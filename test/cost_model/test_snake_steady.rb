# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# The headline outcome for the game developer: with selectivity, the estimator
# tells the truth about the SHIPPED (incremental) Snake — its steady per-frame work
# fits the budget, even though the full cost of a menu/transition frame (which
# repaints the whole board once) does not. Without selectivity the estimate would
# cry wolf on a game that plays tear-free.
class TestSnakeSteadyCost < CostModelTest
  Cost = RubyGBA::IR::CostModel

  def test_incremental_snake_steady_fits_though_a_transition_frame_does_not
    require_relative "../../examples/snake"
    model = Cost.new
    assert_operator model.steady_drawing_cost(Snake.program), :<=, Cost::VBLANK_BUDGET,
                    "steady per-frame drawing should fit the vblank window — the game plays tear-free"
    assert_operator model.frame_cost(Snake.program), :>, Cost::VBLANK_BUDGET,
                    "a transition frame (whole-board repaint) is heavy — that's the spike selectivity discounts"
  end
end
