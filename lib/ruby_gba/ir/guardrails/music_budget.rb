# frozen_string_literal: true

require_relative "../cost_model"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # Music plays by checking the whole score against a frame counter on every
        # frame: the tune is unrolled into one comparison per note, and all of them
        # are re-checked 60 times a second. A short jingle is nothing, but a long
        # tune turns into a long comparison chain the console re-runs every frame —
        # real recurring work that has nothing to do with drawing, and it grows the
        # ROM too. This flags a song long enough for that chain to be heavy on its
        # own and suggests keeping tunes to a shorter loop. Advisory, like the draw
        # budget: the estimate is rough and the build still produces a ROM.
        class MusicBudget
          NAME = :music_budget

          def detect(program)
            model = CostModel.new
            # The per-frame chain only recurs when a game loop calls play_song each
            # frame; a one-shot program plays the song once, so there's nothing to
            # flag.
            return [] unless model.looping?(program)

            model.song_verdicts(program).select { |song| song[:over] }.map do |song|
              Finding.new(check: NAME, severity: :warning, message: message(song), fix: nil)
            end
          end

          private

          def message(song)
            "The song :#{song[:name]} has #{song[:notes]} notes. Music plays by checking every note " \
              "against a frame counter, and it re-checks all #{song[:notes]} of them on every single frame " \
              "(roughly #{format('%.1f', song[:steady_cost])} scanlines of work a frame, against about " \
              "#{format('%.1f', song[:budget])} for music) — real recurring work even when nothing on screen " \
              "is moving, and it makes the ROM bigger too. Keep tunes to a shorter loop, or break a long piece " \
              "into a few shorter songs you swap between. Call `rom.explain` on the built ROM to see the " \
              "per-song breakdown."
          end
        end
      end
    end
  end
end
