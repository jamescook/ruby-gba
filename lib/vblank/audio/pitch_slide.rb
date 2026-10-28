# frozen_string_literal: true

module VBlank
  module Audio
    # HOW A NOTE ON THE FIRST SQUARE VOICE SLIDES ITS OWN PITCH while it holds.
    #
    # That voice has a circuit the other three lack. Struck at a pitch, every +every+ 128ths of a
    # second it moves the pitch by a part of itself — up or down — with nothing from the game. The
    # part is the voice's pitch number shifted right +shift+ places: 1 moves it by half of itself
    # at each step, 7 by a 128th. The voice keeps its pitch as a number that climbs as the note
    # gets higher, so sliding up climbs faster and faster, and once the number would run past the
    # top of what the voice can play the voice switches itself off: a zap that ends in silence.
    # Sliding down slows as it falls and never runs out.
    #
    # It is the voice's own counting, like a fade (NoteFade), so it costs nothing a frame, and it
    # is the same circuit on the Advance and the Color. A song's first square part plays on that
    # voice, so it is the one part that can slide (Guardrails::Checks::SlideOffFirstSquare).
    PitchSlide = Data.define(:direction, :every, :shift)

    class PitchSlide
      # The most 128ths of a second between steps, and the most places a step shifts by — the
      # finest step. Each is three bits of the register.
      SLOWEST = 7
      FINEST = 7

      # The speeds a game can say, as how many 128ths of a second each step waits. All three move
      # by the same part of the pitch at each step: a 32nd, which from a middle note climbs off
      # the top in a handful of steps and falls about two octaves over a second.
      EVERY = { fast: 1, medium: 3, slow: SLOWEST }.freeze
      SHIFT = 5

      def self.upward(every:, shift:) = new(direction: :up, every: every, shift: shift)

      def self.downward(every:, shift:) = new(direction: :down, every: every, shift: shift)

      # A note that does not slide, written over a part that does.
      NONE = upward(every: 0, shift: 0)

      # Does the pitch move? Only NONE holds it, since a slide said in words or numbers waits at
      # least one 128th and shifts at least one place. `:none` is said — the log names it — but it
      # asks nothing of the voice, so any part may say it and it costs a game nothing.
      def moves? = self != NONE

      # Whether +slide+ — said, or nil for nothing said — moves the pitch.
      def self.moves?(slide) = !slide.nil? && slide.moves?

      # THE SLIDE A PART OR NOTE SAID, from the two words a song writes it with: +up+ to slide it up
      # and +down+ to slide it down. Each is a speed (:fast, :medium or :slow), :none, or the
      # voice's own two numbers ({ every: 1..7, shift: 1..7 }). Nil when it said neither.
      def self.said(up:, down:, where:)
        return nil if up.nil? && down.nil?
        unless up.nil? || down.nil?
          raise ArgumentError, "#{where} says both `slide_up:` and `slide_down:`. A note can slide up or down, " \
                               "but not both. To fix this, remove one of them."
        end

        up.nil? ? of(:down, down, where) : of(:up, up, where)
      end

      def self.of(direction, said, where)
        return NONE if said == :none
        return new(direction: direction, every: EVERY.fetch(said), shift: SHIFT) if EVERY.key?(said)
        return new(direction: direction, every: said[:every], shift: said[:shift]) if voice_numbers?(said)

        raise ArgumentError, "#{where} says `slide_#{direction}: #{said.inspect}`. A slide is :fast, :medium, " \
                             ":slow or :none, or the voice's own numbers, { every: 1..#{SLOWEST}, " \
                             "shift: 1..#{FINEST} }. To fix this, give one of those."
      end
      private_class_method :of

      # Is +said+ the voice's own two numbers, each in its range?
      def self.voice_numbers?(said)
        said.is_a?(Hash) && said.keys.sort == %i[every shift] &&
          [[said[:every], SLOWEST], [said[:shift], FINEST]].all? { |n, most| n.is_a?(Integer) && n.between?(1, most) }
      end
      private_class_method :voice_numbers?

      # Only the first square voice has the circuit, and only a song's first square part plays on it.
      # +who+ names the part, as the start of a sentence; +wave+ and +noise+ say which other voice it
      # plays, and neither is a recording.
      def self.refuse_off_square!(who, wave:, noise:)
        plays = (wave && "the wave voice") || (noise && "the noise voice") || "a recording"
        raise ArgumentError, "#{who} says `slide_up` or `slide_down`, but it plays #{plays}. Only the song's first " \
                             "square part can slide its notes. To fix this, give the slide to that part."
      end

      # The seven bits the voice's sweep register keeps it in: how many 128ths each step waits,
      # then 8 when it slides down, then the shift. Both consoles lay it out the same.
      EVERY_AT = 4
      DOWN = 8
      THREE_BITS = 7

      def bits = (every << EVERY_AT) | (direction == :down ? DOWN : 0) | shift

      def self.from_bits(bits)
        new(direction: bits.anybits?(DOWN) ? :down : :up, every: (bits >> EVERY_AT) & THREE_BITS,
            shift: bits & THREE_BITS)
      end
    end
  end
end
