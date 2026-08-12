# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A screen tinted all the way and never brought back.
        #
        # The same silent flat screen {FadeNeverLifted} catches, reached by the other
        # verb. A full tint mixes its color in completely, so nothing shows through it —
        # not the game, not a sprite, not anything drawn afterwards. The picture is all
        # still there underneath, which is what makes it hard to spot: the program runs
        # correctly and draws everything it meant to, and the screen is one flat color.
        #
        # It is a separate check rather than a branch inside the fade's because the two
        # verbs are separate: a program can fade and never tint, and the advice names the
        # verb the author actually wrote.
        #
        # Only a tint whose amount is a plain number is judged. A tint driven by a
        # variable is how a tint over time is written, and where it ends up is not
        # knowable here, so those programs are left alone.
        class TintNeverLifted
          NAME = :tint_never_lifted

          # The amount at which nothing shows through at all. Below this something of the
          # picture survives, and a permanently colored screen is a style choice rather
          # than a bug.
          FULL = 100

          MESSAGE =
            "This game tints the screen fully and never lifts the tint. A full tint mixes " \
            "the color in completely, so the screen stays one flat color and the game is " \
            "not visible behind it. Anything drawn after the tint is covered too. To fix " \
            "this, use an amount of 0 when the tint is finished. For a tint over time, " \
            "move a variable from 0 to 100 and give it to `tint`."

          def detect(program)
            tints = program.each.select { |node| node.kind == :tint }
            return [] if tints.empty?

            amounts = tints.map { |node| amount_of(node) }
            return [] if amounts.any?(&:nil?)  # a tint the game works out — unknowable
            return [] if amounts.any?(&:zero?) # something does bring it back
            return [] unless amounts.max >= FULL

            [Finding.new(check: NAME, severity: :warning, message: MESSAGE, node: tints.last)]
          end

          private

          # The tint's amount when it is a plain number, or nil when the game works it out
          # as it runs.
          def amount_of(node)
            value = node.amount
            value.is_a?(Node) && value.kind == :int ? value.value : nil
          end
        end
      end
    end
  end
end
