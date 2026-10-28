# frozen_string_literal: true

module VBlank
  module Audio
    # HOW A NOTE ON A SQUARE OR NOISE VOICE CHANGES ITS OWN LOUDNESS while it holds.
    #
    # Those voices count a note's loudness by themselves, with nothing from the game: struck at
    # its volume (0 to 15), the voice steps it one down — or one up — every +step+ 64ths of a
    # second, until it reaches silence (or full) and stays there. A step of 0 never moves it, which
    # is a note that holds like an organ's. Fading down is a plucked string or a bell, and the way
    # a drum hit rings out; swelling up is a bowed note, or a pad that breathes in.
    #
    # It is the voice's own counting and not the game's, so it costs nothing a frame — and it is
    # the same circuit on the Advance and the Color, which is why a song written for one plays the
    # same on the other.
    #
    # A recording on the mixer has a shape of its own instead (Envelope), and the wave voice has
    # no counting at all: it plays at one of its few fixed volumes until it is told another.
    NoteFade = Data.define(:direction, :step)

    class NoteFade
      # The slowest the voice counts: seven 64ths of a second on each step of loudness.
      SLOWEST = 7

      def self.fading(step) = new(direction: :down, step: step)

      def self.swelling(step) = new(direction: :up, step: step)

      # A note that holds at its volume.
      HOLD = fading(0)

      # THE SHAPE A PART OR NOTE SAID, from the two words a song writes it with: +decay+ to fade
      # each note out, +swell+ to bring it in. Each is a speed (:fast, :medium, :slow or :none) or
      # the step itself, 0 to 7. Nil when it said neither, which leaves the note to its voice: a
      # drum fades as its part says, a square note holds.
      def self.said(decay:, swell:, where:)
        return nil if decay.nil? && swell.nil?
        unless decay.nil? || swell.nil?
          raise ArgumentError, "#{where} says both `decay:` and `swell:`. A note can fade out or swell in, " \
                               "but not both. To fix this, remove one of them."
        end

        decay.nil? ? swelling(step_of(swell, "swell", where)) : fading(step_of(decay, "decay", where))
      end

      def self.step_of(speed, word, where)
        Sound.fade_step(speed)
      rescue ArgumentError
        raise ArgumentError, "#{where} says `#{word}: #{speed.inspect}`. A #{word} is :fast, :medium, :slow " \
                             "or :none, or the 64ths of a second each step of loudness lasts, from 0 to #{SLOWEST}. " \
                             "To fix this, give one of those."
      end
      private_class_method :step_of

      # A WHOLE PART'S FADE, from what it said: a part on the noise voice keeps its fade-out as its
      # own `decay`, as a drum always did, so only a swell is a fade of its own there. Every other
      # part's is what it said.
      def self.for_part(said, drum:) = drum && !said&.swells? ? nil : said

      # A recording and the wave voice have no counting of their own to fade a note with: the
      # wave voice plays at one of its few fixed volumes, and a recording's shape is its envelope.
      # +who+ names the part, as the start of a sentence.
      def self.refuse_without_counting!(who, wave:)
        fix = wave ? "To fade the wave voice, write each note at the volume you want it" \
                   : "To shape a recording's notes, give the part an `envelope:` instead"
        raise ArgumentError, "#{who} says `decay` or `swell`, but it plays #{wave ? 'the wave voice' : 'a recording'}. " \
                             "Only the square and noise voices can fade a note by themselves. #{fix}."
      end

      # The four bits the voice's control register keeps it in: the direction (up is 8) and the
      # step under it. Both consoles lay it out the same.
      def bits = (direction == :up ? 8 : 0) | step

      def self.from_bits(bits) = new(direction: bits.anybits?(8) ? :up : :down, step: bits & 7)

      def swells? = direction == :up
    end
  end
end
