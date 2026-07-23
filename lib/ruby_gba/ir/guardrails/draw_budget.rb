# frozen_string_literal: true

require_relative "../cost_model"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # The console draws to a single screen the TV is reading at the same time,
        # and there's only a brief safe window each frame to change it. A game that
        # does more drawing than fits in that window spills into the visible frame,
        # so the picture tears — a jagged, flickering image, often with the last
        # thing drawn missing — and it gets worse as the game grows. The classic
        # cause is clearing and repainting the whole screen every frame.
        #
        # This is the cost-model-driven warning: it estimates the *steady* per-frame
        # drawing (what recurs every frame — a once-per-round transition or an
        # every() tick doesn't count) and flags it when it's over the budget. Like
        # the other soft checks it's advisory, not an error: the estimate is rough,
        # and the build still produces a ROM. `rom.explain` shows the breakdown.
        class DrawBudget
          NAME = :draw_budget

          def detect(program)
            model = CostModel.new
            return [] unless model.looping?(program)

            steady = model.steady_cost(program)
            return [] if steady <= CostModel::VBLANK_BUDGET

            [Finding.new(check: NAME, severity: :warning, message: message(steady), fix: nil)]
          end

          private

          def message(steady)
            "This game looks like it draws a lot every frame (roughly #{steady} vs a budget of about " \
              "#{CostModel::VBLANK_BUDGET}) — more than the console can finish in the brief moment it has to " \
              "change the screen, so the picture may tear or flicker, and worse as things grow. The usual " \
              "cause is clearing and repainting the whole screen each frame: instead, draw the parts that " \
              "don't change once, and each frame repaint only what actually moved. Call `rom.explain` on the " \
              "built ROM to see where the per-frame drawing goes."
          end
        end
      end
    end
  end
end
