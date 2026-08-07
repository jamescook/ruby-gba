# frozen_string_literal: true

require "test_helper"

require_relative "helper"
require_relative "../conformance_fixture"

# Judging the total (lib/ruby_gba/ir/cost_model/verdicts.rb): which budget applies,
# whether it fits, and what the estimate admits it cannot see.
class TestCostVerdicts < CostModelTest
  # Self-audit: the conformance fixture exercises every IR kind, so the model must have
  # an estimate (or a deliberate free classification) for each — nothing it touches
  # should be flagged unpriced. This is what catches a new op added without a cost.
  def test_the_cost_model_understands_every_ir_kind
    assert_empty Cost.new.unpriced_kinds(ConformanceFixture.program),
                 "these kinds have no cost estimate — price them in op_cost/expr_cost, or add to a FREE_*_KINDS list"
  end

  # The audit above is only worth anything if it reads the WHOLE program. Asking it for a
  # frame is what let camera, fade and save_store sit unpriced for so long: the fixture
  # keeps every kind above its game loop, so a frame walk saw `wait_vblank, halt` and had
  # nothing to report — while three real ops were being counted as free.
  def test_an_unpriced_op_outside_the_game_loop_is_still_found
    mystery = RubyGBA::IR::Node.new(:mystery_op)
    prog = Build.program(Build.screen(:bitmap), mystery, Build.loop_(Build.wait_vblank, Build.halt))
    assert_includes Cost.new.unpriced_kinds(prog), :mystery_op
  end

  # An op the model can't price is announced loudly at the very top of the estimate,
  # rather than silently counted as free.
  def test_an_unpriced_op_is_announced_at_the_top
    mystery = RubyGBA::IR::Node.new(:mystery_op)
    prog = Build.program(Build.screen(:bitmap), Build.loop_(Build.wait_vblank, mystery))
    cost = Cost.new
    assert_includes cost.unpriced_kinds(prog), :mystery_op

    io = StringIO.new
    cost.render(prog, out: io)
    assert_match(/cannot estimate: .*mystery_op/, io.string.lines.first, "the warning leads the output")
  end

  # A program the model fully understands prints no such warning.
  def test_a_fully_priced_program_has_no_warning
    prog = program do
      screen :bitmap
      game_loop { clear_screen :black }
    end
    io = StringIO.new
    Cost.new.render(prog, out: io)
    refute_match(/can't estimate/, io.string)
  end

  # --- mode-aware budget: double buffering draws to a hidden page, so it gets the
  # whole frame to draw (not just the brief safe window) and can't tear ---

  # The SAME drawing is judged against a different budget by mode: the brief
  # vblank window single-buffered, the whole frame (much larger) double-buffered.
  def test_buffered_screen_is_judged_against_the_whole_frame_budget
    single = loop_of_clears(3, buffered: false) # 3 whole-screen clears a frame
    double = loop_of_clears(3, buffered: true)

    # each priced by the screen it is on — the tear-free one clears for half the work,
    # because a pixel there is one byte where a direct-color one is two...
    near 3 * dma_blob(240 * 160), Cost.new.steady_cost(single)
    near 3 * tearfree_clear, Cost.new.steady_cost(double)

    # ...but a different budget applies, and only one calls it buffered.
    assert_equal Cost::VBLANK_BUDGET, Cost.new.budget_for(single) # the vblank window (68 scanlines)
    assert_equal Cost::FRAME_BUDGET, Cost.new.budget_for(double)  # the whole frame (228 scanlines)
    refute Cost.new.buffered?(single)
    assert Cost.new.buffered?(double)
  end

  # 3 whole-screen clears a frame are over the single-buffer window (so it tears) but
  # under a whole frame (so buffered it's fine) — the verdict wording says which.
  def test_verdict_wording_reflects_the_mode
    io = StringIO.new
    Cost.new.report(loop_of_clears(3, buffered: false), out: io)
    assert_match(/over — the screen tears/, io.string)

    io = StringIO.new
    Cost.new.report(loop_of_clears(3, buffered: true), out: io)
    assert_match(/estimate within budget/, io.string)
    assert_match(/double-buffered — drawing can't tear/, io.string)
  end

  # With no measurement, the report is an estimate and says so plainly — it does not
  # pretend to have run the game or promise a frame rate.
  def test_estimate_only_says_the_emulator_did_not_run
    prog = program do
      screen :bitmap
      var :state, 0
      scene(:title) { clear_screen :blue }
      scene(:play)  { clear_screen :red }
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    io = StringIO.new
    Cost.new.report(prog, out: io)
    assert_match(/estimate only/, io.string)
    assert_match(/the emulator did not run/, io.string)
  end

  # A measurement folds in as the verdict: the report reads the real per-frame number and
  # drops the estimate's own within/over verdict.
  def test_a_measured_verdict_replaces_the_estimate_verdict
    io = StringIO.new
    Cost.new.report(loop_of_clears(1, buffered: false), out: io, measured: { nil => { scanlines: 40.0, fps: nil, saturated: false } })
    assert_match(/measured ~40\.0 of #{Cost::FRAME_BUDGET} scanlines/, io.string)
    refute_match(/estimate within budget/, io.string)
    refute_match(/estimate only/, io.string)
  end

  # Even double buffering has a ceiling: draw more than fits in a whole frame and
  # the frame rate drops (it still never tears).
  def test_buffered_over_a_whole_frame_reads_as_a_dropped_frame_not_tearing
    io = StringIO.new
    Cost.new.report(loop_of_clears(10, buffered: true), out: io)
    assert_match(/estimate over budget/, io.string)
    refute_match(/tears/, io.string)
  end

  # --- the software mixer: real per-frame CPU the estimate must account for ---

  # It's judged against the WHOLE FRAME (the 60fps deadline), not the vblank window —
  # the mixer is CPU work after wait_vblank and draws nothing.
  def test_the_mixer_is_priced_against_the_frame_budget
    v = Cost.new.mixer_verdict(sample_game)
    assert_equal Cost::FRAME_BUDGET, v[:budget]
    assert_equal Cost::MIXER_VOICES, v[:voices]
  end

  # A silent program has no mixer cost and no sound section.
  def test_no_mixer_for_a_silent_program
    assert_nil Cost.new.mixer_verdict(silent_game)
    assert_nil Cost.new.category_tree(silent_game).find { |c| c[:category] == :sound }
  end

  # Its cost grows with the buffer it fills each frame — a higher sample rate means
  # more samples per frame, so more mixing.
  def test_the_mixer_cost_grows_with_the_sample_rate
    low = Cost.new.mixer_verdict(sample_game(rate: 8000))
    high = Cost.new.mixer_verdict(sample_game(rate: 16000))
    assert_operator high[:samples_per_frame], :>, low[:samples_per_frame]
    assert_operator high[:cost], :>, low[:cost]
  end
end
