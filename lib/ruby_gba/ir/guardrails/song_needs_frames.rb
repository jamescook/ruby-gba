# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A song in a program that never waits for the screen.
        #
        # `play_song` names the tune that is playing; the tune itself is moved on a frame at
        # a time by the framework, at the moment the screen finishes a picture — the same
        # moment `wait_vblank` wakes up at. A program that never waits has no such moments.
        # Nothing moves the tune on, and the cartridge stays silent: no crash, and the call
        # looks right where it is written.
        class SongNeedsFrames
          NAME = :song_needs_frames
          PLAIN_NAME = "a song with no frames to play on"

          MESSAGE =
            "This game plays a song with `play_song`, but it never waits for the screen. " \
            "A song moves one step on every frame, so it needs frames to play on. A frame " \
            "ends when the game waits for the screen. With no wait there are no frames, and " \
            "the song never plays. To fix this, put the game in a `game_loop`. A `game_loop` " \
            "waits for the screen on each pass."

          def detect(program)
            played = program.walk.find { |node| %i[play_song play_from_list].include?(node.kind) }
            return [] unless played
            return [] if program.walk.any? { |node| node.kind == :wait_vblank }

            [Finding.new(check: NAME, severity: :warning, message: MESSAGE, node: played)]
          end
        end
      end
    end
  end
end
