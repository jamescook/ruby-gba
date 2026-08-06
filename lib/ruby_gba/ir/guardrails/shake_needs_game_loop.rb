# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A screen shake that has no frames to happen on.
        #
        # A shake works by moving the picture a small amount, a different way each
        # frame, and then putting it back — so it is spread over time by definition.
        # The framework runs that for you once per frame, at the frame boundary a
        # `game_loop` provides. A program with no game loop has no boundary, so the
        # routine is never reached: `shake_screen` sets its counter, nothing ever
        # reads it, and the screen sits perfectly still. No crash, no warning, and the
        # call looks right where it is written.
        #
        # Read structurally rather than from build-time bookkeeping: the shake routine
        # is declared as soon as anything shakes, and a call to it is placed at each
        # frame boundary. A declared routine with no call to it is exactly this bug.
        class ShakeNeedsGameLoop
          NAME = :shake_needs_game_loop

          ROUTINE = :__shake_tick
          TRIGGER = :__shake_left # the variable `shake_screen` sets at the call site

          MESSAGE =
            "This game shakes the screen with `shake_screen`, but it has no " \
            "`game_loop`. A shake moves the picture a small amount on every frame, " \
            "so it needs frames to run on. With no game loop there are none, and the " \
            "screen never moves. To fix this, put the game in a `game_loop`."

          def detect(program)
            return [] unless declared?(program)
            return [] if called?(program)

            [Finding.new(check: NAME, severity: :warning, message: MESSAGE,
                         node: trigger(program) || :program)]
          end

          private

          def declared?(program)
            program.each.any? { |node| node.kind == :func && node[:name] == ROUTINE }
          end

          def called?(program)
            program.each.any? { |node| node.kind == :call && node[:target] == ROUTINE }
          end

          # Where the author wrote `shake_screen`. The routine itself is the
          # framework's and carries no line, but the counter it sets was recorded at
          # the call site, so that is the line to send them to.
          def trigger(program)
            program.each.find { |node| node.kind == :set && node[:var] == TRIGGER }
          end
        end
      end
    end
  end
end
