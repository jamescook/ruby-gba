# frozen_string_literal: true

module VBlank
  module Audio
    # HOW A NOTE WOBBLES ITS PITCH while it holds — a singer's vibrato, a violin's.
    #
    # No voice of the console does this by itself, so the music player does it, a frame at a time:
    # once the note has sounded for +after+ frames, it moves the voice's pitch number up by half
    # the +depth+ (rounded up) and holds it there for +speed+ frames, then down by the other half
    # below where the note began for +speed+ frames, and back up, until the part's next note. The
    # pitch number is the one the voice is tuned by (Sound::Registers.frequency_value), the same on
    # the Advance and the Color, so a step is the voice's own smallest change of pitch: small on a
    # low note and larger on a high one, which is how the console's own music engines wobble.
    #
    # The note is not started again as its pitch moves, so its loudness and any fade carry on. The
    # square voices and the wave voice wobble; the hiss has no pitch to wobble, and a recording
    # plays at a rate of the mixer's.
    Vibrato = Data.define(:depth, :speed, :after)

    class Vibrato
      # The most a wobble can say, as the four, four and eight bits a note keeps it in — the speed
      # kept less one, since it is never nought, so a converted engine's slowest swing fits: that
      # engine counts a swing down from fifteen to nought, which is sixteen frames.
      DEEPEST = 15
      SLOWEST = 16
      LONGEST_WAIT = 255

      # The words a game can say: how far it wobbles, in the voice's pitch steps, and how many
      # frames each swing holds.
      DEPTHS = { slight: 2, medium: 4, wide: 8 }.freeze
      SPEEDS = { fast: 2, medium: 4, slow: 8 }.freeze

      # A note that holds its pitch, written over a part that wobbles.
      NONE = new(depth: 0, speed: 1, after: 0)

      # Does the pitch move? A depth of nought holds it still.
      def moves? = depth.positive?

      # Whether +vibrato+ — said, or nil for nothing said — moves the pitch.
      def self.moves?(vibrato) = !vibrato.nil? && vibrato.moves?

      # How far the pitch number goes above where the note began, and below it.
      def above = (depth + 1) / 2
      def below = depth / 2

      # THE WOBBLE A PART OR NOTE SAID: :none, or a Hash of +depth+ (:slight, :medium, :wide, or
      # 1 to 15 pitch steps), +speed+ (:fast, :medium, :slow, or the frames each swing holds, 1 to
      # 16) and +after+ (the frames before it starts, 0 to 255, or a note length when +frames+ can
      # turn one into frames). What a Hash leaves out is :medium, :medium and nought. Nil when it
      # said nothing. +where+ names who said it, as the start of a sentence.
      def self.said(said, where:, frames: nil)
        return nil if said.nil?
        return NONE if said == :none
        refuse_unknown!(said, where) unless said.is_a?(Hash) && (said.keys - %i[depth speed after]).empty?

        new(depth: checked_amount(said.fetch(:depth, :medium), DEPTHS, DEEPEST, "depth", where),
            speed: checked_amount(said.fetch(:speed, :medium), SPEEDS, SLOWEST, "speed", where),
            after: checked_wait(said.fetch(:after, 0), frames, where))
      end

      def self.checked_amount(said, words, most, word, where)
        return words.fetch(said) if words.key?(said)
        return said if said.is_a?(Integer) && said.between?(1, most)

        raise ArgumentError, "#{where} says a vibrato #{word} of #{said.inspect}. A #{word} is " \
                             "#{words.keys.map(&:inspect).join(', ')}, or a whole number from 1 to #{most}. " \
                             "To fix this, give one of those."
      end
      private_class_method :checked_amount

      def self.checked_wait(said, frames, where)
        said = frames.call(said) if said.is_a?(Symbol) && frames
        return said if said.is_a?(Integer) && said.between?(0, LONGEST_WAIT)

        raise ArgumentError, "#{where} says a vibrato starts after #{said.inspect}. It starts after a number " \
                             "of frames, from 0 to #{LONGEST_WAIT}#{frames ? ', or a note length like :eighth' : ''}. " \
                             "To fix this, give one of those."
      end
      private_class_method :checked_wait

      def self.refuse_unknown!(said, where)
        raise ArgumentError, "#{where} says `vibrato: #{said.inspect}`. A vibrato is :none, or " \
                             "{ depth:, speed:, after: }. To fix this, give one of those."
      end
      private_class_method :refuse_unknown!

      # The hiss has no pitch to wobble, and a recording plays at the mixer's rate. +who+ names the
      # part, as the start of a sentence.
      def self.refuse_without_pitch!(who, noise:)
        plays = noise ? "the noise voice" : "a recording"
        raise ArgumentError, "#{who} says `vibrato`, but it plays #{plays}. Only a square part or the wave part " \
                             "can have vibrato. To fix this, remove `vibrato` from this part and from its notes."
      end

      # A slide and a wobble both move the same pitch, so a note has one of them. +frame+ is when the
      # note starts, which names it.
      def self.refuse_with_slide!(who, frame:)
        seconds = (frame / Score::FRAME_RATE.to_f).round(2)
        raise ArgumentError, "#{who} has a note with a slide and vibrato, #{seconds} seconds in. A note can have a " \
                             "slide or vibrato, but not both. To fix this, give that note `vibrato: :none`, or " \
                             "`slide_up: :none`."
      end

      # The sixteen bits a note keeps it in: the depth, the speed above it, and the wait above that.
      SPEED_AT = 4
      AFTER_AT = 8
      FOUR_BITS = 0xF

      def bits = depth | ((speed - 1) << SPEED_AT) | (after << AFTER_AT)

      def self.from_bits(bits)
        new(depth: bits & FOUR_BITS, speed: ((bits >> SPEED_AT) & FOUR_BITS) + 1, after: bits >> AFTER_AT)
      end
    end
  end
end
