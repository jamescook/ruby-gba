# frozen_string_literal: true

module VBlank
  module Audio
    # A PART PLAYED HIGHER OR LOWER THAN IT IS WRITTEN, worked into each of its notes' pitches as the
    # game is built, so every backend plays the same pitches and no player does anything new.
    #
    # +transpose+ moves every note by whole semitones, up or down: twelve is an octave. +pitch_offset+
    # then moves it by the voice's own pitch steps — the number a square voice or the wave voice is
    # tuned by (Sound.square_wave_ticks, Sound.wave_voice_ticks), where each step up makes a wave a
    # tick of the voice's clock shorter. A step or two is a part a little sharp, which is how another
    # game's music engine detunes a part against another, and what music converted from one arrives
    # saying. The hiss has no such number, and a recording plays at a rate of the mixer's, so only
    # a square part or the wave part can be offset; any part can be transposed. A note transposed
    # past what its voice reaches plays at the voice's end, as a note written there does.
    PitchShift = Data.define(:transpose, :pitch_offset)

    class PitchShift
      NONE = new(transpose: 0, pitch_offset: 0)

      # The most semitones a part moves, either way: four octaves.
      MOST_SEMITONES = 48

      # Each voice that has pitch steps: the ticks a second its clock counts, and the most ticks a
      # wave of it lasts.
      VOICE_CLOCKS = Ractor.make_shareable({ square: [Sound::SQUARE_CLOCK_HZ, Sound::SQUARE_LONGEST_WAVE],
                                             wave: [Sound::WAVE_CLOCK_HZ, Sound::WAVE_LONGEST_WAVE] })

      # THE SHIFT A PART SAID, +transpose+ semitones and +pitch_offset+ pitch steps, nil for each it did
      # not say. +where+ names the part, as the start of a sentence.
      def self.said(transpose:, pitch_offset:, where:)
        new(transpose: checked_amount(transpose, MOST_SEMITONES, "transpose", "semitones", where),
            pitch_offset: checked_amount(pitch_offset, Sound::SQUARE_LONGEST_WAVE - 1, "pitch_offset", "pitch steps", where))
      end

      def self.checked_amount(said, most, word, unit, where)
        return 0 if said.nil?
        return said if said.is_a?(Integer) && said.between?(-most, most)

        raise ArgumentError, "#{where} says `#{word} #{said.inspect}`. It must be a whole number of #{unit} from " \
                             "#{-most} to #{most}. To fix this, give a whole number in that range."
      end
      private_class_method :checked_amount

      def moves? = transpose != 0 || pitch_offset != 0

      # +events+ with every note's pitch shifted, for a part playing +kind+ of voice (Music.kind_played).
      # A rest stays a rest. +who+ names the part, as the start of a sentence.
      def applied(events, kind:, who:)
        return events unless moves?

        refuse_offset!(who, kind) unless pitch_offset.zero? || VOICE_CLOCKS.key?(kind)
        events.map do |event|
          next event if event[1].zero?

          [event[0], shifted(event[1] * (2**(transpose / 12.0)), kind, who, event[0]), *event.drop(2)]
        end
      end

      private

      # A pitch +pitch_offset+ steps from +hz+'s on a voice of +kind+, as the frequency that voice
      # plays it at.
      def shifted(hz, kind, who, frame)
        return hz if pitch_offset.zero?

        clock, longest = VOICE_CLOCKS.fetch(kind)
        ticks = (kind == :wave ? Sound.wave_voice_ticks(hz) : Sound.square_wave_ticks(hz)) - pitch_offset
        refuse_out_of_reach!(who, frame, higher: ticks < 1) unless ticks.between?(1, longest)
        clock.to_f / ticks
      end

      def refuse_offset!(who, kind)
        plays = kind == :noise ? "the noise voice" : "a recording"
        raise ArgumentError, "#{who} says a pitch offset, but it plays #{plays}. Only a square part or the wave part " \
                             "has pitch steps to offset. To fix this, remove `pitch_offset` from this part."
      end

      # +frame+ is when the note starts, which names it.
      def refuse_out_of_reach!(who, frame, higher:)
        seconds = (frame / Score::FRAME_RATE.to_f).round(2)
        raise ArgumentError, "#{who} has a note #{seconds} seconds in. Its pitch offset moves it " \
                             "#{higher ? 'higher' : 'lower'} than the voice can play. To fix this, give a smaller " \
                             "pitch offset, or write that note #{higher ? 'lower' : 'higher'}."
      end
    end
  end
end
