# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      # Individual guardrails. Unlike the registry/pass in guardrails.rb, a check
      # encodes real hardware knowledge — what goes wrong on the console and how
      # to say it plainly — so this is where target-specific footgun detail lives.
      module Checks
        # The classic silent-black-screen footgun: the program draws something,
        # but never picks a screen mode. On the Game Boy Advance nothing appears
        # on screen until a mode is chosen, so the whole game runs invisibly — and
        # because there's no crash, it's maddening to diagnose. We catch it on the
        # IR and, since the fix is completely safe, just switch the screen on in
        # bitmap mode for you and leave a warning.
        class ScreenModeSet
          NAME = :screen_mode_set

          PROBLEM =
            "This program draws to the screen but never picks a screen mode. On the " \
            "Game Boy Advance, nothing appears until you pick a mode. So the screen " \
            "stays black, with no crash or error to point at it. To fix this, pick a " \
            "mode with `screen :bitmap` before your first draw. This switches the " \
            "screen on."

          FIXED =
            "You drew without a screen mode, which leaves the screen black. The " \
            "framework switched the screen on in bitmap mode (`screen :bitmap`) for " \
            "you. To silence this warning, add `screen :bitmap` yourself before your " \
            "first draw."

          # Fires only when the program actually draws yet no `screen` op sets a
          # mode anywhere. A program that never draws isn't nagged, and one that
          # already sets a mode is left alone.
          def detect(program)
            first_draw = first_draw(program)
            return [] unless first_draw
            return [] if screen_set?(program)

            # Blame the first draw: it's the line the missing `screen` has to go
            # above, so it's where the author reads the message and puts the fix.
            [Finding.new(
              check: NAME,
              severity: :error,
              message: PROBLEM,
              node: first_draw,
              fix: Fix.new(message: FIXED, apply: method(:switch_screen_on)),
            )]
          end

          private

          # The program's first drawing op, or nil if it never draws. `screen` itself
          # is categorized as a draw op, so exclude it — it's the thing whose absence
          # we're checking for.
          def first_draw(program)
            program.each.find { |node| node.category == :draw && node.kind != :screen }
          end

          def screen_set?(program)
            program.each.any? { |node| node.kind == :screen }
          end

          # The safe fix: put a bitmap `screen` at the very top, ahead of every
          # existing statement, so the screen is on before anything draws.
          def switch_screen_on(program)
            Build.program(Build.screen(:bitmap), *program.children)
          end
        end
      end
    end
  end
end
