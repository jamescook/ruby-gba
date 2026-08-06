# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A screen faded all the way out and never brought back.
        #
        # A full fade blends every layer completely into one color, so nothing shows
        # through it — not the game, not a sprite, not text drawn afterwards. The
        # picture is all still there underneath, which is exactly what makes this hard
        # to spot: the program runs correctly and draws everything it meant to, and the
        # screen is a flat color. It is the classic silent black screen, and the usual
        # way in is to fade out for a scene change and forget the fade back in.
        #
        # Only a fade whose amount is a plain number is judged. A fade driven by a
        # variable is how a fade over time is written, and where it ends up is not
        # knowable here, so those programs are left alone.
        class FadeNeverLifted
          NAME = :fade_never_lifted

          # The amount at which nothing shows through at all. Below this something of
          # the picture survives, and a permanently dimmed screen is a style choice
          # rather than a bug.
          FULL = 100

          def detect(program)
            fades = program.each.select { |node| node.kind == :fade }
            return [] if fades.empty?

            amounts = fades.map { |node| amount_of(node) }
            return [] if amounts.any?(&:nil?)  # a fade the game computes — unknowable
            return [] if amounts.any?(&:zero?) # something does bring it back
            return [] unless amounts.max >= FULL

            [Finding.new(check: NAME, severity: :warning, message: message(fades.last),
                         node: fades.last)]
          end

          private

          def message(node)
            color = node[:toward]
            "This game fades the screen fully to #{color} and never fades back. A full " \
              "fade covers everything, so the screen stays one flat color and the game " \
              "is not visible behind it. Anything drawn after the fade is covered too. " \
              "To fix this, use `fade :#{color}, 0` when the fade is finished. For a fade " \
              "over time, move a variable from 0 to 100 and give it to `fade`."
          end

          # The fade's amount when it is a plain number, or nil when the game works it
          # out as it runs.
          def amount_of(node)
            value = node[:amount]
            value.is_a?(Node) && value.kind == :int ? value[:value] : nil
          end
        end
      end
    end
  end
end
