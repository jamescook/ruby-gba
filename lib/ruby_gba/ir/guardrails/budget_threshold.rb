# frozen_string_literal: true

require_relative "../cost_model"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A game that draws a growing collection item by item every frame — a snake's
        # body, a swarm of enemies, a field of bullets — does more drawing the more
        # the collection holds. It can look fine while small and start to tear or slow
        # only once it grows, which is a baffling bug to hit late. Where the draw-budget
        # check says "this frame draws too much", this one says *how big the collection
        # can get before it does* — the tip-over count — and points at the list to cap.
        #
        # It leans on the cost model's parametric analysis (which count crosses the
        # budget) and only speaks when that count is reachable within the list's
        # declared capacity. Advisory, like the other soft checks: the estimate is
        # rough and the build still produces a ROM.
        class BudgetThreshold
          NAME = :budget_threshold

          def detect(program)
            CostModel.new.budget_thresholds(program).map do |threshold|
              Finding.new(check: NAME, severity: :warning, message: message(threshold), fix: nil)
            end
          end

          private

          def message(threshold)
            "The :#{threshold[:list]} list is drawn item by item every frame, so the more it holds the more the " \
              "frame draws. Past about #{threshold[:break_even]} items it goes over the frame budget and the " \
              "picture starts to tear or slow — but :#{threshold[:list]} can grow to #{threshold[:cap]}. Cap it " \
              "lower (nearer #{threshold[:break_even]}), or draw less per item — repaint only what moved instead " \
              "of the whole list each frame. Call `rom.explain` on the built ROM to see the per-frame breakdown."
          end
        end
      end
    end
  end
end
