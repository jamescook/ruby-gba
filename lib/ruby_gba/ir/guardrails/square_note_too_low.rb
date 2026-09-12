# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A note on a square-wave part that is lower than the square-wave voice can play.
        #
        # The console tunes a square-wave voice with a number that has a bottom, and the bottom
        # is 64 Hz — between the B and the C two octaves below middle C. A lower note is played
        # AT the bottom: it still sounds, it is just a different note, and nothing about the
        # music says so. A song block's note names start at C2 and never reach it, but a pitch
        # written in Hz can, and a Score's MIDI keys go all the way down to 0.
        #
        # A part that plays an instrument has no such bottom — a recording is simply read more
        # slowly — which is one of the two ways out the message offers.
        class SquareNoteTooLow
          NAME = :square_note_too_low
          PLAIN_NAME = "a square-wave note lower than the voice can play"

          LOWEST = Sound::Registers::SQUARE_LOWEST_HZ

          # The lowest MIDI key the square wave plays in tune, and its name: key 36, :C2.
          LOWEST_KEY = (69 + (12 * Math.log2(LOWEST / 440.0))).ceil
          LOWEST_NOTE = :"#{%w[C Cs D Ds E F Fs G Gs A As B][LOWEST_KEY % 12]}#{(LOWEST_KEY / 12) - 1}"

          def detect(program)
            program.walk.select { |node| node.kind == :song }.flat_map do |song|
              song.voices.each_with_index.filter_map do |part, index|
                # Only the square voices have this bottom. A recording is read more slowly, and
                # the wave voice tunes by a sample rate, so it reaches an octave further down.
                next unless Tunes.part_kind(part) == :square

                low = part[:events].map { |event| event[1] }.select { |hz| hz.positive? && hz < LOWEST }
                next if low.empty?

                Finding.new(check: NAME, severity: :warning, message: message(program, song, index, low), node: song)
              end
            end
          end

          private

          def message(program, song, index, low)
            part = SongWords.part(program, song, index)
            lowest = low.min
            count = low.size == 1 ? "" : " This part has #{low.size} notes that are too low."
            notes = low.size == 1 ? "this note" : "these notes"
            "#{part.sub(/\A./, &:upcase)} of #{SongWords.song(program, song)} plays a note at " \
              "#{lowest.round} Hz (MIDI key #{key(lowest)}). The square-wave voice cannot play a note lower " \
              "than #{LOWEST} Hz. It plays this note at #{LOWEST} Hz, so you hear a different note.#{count} " \
              "The lowest note that the voice plays correctly is :#{LOWEST_NOTE} (MIDI key #{LOWEST_KEY}). To " \
              "fix this, play #{notes} one or more octaves higher. Or write `plays: :wave` on this part. " \
              "The wave voice goes one octave lower. Or use `plays:` to give the part an instrument. An " \
              "instrument can play lower notes."
          end

          def key(hz) = (69 + (12 * Math.log2(hz / 440.0))).round
        end
      end
    end
  end
end
