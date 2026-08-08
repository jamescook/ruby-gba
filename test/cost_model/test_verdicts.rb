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

  # A game costs what the player makes it cost, so a verdict found with a button down has
  # to say which one. Without it, "your game is fine" and "your game is fine until someone
  # plays it" read exactly the same.
  def test_a_verdict_found_with_a_button_held_names_it
    io = StringIO.new
    Cost.new.report(loop_of_clears(1, buffered: false), out: io,
                    measured: { nil => { scanlines: 228.0, fps: 30.0, saturated: true, keys: [:left] } })
    assert_match(/running at ~30\.0 fps while LEFT is held/, io.string)
    assert_match(/Each button this game reads was held in turn/, io.string)
  end

  # When nothing the player does costs more than standing still, the report says so —
  # that is the reader's licence to trust the number.
  def test_a_verdict_no_button_made_dearer_says_input_was_tried
    io = StringIO.new
    Cost.new.report(loop_of_clears(1, buffered: false), out: io,
                    measured: { nil => { scanlines: 40.0, fps: nil, saturated: false, keys: [] } })
    assert_match(/No button cost more than none held/, io.string)
    refute_match(/while .* is held/, io.string)
  end

  # Several buttons at once (the profiler will hold exactly what a dev names) reads as a
  # plural, not "LEFT+A is held".
  def test_several_held_buttons_read_as_a_plural
    io = StringIO.new
    Cost.new.report(loop_of_clears(1, buffered: false), out: io,
                    measured: { nil => { scanlines: 90.0, fps: nil, saturated: false, keys: %i[left a] } })
    assert_match(/while LEFT\+A are held/, io.string)
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

  # --- a timer's tick handler: the other place a frame goes outside the loop ---

  # A timer runs its body off its own clock, at a rate written on the `timer` and not on the
  # handler, so nothing where the body is written says how often it runs. At 4000 a second
  # that is 67 times a frame.
  def ticking_game(per_second: 4000, ops: 1)
    program do
      screen :bitmap
      n = var :n, 0
      timer(:beat, per_second: per_second).on_tick { ops.times { n.add 1 } }
      game_loop { }
    end
  end

  def test_a_tick_handler_costs_the_frame_something
    v = Cost.new.tick_verdict(ticking_game)
    assert_equal 1, v[:timers].length
    assert_equal :beat, v[:timers].first[:name]
    assert_in_delta 4000 / 60.0, v[:timers].first[:ticks], 0.01
    assert_operator v[:cost], :>, 1, "67 ticks a frame is real work"
  end

  # It is judged against the WHOLE frame, like the mixer and a bend: it is CPU spread through
  # the frame that touches no video memory, so it can cost a frame its rate but never tear it.
  def test_a_tick_handler_is_priced_against_the_frame_budget
    assert_equal Cost::FRAME_BUDGET, Cost.new.tick_verdict(ticking_game)[:budget]
  end

  # Twice the rate, twice the cost — the whole point, since the rate is the thing the reader
  # cannot see from the handler.
  def test_the_cost_follows_the_rate
    slow = Cost.new.tick_verdict(ticking_game(per_second: 2000))[:cost]
    fast = Cost.new.tick_verdict(ticking_game(per_second: 4000))[:cost]
    assert_in_delta slow * 2, fast, 0.001
  end

  # The body is charged too, per tick, so a dear handler reads as dear rather than hiding
  # behind the fixed interrupt cost.
  def test_the_bodys_own_work_is_charged_per_tick
    one = Cost.new.tick_verdict(ticking_game(ops: 1))
    ten = Cost.new.tick_verdict(ticking_game(ops: 10))
    assert_operator ten[:timers].first[:body], :>, one[:timers].first[:body] * 5
    assert_in_delta one[:timers].first[:interrupts], ten[:timers].first[:interrupts], 0.001,
                    "the interrupt costs the same whatever the body does"
  end

  # ...but for a short body the interrupt is the bigger half, which is the shape a reader
  # guesses wrong: they shorten the body and most of the cost stays.
  def test_a_short_handler_is_mostly_interrupt
    t = Cost.new.tick_verdict(ticking_game(ops: 1))[:timers].first
    assert_operator t[:interrupts], :>, t[:body] * 4
  end

  # A program with no timer handler pays nothing and says nothing.
  def test_a_program_with_no_tick_handler_has_no_tick_cost
    assert_nil Cost.new.tick_verdict(silent_game)
    assert_equal 0, Cost.new.tick_cost(silent_game)
  end

  # A handler on a timer that was never started never runs, so it costs nothing. There is no
  # rate to work from either, which would otherwise be a crash.
  def test_a_handler_on_a_timer_that_never_started_costs_nothing
    prog = Build.program(Build.screen(:bitmap),
                         Build.on_timer(:ghost, Build.set(:n, Build.int(1))),
                         Build.loop_(Build.wait_vblank))
    assert_nil Cost.new.tick_verdict(prog)
  end

  # The frame total has to include it. Without this a program whose whole frame is a fast
  # timer reads as costing nothing — the same silent zero a bend had.
  def test_the_frame_total_includes_the_tick_handler
    total = Cost.new.as_json(ticking_game)[:frame_cost]
    assert_in_delta Cost.new.tick_cost(ticking_game), total, 0.001
    assert_operator total, :>, 1
  end

  # And the tree gives it a line, so `hottest` can name it.
  def test_the_tree_gives_a_tick_handler_a_line
    leaf = leaves(Cost.new.category_tree(ticking_game)).find { |node| node[:op] == :tick }
    refute_nil leaf, "a frame spent in a tick handler has to appear in the tree"
    assert_match(/timer :beat/, leaf[:label])
    assert_match(/67 times a frame/, leaf[:label])
  end

  # Keeping the routine a tick lands in in faster memory makes it genuinely cheaper, and by
  # LESS than ordinary code gains — part of an interrupt is the console's own work. Both
  # cases are measured.
  def test_the_estimate_follows_the_tick_into_quick_memory
    cart = Cost.new.tick_verdict(ticking_game)[:cost]
    quick = Cost.new(fast_interrupts: true).tick_verdict(ticking_game)[:cost]
    assert_operator quick, :<, cart

    gain = Cost::DEFAULT_WEIGHTS[:tick_interrupt] / Cost::DEFAULT_WEIGHTS[:tick_interrupt_fast]
    assert_operator gain, :>, 1.2
    assert_operator gain, :<, Cost::DEFAULT_WEIGHTS[:fast_code_speedup]
  end

  # A busy timer is named in the budget section with both halves apart, the same as a bend.
  def test_the_report_names_what_a_busy_timer_costs
    out = reported(ticking_game)
    assert_match(/timer :beat costs/, out)
    assert_match(/ticks 4000 times a second/, out)
    assert_match(/interrupts/, out)
  end

  # A timer slow enough to cost nothing gets no budget line — most timers tick a handful of
  # times a second, and a line reading "~<0.1" only teaches a reader to skip the section. It
  # is still in the tree.
  def test_a_slow_timer_gets_no_budget_line
    prog = ticking_game(per_second: 2)
    refute_match(/timer :beat costs/, reported(prog))
    refute_nil leaves(Cost.new.category_tree(prog)).find { |node| node[:op] == :tick }
  end
end
