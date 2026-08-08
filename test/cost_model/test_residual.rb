# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# How much of the measured frame the breakdown accounts for
# (lib/ruby_gba/ir/cost_model/verdicts.rb, #residual_note).
#
# The report has always shown an ESTIMATED tree beside a MEASURED total without ever
# relating the two, and a cost missing from the model hides perfectly in that gap: the tree
# sums to something plausible, the verdict reads correct because it is measured, and no
# line anywhere looks odd. These are the tests for saying the gap out loud.
#
# The measurement is passed in as plain data here, the same shape the CLI hands the report
# ({ scene_or_nil => { scanlines:, ... } }), so none of this needs an emulator. What the
# emulator says about real programs is test/test_cost_calibration.rb's job.
class TestCostResidual < CostModelTest
  # ~46.9 scanlines of estimate: one whole-screen clear a frame, and nothing else.
  def clearing_game
    program do
      screen :bitmap
      game_loop { clear_screen :black }
    end
  end

  def measurement(scanlines) = { nil => { scanlines: scanlines, fps: nil, saturated: false, keys: [] } }

  def estimate(prog) = Cost.new.category_tree(prog).sum { |node| node[:cost] }

  # --- when it speaks ---

  # THE CASE THIS EXISTS FOR: the frame really costs twice what the breakdown can see.
  def test_a_breakdown_that_misses_half_the_frame_is_reported
    prog = clearing_game
    note = Cost.new.residual_note(prog, measurement(estimate(prog) * 2.5))
    refute_nil note
    assert_in_delta 0.4, note[:share], 0.01
  end

  def test_the_report_says_it_at_the_top
    prog = clearing_game
    line = rendered(prog, measured: measurement(estimate(prog) * 2.5)).lines.first
    assert_match(/the breakdown accounts for 40% of the measured frame/, line)
    assert_match(/largest line below is not always the largest cost/, line)
  end

  # The caveat has to travel with the number wherever it appears. The estimate is not a
  # point prediction — it counts a list-driven loop at capacity and a `pressed` body at
  # zero — so an over-count and an under-count land in the same total and can cancel. A
  # share near 100% is therefore weak evidence of correctness, and saying only that a low
  # share is bad would let the number read as a proof it is not.
  def test_it_says_the_share_is_a_net_and_not_a_bound
    prog = clearing_game
    line = rendered(prog, measured: measurement(estimate(prog) * 2.5)).lines.first
    assert_match(/share is a net/, line)
    assert_match(/can cancel/, line)
    assert_match(/high share does not show that there is none/, line)
  end

  # The banner is red and the frame's own verdict is not. Red means "there is something to
  # fix", and here the thing to fix is the report: a game can hold 60fps — green on its
  # verdict line, where the rule about red lives — while the breakdown above it explains
  # almost none of the frame. Both facts are true at once and the colours have to show that.
  def test_it_is_red_without_making_a_fitting_frame_look_broken
    prog = clearing_game
    measured = { nil => { scanlines: estimate(prog) * 2.5, fps: 60.0, saturated: false, keys: [] } }
    out = rendered(prog, measured: measured, color: true)
    red = RubyGBA::IR::ColorPrinter::COLORS.fetch(:hot)

    assert_includes out.lines.first, red, "the banner raises the alarm about the estimate"
    verdict = out.lines.find { |line| line.include?("measured ~") }
    refute_includes verdict, red, "the game itself fits, so its verdict is not red"
  end

  # When the estimate already knows what it cannot see, the banner names it rather than
  # calling the gap a mystery.
  def test_a_known_blind_spot_is_named
    prog = program do
      screen :bitmap
      n = var :n, 0
      game_loop { clear_screen :black; repeat(n) { fill_rect 0, 0, 8, 8, :red } }
    end
    line = rendered(prog, measured: measurement(estimate(prog) * 2.5)).lines.first
    assert_match(/cannot price an unbounded loop/, line)
  end

  # A scene game is measured scene by scene, and the tree is the heaviest frame the program
  # can reach (a case_var costs its heaviest branch). So the dearest reading is the one that
  # answers the same question.
  def test_across_scenes_it_takes_the_dearest_reading
    prog = clearing_game
    scenes = { title: { scanlines: 1.0 }, playing: { scanlines: estimate(prog) * 2.5 } }
    note = Cost.new.residual_note(prog, scenes)
    assert_in_delta estimate(prog) * 2.5, note[:measured], 0.01
  end

  # --- when it stays quiet ---

  def test_an_estimate_that_matches_says_nothing
    prog = clearing_game
    assert_nil Cost.new.residual_note(prog, measurement(estimate(prog) * 1.05))
    refute_match(/the breakdown accounts for/, rendered(prog, measured: measurement(estimate(prog) * 1.05)))
  end

  # Without a measurement there is nothing to compare against, and the report already says
  # so in its own words at the bottom.
  def test_no_measurement_says_nothing
    prog = clearing_game
    assert_nil Cost.new.residual_note(prog, nil)
    refute_match(/the breakdown accounts for/, rendered(prog))
  end

  # A program with no game loop ends on `halt`, which is a branch to itself — so it spins,
  # and the reading comes back at a whole frame for every static program ever written. That
  # is a fact about `halt` and not about the estimate, and comparing against it would put a
  # banner on top of every static picture in examples/.
  def test_a_static_program_says_nothing
    static = program do
      screen :bitmap
      clear_screen :black
      draw_text "HELLO", 8, 8, :white
      halt
    end
    assert_nil Cost.new.residual_note(static, measurement(228.0))
  end

  # A game loop that does NOTHING measures about 0.2 scanlines — waking from the vblank,
  # and the branch — where the estimate says 0. So a small enough program is 0% accounted
  # for and always will be, and the share alone would fire on it. Three of the tiled
  # examples live exactly here.
  def test_a_gap_too_small_to_act_on_says_nothing
    tiny = program do
      screen :bitmap
      game_loop { fill_rect 0, 0, 10, 10, :red }
    end
    assert_operator estimate(tiny), :<, Cost::RESIDUAL_GAP
    assert_nil Cost.new.residual_note(tiny, measurement(4.0))
  end

  # Rooting the tree at one func means the breakdown is that routine, not the frame — so
  # the share would be comparing a part against the whole and reading alarmingly low.
  def test_a_focused_tree_says_nothing
    prog = program do
      screen :bitmap
      func(:paint) { clear_screen :black }
      game_loop { call :paint }
    end
    out = rendered(prog, focus: :paint, measured: measurement(estimate(prog) * 2.5))
    refute_match(/the breakdown accounts for/, out)
  end
end
