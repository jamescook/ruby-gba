# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # A song's second square part saying its notes slide their pitch.
        #
        # The console has two square-wave voices and only the first has the circuit that slides
        # a note's pitch by itself (Audio::PitchSlide). A song's first square part plays on it and
        # its second on the other, so a slide said by the second has nothing to play it — the
        # note would hold its pitch, with nothing to say why. The fix costs nothing: the two parts
        # trade places in the song.
        #
        # Checked here, on the finished program, because a song reaches the IR two ways — a
        # `song` block and a Score — and only the whole song knows which square part comes first.
        class SlideOffFirstSquare
          NAME = :slide_off_first_square
          PLAIN_NAME = "a slide on a square part that is not the song's first"

          def detect(program)
            program.walk.select { |node| node.kind == :song }.flat_map do |song|
              squares = song.voices.each_with_index.select { |part, _| Tunes.part_kind(part) == :square }
              squares.drop(1).filter_map do |part, index|
                next unless part.slides?

                Finding.new(check: NAME, severity: :error, message: message(program, song, index), node: song)
              end
            end
          end

          private

          def message(program, song, index)
            part = SongWords.part_phrase(program, song, index)
            "#{part.sub(/\A./, &:upcase)} of #{SongWords.song_phrase(program, song)} says `slide_up` or " \
              "`slide_down`, but it is the second square part. Only the song's first square part can slide its " \
              "notes. To fix this, put this part before the other square part."
          end
        end
      end
    end
  end
end
