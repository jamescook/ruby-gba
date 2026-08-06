# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# Per-scene budgets: a game that runs some scenes in direct color and others
# tear-free can't be judged against one whole-program budget. Each scene is judged
# against its OWN mode's budget — the safe window for direct, the whole frame for
# tear-free — so a heavy direct scene is caught even when a buffered scene is also
# present (which, judged whole-program, would widen the budget and hide it).
class TestPerSceneCost < CostModelTest
  include RubyGBA::IR::Build
  include CostArith

  Cost = RubyGBA::IR::CostModel

  # A two-scene game dispatched by :state: a direct-color scene and a tear-free
  # (buffered) one, each clearing the whole screen a given number of times a frame
  # (one clear = 240*160 pixels, one DMA). Built from the IR so each scene's
  # mode is explicit.
  def mixed(direct_clears:, buffered_clears:)
    program(
      screen(:bitmap),                       # boot: direct color
      set(:state, int(0)),
      func(:_scene_still, *Array.new(direct_clears) { clear_screen(:black) }), # inherits direct
      func(:_scene_action, screen(:bitmap, buffered: true),
           *Array.new(buffered_clears) { clear_screen(:black) }),             # declares tear-free
      loop_(wait_vblank, case_(:state, [[0, :_scene_still], [1, :_scene_action]])),
    )
  end

  # The same drawing work is judged differently by mode: a direct scene clearing
  # 3x a frame (115,200) overruns the brief safe window and tears; a buffered one
  # clearing 3x fits a whole frame and is fine.
  def test_each_scene_is_judged_against_its_own_mode_budget
    verdicts = Cost.new.scene_verdicts(mixed(direct_clears: 3, buffered_clears: 3))
    still  = verdicts.find { |s| s[:name] == "still" }
    action = verdicts.find { |s| s[:name] == "action" }

    assert_equal :direct, still[:mode]
    near 3 * dma_blob(240 * 160), still[:steady_cost]
    assert_equal Cost::VBLANK_BUDGET, still[:budget]
    assert still[:over], "a direct scene clearing 3x a frame overruns the safe window"

    assert_equal :buffered, action[:mode]
    near 3 * dma_blob(240 * 160), action[:steady_cost]
    assert_equal Cost::FRAME_BUDGET, action[:budget]
    refute action[:over], "the same work, buffered, fits a whole frame"
  end

  # Judging each scene against its OWN mode's budget is what catches a heavy direct
  # scene sitting beside a buffered one: the direct scene overruns the vblank window
  # (so it tears) even though its cost fits the wider whole-frame budget a buffered
  # scene gets — so a single program-wide budget would miss it.
  def test_a_heavy_direct_scene_is_caught_even_beside_a_buffered_one
    still = Cost.new.scene_verdicts(mixed(direct_clears: 3, buffered_clears: 1))
                    .find { |s| s[:name] == "still" }
    assert still[:over], "the direct scene tears on its own budget"
    assert_operator still[:steady_cost], :<, Cost::FRAME_BUDGET,
                    "yet it fits the wider whole-frame budget a buffered scene would get"
  end

  # The report prints a line per scene, each naming its mode and verdict.
  def test_report_breaks_down_per_scene
    io = StringIO.new
    Cost.new.report(mixed(direct_clears: 3, buffered_clears: 3), out: io)
    assert_match(/scene :still \(direct\).*tears/, io.string)
    assert_match(/scene :action \(tear-free\).*estimate within budget/, io.string)
  end

  # The JSON carries the per-scene breakdown for tools, in dispatch order.
  def test_json_carries_the_per_scene_breakdown
    scenes = Cost.new.as_json(mixed(direct_clears: 3, buffered_clears: 3))[:scenes]
    assert_equal %w[still action], scenes.map { |s| s[:name] }
    assert_equal %i[direct buffered], scenes.map { |s| s[:mode] }
  end
end
