# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A song whose loop point has no note after it.
        #
        # A song with an introduction plays it once, then at its end goes back to its loop point
        # and plays on from there, over and over. If no part plays a note between the loop point
        # and the end, that repeat is silence: the music stops after its first time through, for
        # as long as the game plays it, and nothing in the program says why.
        #
        # What counts is a note SOUNDING there, not an event. A note held across the loop point
        # is sounded again at it every time round, or simply carries on when the song ends on
        # it, so a drone from the introduction is a repeat with something in it. The answer
        # comes from IR::Tunes, beside the rule both players follow, so this can never disagree
        # with what is heard.
        class SongLoopsIntoSilence
          NAME = :song_loops_into_silence
          PLAIN_NAME = "a song that is silent after its first time through"

          def detect(program)
            program.walk.select { |node| node.kind == :song }.filter_map do |song|
              next unless silent_repeat?(song)

              Finding.new(check: NAME, severity: :error, message: message(program, song), node: song)
            end
          end

          private

          # A loop point at or past the end is refused where it is written — `loop_from:` or
          # `loop_from_here` — in the unit it was written in, so it is not this check's to name.
          def silent_repeat?(song)
            from = Tunes.loop_frame(song)
            return false unless from.positive? && from < song.total_frames

            !Tunes.repeat_sounds?(song)
          end

          def message(program, song)
            fix = if SongWords.score?(program, song)
                    "give `loop_from:` a tick that has notes after it"
                  else
                    "put `loop_from_here` at a point that has notes after it"
                  end
            "#{SongWords.song_capitalized(program, song)} loops from " \
              "#{SongWords.seconds(Tunes.loop_frame(song))} into the song. No part plays a note from that " \
              "point to the end. So after the first time through, the song is silent. To fix this, #{fix}."
          end
        end
      end
    end
  end
end
