# frozen_string_literal: true

module RubyGBA
  module Audio
    # HOW A NOTE STARTS AND HOW IT ENDS — the shape of its loudness over time, the thing that
    # makes a plucked string different from a bowed one played at the same pitch.
    #
    # WHY IT HAS TO EXIST AT ALL, which is not obvious until you hear it: a recorded note that
    # simply stops leaves the speaker wherever the wave happened to be at that instant, and the
    # jump from there to silence is a CLICK. It is loud — a note cut at the top of its wave moves
    # the speaker further in one step than the music ever does — and it comes and goes, because a
    # note that happens to end near the middle of its wave is silent about it. That is the worst
    # kind of bug to be handed: "sometimes there is a pop at the end of a lick".
    #
    # So a note ends by getting quieter over a few frames instead of stopping. A twentieth of a
    # second is enough to remove the click completely and far too short to hear as a fade.
    #
    # WHAT THE FOUR NUMBERS ARE. A sounding note keeps a LEVEL, from nothing up to however loud
    # the note was asked to be, and the four numbers move that level once a frame:
    #
    #   attack   how fast it climbs when the note starts.
    #   decay    how fast it falls from full, once it gets there.
    #   sustain  where it stops falling, and holds while you keep the note down.
    #   release  how fast it falls to nothing once the note ends.
    #
    # A struck instrument — a piano, a bell — hits full at once, falls back, and rings on after the
    # key is let go. A bowed or blown one climbs, holds where it is, and stops soon after. Both are
    # these four numbers.
    #
    # TWO WAYS TO SAY THEM, and they are for two different people.
    #
    # Write a Hash and say it in TIME, which is what somebody writing music means:
    #
    #   envelope: { attack: 0.01, decay: 0.2, sustain: 0.6, release: 0.25 }
    #
    # The three times are in seconds, and +sustain+ is a fraction of full loudness (0.0 silent,
    # 1.0 as loud as the note was asked to be). Everything you leave out stays where it was, so
    # `envelope: { release: 0.2 }` says the one thing most music needs and nothing else.
    #
    # Or build one of these directly and give the four numbers the console's own sound engine
    # keeps, 0 to 255 each:
    #
    #   Envelope.new(attack: 255, decay: 245, sustain: 180, release: 216)
    #
    # That form is for a game whose music came out of another cartridge: its instruments already
    # carry these four bytes, and there is nothing to convert. Their meanings are the ones the
    # original hardware's sound engine uses, so the numbers drop straight in: +attack+ is ADDED to
    # the level each frame, +decay+ and +release+ are what the level is MULTIPLIED by each frame
    # (out of 256, so 216 keeps about six sevenths of it and 89 keeps about a third), and
    # +sustain+ is the level it holds at.
    #
    # WHAT IT COSTS is one pass over the sounding voices once a frame, where the four numbers move
    # the level — and then one addition per sample, in the mix, to slide the loudness there. The
    # console's own retail sound engine moves the level at the frame boundary and nowhere else,
    # which makes a fade a staircase, and a fast fade takes most of its fall in the first step: the
    # fastest release on a retail cartridge, 89, keeps about a third of the level each frame, so its
    # first step is two thirds of the wave and is a click. Slid across the frame's samples instead,
    # no fade steps further in one sample than the wave itself does. A game that shapes no note
    # emits none of this, and its mix is the one it always had.
    Envelope = Data.define(:attack, :decay, :sustain, :release)

    class Envelope
      # The largest any of the four can be. The level is a byte, and so is each of these.
      MOST = 255
      FULL = MOST

      # THE LEVEL IS A BYTE AND NOTHING FINER, which is worth saying because keeping it finer
      # looks like an improvement and is not. A fall is a multiply by a fraction, so it loses its
      # remainder every frame, and that lost remainder is most of how fast a quiet note dies: the
      # same 216 that keeps five sixths of a loud level takes a level of 3 straight to 2. Kept to a
      # byte the numbers off a real cartridge fall in the frames they were measured falling in;
      # kept finer they take about twice as long, and every note rings on past where its music
      # wanted it. There is nothing to lose either, because what the mix multiplies by is 0 to 64 —
      # a sixty-fourth of full is already smaller than one step of the level.
      SCALE = 8 # the level scales a loudness of 0..64 through a shift of this many bits

      # AS IT WAS WITHOUT AN ENVELOPE: full at once, no fall, and it stops the instant the note
      # ends. So `envelope: {}` changes nothing, and each key you write changes one thing.
      PLAIN = { attack: 0.0, decay: 0.0, sustain: 1.0, release: 0.0 }.freeze

      # Frames a second — the rate the music is played at, and the rate this level moves at. The
      # same round figure a song's note lengths are worked out from, so a fifth of a second here
      # and a fifth of a second there are the same number of frames.
      FRAME_RATE = Score::FRAME_RATE

      # What an author wrote, as an Envelope: one of these already, or a Hash of times, or nothing
      # at all. +where+ names the thing it was written on, for a message about it.
      def self.of(said, where)
        case said
        when nil then nil
        when Envelope then said
        when Hash then from_times(said, where)
        else
          raise ArgumentError, "#{where} has the envelope #{said.inspect}. An envelope is a Hash of " \
                               "times, like `{ release: 0.2 }`. It can also be an Envelope, for the " \
                               "four numbers the console's own sound engine keeps."
        end
      end

      # A Hash of times as the four numbers. Times are in seconds and sustain is a fraction of
      # full. Worked out once, when the game is built.
      def self.from_times(said, where)
        unknown = said.keys - PLAIN.keys
        unless unknown.empty?
          raise ArgumentError, "#{where} has an envelope with #{unknown.first.inspect} in it. An " \
                               "envelope has #{PLAIN.keys.map(&:inspect).join(', ')} and nothing else."
        end

        times = PLAIN.merge(said)
        PLAIN.each_key { |key| number!(times[key], key, where) }
        sustain = level_of(times[:sustain], where)
        new(attack: attack_for(times[:attack]), decay: fall_for(times[:decay], FULL, sustain),
            sustain: sustain, release: fall_for(times[:release], FULL, 0))
      end

      # HOW FAST THE LEVEL CLIMBS to reach full in about +seconds+. It is added each frame, so the
      # step is the whole climb shared out over the frames there are. A time of nothing at all
      # means full on the first frame, which is what a struck instrument does.
      def self.attack_for(seconds)
        frames = (seconds * FRAME_RATE).round
        return MOST if frames < 2

        (MOST.to_f / frames).ceil.clamp(1, MOST)
      end

      # HOW FAST THE LEVEL FALLS from +from+ to +to+ in about +seconds+ — the number it is
      # multiplied by each frame, out of 256.
      #
      # Found by trying it rather than by a formula, and that is deliberate: the level is a whole
      # number that loses its remainder every frame, so the arithmetic the console really does is
      # the only honest answer to "how long does 216 take". A bigger number falls more slowly, so
      # the search can halve the range each time.
      def self.fall_for(seconds, from, to)
        frames = (seconds * FRAME_RATE).round
        return 0 if frames < 1 # nothing at all: it stops where it is

        low, high = 0, MOST
        while low < high
          middle = (low + high) / 2
          frames_to_fall(middle, from, to) < frames ? low = middle + 1 : high = middle
        end
        nearest(low, frames, from, to)
      end

      # Of the number found and the one below it, whichever lands nearer the time that was asked
      # for. The search stops at the first number that takes long enough, and the one below it can
      # be the closer of the two.
      def self.nearest(found, frames, from, to)
        return found if found.zero?

        over = frames_to_fall(found, from, to) - frames
        under = frames - frames_to_fall(found - 1, from, to)
        over < under ? found : found - 1
      end

      # How many frames the level takes to fall from +from+ to +to+ when it is multiplied by
      # +byte+/256 each frame — the same arithmetic the mixer does, so this cannot disagree with
      # what is heard. A number that cannot get there at all answers with the longest fall there
      # is, which keeps the search above in order.
      def self.frames_to_fall(byte, from, to)
        return 1 if byte.zero?

        level = from
        frames = 0
        while level > to && frames < LONGEST_FALL
          level = (level * byte) >> SCALE
          frames += 1
        end
        frames
      end

      # Where the search gives up. The slowest fall there is dies away well inside this, so no real
      # time reaches it — it is here so a fall that somehow stood still could not spin.
      LONGEST_FALL = 4096

      def self.level_of(fraction, where)
        unless fraction.between?(0, 1)
          raise ArgumentError, "#{where} has an envelope with sustain #{fraction.inspect}. Sustain is " \
                               "how loud the note holds, from 0.0 (silent) to 1.0 (as loud as the note " \
                               "was asked to be)."
        end

        (fraction * MOST).round
      end

      def self.number!(value, key, where)
        return if value.is_a?(Numeric) && value >= 0

        means = key == :sustain ? "a fraction of full loudness, 0.0 to 1.0" : "a time in seconds, 0 or more"
        raise ArgumentError, "#{where} has an envelope with #{key}: #{value.inspect}. " \
                             "The #{key} is #{means}."
      end

      # The four numbers the console's own sound engine keeps, 0 to 255 each. A Hash of times is
      # the other way to say this (see .of), and is what a hand-written song wants.
      def initialize(attack: MOST, decay: 0, sustain: MOST, release: 0)
        { attack: attack, decay: decay, sustain: sustain, release: release }.each do |name, value|
          next if value.is_a?(Integer) && value.between?(0, MOST)

          raise ArgumentError, "An Envelope has #{name}: #{value.inspect}. Each of the four is a whole " \
                               "number from 0 to #{MOST}, as the console's own sound engine keeps them. " \
                               "To give times in seconds, write a Hash: `{ #{name}: 0.2 }`."
        end
        super
      end

      # WHICH PART OF A NOTE A VOICE IS IN. Climbing to full, then holding (which covers both the
      # fall to the sustain level and the hold there — one test against the level tells them
      # apart), then falling away once the note has ended.
      CLIMBING = :climbing
      HOLDING = :holding
      FALLING = :falling

      # ONE FRAME OF THE NOTE'S SHAPE: where the level and the phase are after it. This is the
      # rule, written once, in the plainest form there is — both backends do exactly this, one in
      # Ruby and one in ARM, and a test holds them against each other. Whole numbers throughout,
      # because that is what the console has and a fall loses its remainder every frame.
      def step(level, phase)
        case phase
        when CLIMBING
          climbed = level + attack
          climbed >= FULL ? [FULL, HOLDING] : [climbed, CLIMBING]
        when HOLDING
          return [level, HOLDING] if level <= sustain

          [[(level * decay) >> SCALE, sustain].max, HOLDING]
        else
          [(level * release) >> SCALE, FALLING]
        end
      end

      # The four packed into one word, which is how a sounding voice carries them. Never 0 as a
      # whole, so a voice can say it has no envelope by holding nothing at all: an envelope that
      # packed to 0 would be a note that never sounds, and #initialize's own floor keeps attack
      # above it.
      def packed = attack | (decay << 8) | (sustain << 16) | (release << 24)

      # Does the level move at all, or is this the plain note it always was? A note that starts
      # full, holds full and stops dead is what a voice with no envelope already does, so saying
      # it costs nothing and emits nothing.
      def plain? = attack == MOST && sustain == MOST && release.zero?
    end
  end
end
