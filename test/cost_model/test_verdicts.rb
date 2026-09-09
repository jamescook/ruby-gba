# frozen_string_literal: true

require "test_helper"

require_relative "helper"
require_relative "../conformance_fixture"

# Judging the total (lib/ruby_gba/ir/cost_model/verdicts.rb): which budget applies,
# whether it fits, and what the estimate admits it cannot see.
class TestCostVerdicts < CostModelTest
  # A kind the model has never been taught. Every kind this library declares HAS a price, so
  # the only way to have one that doesn't is a node class from outside — which is the case
  # the unpriced banner exists for.
  MysteryOp = Class.new do
    include RubyGBA::IR::Node
    kind :mystery_op
    category :draw
  end

  # Self-audit: the conformance fixture exercises every IR kind, so the model must have
  # an estimate (or a deliberate free classification) for each — nothing it touches
  # should be flagged unpriced. This is what catches a new op added without a cost.
  def test_the_cost_model_understands_every_ir_kind
    assert_empty Cost.new.unpriced_kinds(ConformanceFixture.program),
                 "these kinds have no cost estimate — price them in op_cost/expr_cost, or add to a FREE_*_KINDS list"
  end

  # ...and the same on a REAL CARTRIDGE, which is the path a person actually reads. The audit
  # above prices a program nobody built, and that is a different route through the model: with
  # a build behind it a statement is priced by counting what the lowering emitted, so the
  # weights the audit walks are not the ones a report reads. The two have to be asked
  # separately, and this one caught a whole banner of value kinds reported as unpriced on
  # every example there was.
  def test_a_built_cartridge_prices_every_kind_it_uses
    rom = RubyGBA.build("AUDIT", code: "BAUD", maker: "01", err: StringIO.new) do
      screen :bitmap
      xs = list :xs, capacity: 8
      t = table :tbl, (0...8).to_a
      i = var :i, 0
      y = var :y, 0
      game_loop do
        y.set(xs[i] + t[i])
        (y > 3).then { y.set(y / 2) }
      end
    end

    assert_empty rom.cost_model.unpriced_kinds(rom.source_program),
                 "a report on this cartridge would open with a banner saying it cannot price them"
  end

  # The audit above is only worth anything if it reads the WHOLE program. Asking it for a
  # frame is what let camera, fade and save_store sit unpriced for so long: the fixture
  # keeps every kind above its game loop, so a frame walk saw `wait_vblank, halt` and had
  # nothing to report — while three real ops were being counted as free.
  def test_an_unpriced_op_outside_the_game_loop_is_still_found
    mystery = MysteryOp.new
    prog = Build.program(Build.screen(:bitmap), mystery, Build.loop_(Build.wait_vblank, Build.halt))
    assert_includes Cost.new.unpriced_kinds(prog), :mystery_op
  end

  # An op the model can't price is announced loudly at the very top of the estimate,
  # rather than silently counted as free.
  def test_an_unpriced_op_is_announced_at_the_top
    mystery = MysteryOp.new
    prog = Build.program(Build.screen(:bitmap), Build.loop_(Build.wait_vblank, mystery))
    cost = Cost.new
    assert_includes cost.unpriced_kinds(prog), :mystery_op

    io = StringIO.new
    cost.render(prog, out: io)
    assert_match(/cannot estimate: .*mystery_op/, io.string.lines.first, "the warning leads the output")
  end

  # --- a price that is not a number ---
  #
  # THE ONE FAILURE THAT READS AS SUCCESS. Every budget verdict is a comparison and every
  # comparison against a NaN answers false, so a broken estimate does not report over budget,
  # does not warn about tearing, and looks exactly like a game that comfortably fits. It got
  # through once: three examples estimated NaN with the whole suite green, and only the
  # emulator-backed corpus check noticed.

  # One weight set to a NaN, which is the shape of the real fault without depending on which
  # arithmetic produced it — the model's own what-if override does the work.
  def a_pixel_a_frame
    Build.program(Build.screen(:bitmap),
                  Build.loop_(Build.wait_vblank, Build.pixel(Build.int(1), Build.int(1), 0)))
  end

  def test_a_price_that_is_not_a_number_is_named
    assert_includes Cost.new(plot_pixel: Float::NAN).nonsense_kinds(a_pixel_a_frame), :pixel
  end

  # ...and the report REFUSES rather than passing. This is the assertion that matters: the
  # budget line must not say the frame fits.
  def test_a_frame_that_cannot_be_priced_refuses_to_say_it_fits
    io = StringIO.new
    Cost.new(plot_pixel: Float::NAN).render(a_pixel_a_frame, out: io)

    assert_match(/is not a number/, io.string, "the fault is announced")
    assert_match(/cannot be judged/, io.string, "and the budget refuses")
    refute_match(/within budget/, io.string, "a broken estimate must never read as fitting")
  end

  # THE TRAP THAT PRODUCED THE REAL ONE, pinned at the level it lives at rather than through a
  # program, and deliberately so: no pricing path reaches it today, because everything inside
  # an op goes through #raw_expr_cost. The guard is there so the NEXT path is safe, and a test
  # driven through a program would pass whether the guard existed or not.
  #
  # Pricing an op for the share the quick memory cannot reach swaps in a table where every
  # other weight is zero — the speed-up among them. A table of quick-memory weights worked out
  # from THAT one would divide by nought, and one NaN spreads through a whole frame until every
  # budget comparison answers false, which reads as "this fits". So the quick table is worked
  # out once, from the real weights, and the zeroed pass does not swap it in at all.
  def test_the_weights_stay_numbers_while_the_table_is_zeroed
    model = Cost.new(fast_frame: true)
    model.send(:index, a_pixel_a_frame)
    pricing = model.instance_variable_get(:@pricing)

    model.instance_variable_get(:@walker).in_fast_frame do
      pricing.with_consoles_own_weights do
        assert_predicate pricing.weight_here(:op_step).to_f, :finite?,
                         "a quick-memory weight worked out from a zeroed table is a NaN"
      end
    end
  end

  # ...and the table itself holds numbers for every weight, gain or no gain. A weight the
  # calibration could not divide falls back to the general figure rather than to nothing.
  def test_every_weight_has_a_quick_memory_price
    pricing = Cost.new.instance_variable_get(:@pricing) ||
              (Cost.new.tap { |m| m.send(:index, a_pixel_a_frame) }.instance_variable_get(:@pricing))
    quick = pricing.quick_weights(Cost::DEFAULT_WEIGHTS)

    assert_equal Cost::DEFAULT_WEIGHTS.keys, quick.keys
    quick.each { |name, value| assert_predicate value.to_f, :finite?, "#{name} has no quick price" }
  end

  # Every example a player could build has a finite estimate. Cheap, and it is the assertion
  # the suite was missing when three of them went NaN.
  def test_a_real_game_prices_to_a_number
    prog = program do
      screen :bitmap
      level = var :level, 0
      game_loop do
        clear_screen :black
        fade :black, level
        draw_text "SCORE", 8, 8, :white
      end
    end

    assert_predicate Cost.new.steady_cost(prog).to_f, :finite?
    assert_empty Cost.new.nonsense_kinds(prog)
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
    near frame_boundary + (3 * dma_blob(240 * 160)), Cost.new.steady_cost(single)
    near frame_boundary + (3 * tearfree_clear), Cost.new.steady_cost(double)

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
  # pretend to have run the game or promise a frame rate — and it says how to get one,
  # because a reader who wants to know whether the game fits has no other way to find out.
  def test_estimate_only_says_the_game_did_not_run_and_how_to_run_it
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
    assert_match(/the game did not run/, io.string)
    assert_match(/measured: true/, io.string)
  end

  # ...and when a measurement WAS asked for and there was no emulator to take it on, the
  # advice is what to build, not to ask again.
  def test_estimate_only_says_what_the_measurement_needs_when_there_was_no_emulator
    io = StringIO.new
    Cost.new.report(loop_of_clears(1, buffered: false), out: io, unmeasured: :no_emulator)
    assert_match(/estimate only/, io.string)
    assert_match(/needs the emulator/, io.string)
    refute_match(/measured: true/, io.string)
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
    assert_equal Cost::FRAME_BUDGET, v.budget
    assert_equal Cost::MIXER_VOICES, v.voices
  end

  # A silent program has no mixer cost and no sound section.
  def test_no_mixer_for_a_silent_program
    assert_nil Cost.new.mixer_verdict(silent_game)
    assert_nil Cost.new.category_tree(silent_game).find { |c| c.category == :sound }
  end

  # Its cost grows with the buffer it fills each frame — a higher sample rate means
  # more samples per frame, so more mixing.
  def test_the_mixer_cost_grows_with_the_sample_rate
    low = Cost.new.mixer_verdict(sample_game(rate: 8000))
    high = Cost.new.mixer_verdict(sample_game(rate: 16000))
    assert_operator high.samples_per_frame, :>, low.samples_per_frame
    assert_operator high.cost, :>, low.cost
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
    assert_equal 1, v.timers.length
    assert_equal :beat, v.timers.first.name
    assert_in_delta 4000 / 60.0, v.timers.first.ticks, 0.01
    assert_operator v.cost, :>, 1, "67 ticks a frame is real work"
  end

  # It is judged against the WHOLE frame, like the mixer and a bend: it is CPU spread through
  # the frame that touches no video memory, so it can cost a frame its rate but never tear it.
  def test_a_tick_handler_is_priced_against_the_frame_budget
    assert_equal Cost::FRAME_BUDGET, Cost.new.tick_verdict(ticking_game).budget
  end

  # Twice the rate, twice the cost — the whole point, since the rate is the thing the reader
  # cannot see from the handler.
  def test_the_cost_follows_the_rate
    slow = Cost.new.tick_verdict(ticking_game(per_second: 2000)).cost
    fast = Cost.new.tick_verdict(ticking_game(per_second: 4000)).cost
    assert_in_delta slow * 2, fast, 0.001
  end

  # The body is charged too, per tick, so a dear handler reads as dear rather than hiding
  # behind the fixed interrupt cost.
  def test_the_bodys_own_work_is_charged_per_tick
    one = Cost.new.tick_verdict(ticking_game(ops: 1))
    ten = Cost.new.tick_verdict(ticking_game(ops: 10))
    assert_operator ten.timers.first.body, :>, one.timers.first.body * 5
    assert_in_delta one.timers.first.interrupts, ten.timers.first.interrupts, 0.001,
                    "the interrupt costs the same whatever the body does"
  end

  # ...but for a short body the interrupt is the bigger half, which is the shape a reader
  # guesses wrong: they shorten the body and most of the cost stays.
  def test_a_short_handler_is_mostly_interrupt
    t = Cost.new.tick_verdict(ticking_game(ops: 1)).timers.first
    assert_operator t.interrupts, :>, t.body * 4
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
    assert_in_delta Cost.new.tick_cost(ticking_game) + frame_boundary, total, 0.001
    assert_operator total, :>, 1
  end

  # And the tree gives it a line, so `hottest` can name it.
  def test_the_tree_gives_a_tick_handler_a_line
    leaf = leaves(Cost.new.category_tree(ticking_game)).find { |node| node.op == :tick }
    refute_nil leaf, "a frame spent in a tick handler has to appear in the tree"
    assert_match(/timer :beat/, leaf.label)
    assert_match(/67 times a frame/, leaf.label)
  end

  # Keeping the routine a tick lands in in faster memory makes it genuinely cheaper, and by
  # LESS than ordinary code gains — part of an interrupt is the console's own work. Both
  # cases are measured.
  def test_the_estimate_follows_the_tick_into_quick_memory
    cart = Cost.new.tick_verdict(ticking_game).cost
    quick = Cost.new(fast_interrupts: true).tick_verdict(ticking_game).cost
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
    refute_nil leaves(Cost.new.category_tree(prog)).find { |node| node.op == :tick }
  end

  # --- what band the estimate carries ---

  # A single-buffered loop whose every-frame cost lands within a tenth of +limit+, on the side
  # +over+ says. Found by growing one fill until the model prices it there, and asserted to be
  # there — so a recalibration that moves it out of the band fails here rather than passing
  # on the wrong words.
  def loop_near(limit, over:)
    band = over ? (limit..(limit * (1 + Cost::Verdicts::MARGIN))) : ((limit * (1 - Cost::Verdicts::MARGIN))..limit)
    prog = (1..160).lazy.map { |h| single_fill(h) }.find do |p|
      cost = Cost.new.frame_cost(p)
      band.cover?(cost) && (cost > limit) == over
    end
    refute_nil prog, "no fill lands within a tenth of #{limit} on that side"
    prog
  end

  def single_fill(height)
    Build.program(Build.screen(:bitmap), Build.loop_(Build.wait_vblank, Build.fill_rect(0, 0, 240, height, :red)))
  end

  def warm = RubyGBA::IR::ColorPrinter::COLORS[:warm]

  # THE POINT. The estimate is within a tenth of the console on most of the corpus, so a frame
  # within a tenth of the line is on neither side of it, and "ok" would be a claim the estimate
  # cannot make. Ninety-five percent of the vblank and sixty percent of it must not read the same.
  def test_a_frame_within_a_tenth_of_the_vblank_reads_close_not_ok
    out = rendered(loop_near(Cost::VBLANK_BUDGET, over: false), color: true)
    line = out.lines.find { |l| l.include?("tearing") }

    assert_match(/ok, but close/, line)
    assert_match(/a tenth out/, line)
    assert_match(/no measurement can see a tear/, line, "and says a measurement cannot settle this one")
    assert_includes line, warm, "hedged, so warm — not the green of a frame that fits"
  end

  def test_a_frame_just_over_the_vblank_reads_over_but_close
    line = reported(loop_near(Cost::VBLANK_BUDGET, over: true)).lines.find { |l| l.include?("tearing") }

    assert_match(/! over, but close/, line)
    refute_match(/the screen tears/, line, "not a certainty the estimate does not have")
  end

  # ...and a frame comfortably inside says so plainly, with nothing hedged.
  def test_a_frame_well_inside_the_vblank_is_not_called_close
    line = reported(loop_of_clears(1, buffered: false)).lines.find { |l| l.include?("tearing") }

    assert_match(/ok — no tearing/, line)
    refute_match(/close/, line)
  end

  # The frame's own verdict has the same band, and the way to settle it — a measured run.
  def test_a_frame_within_a_tenth_of_the_budget_says_to_measure_it
    out = reported(loop_near(Cost::FRAME_BUDGET, over: false))
    assert_match(/estimate within budget, but close .* measure it to be sure/, out)

    out = reported(loop_near(Cost::FRAME_BUDGET, over: true))
    assert_match(/! estimate over budget, but close .* measure it to be sure/, out)
  end

  # --- what only the estimate can answer ---

  # Beside a measured verdict the tearing line is still the estimate's whenever the readings
  # carry no tear of their own, and it says so — or the measured column reads as the
  # authority on the line next to it. These readings are handed over as numbers rather than
  # run, so there is no tear in them, and the note says which of its two reasons applies.
  def test_beside_a_measurement_with_no_tear_read_the_verdict_says_it_is_the_estimates
    reading = { nil => { scanlines: 40.0, fps: nil, saturated: false } }
    out = reported(loop_of_clears(1, buffered: false), measured: reading)

    assert_match(/tearing is the estimate's alone/, out)
    assert_match(/these readings do not include one/, out)
  end

  # ...and a run that DID read one says what it saw, rather than deferring to the estimate.
  # The reading travels as plain numbers, the way Analyzer::Result#for_report hands it over.
  def test_a_measured_tear_is_the_verdict
    reading = { nil => { scanlines: 40.0, fps: nil, saturated: false,
                         torn_rows: 12, torn_from: 30, torn_to: 41 } }
    out = reported(loop_of_clears(1, buffered: false), measured: reading)

    assert_match(/tearing  measured — the display showed 12 rows before the game finished them/, out)
    assert_match(/rows 30 to 41/, out)
    refute_match(/tearing is the estimate's alone/, out)
  end

  # THE WORST FRAME AND THE USUAL ONE ARE TWO ANSWERS, and the budget line gives both when
  # they differ. The number a budget is about is the worst — a frame that does not fit tears,
  # however rare it is — but a reader holding that against the "every frame" estimate above
  # would think the estimate badly wrong when it is right. examples/pacman.rb measures 4.1 at
  # its worst and 2.5 the rest of the time, against an estimate of 2.6.
  def test_a_frame_with_rare_work_reports_the_usual_one_beside_the_worst
    reading = { nil => { scanlines: 40.0, typical: 12.0, fps: nil, saturated: false } }
    out = reported(loop_of_clears(1, buffered: false), measured: reading)

    assert_match(/measured ~40\.0 of 228 scanlines/, out)
    assert_match(/a usual frame ~12\.0/, out)
  end

  # ...and says nothing when the frame is the same every time, rather than printing one number
  # twice. Most programs are this one.
  def test_a_uniform_frame_is_not_told_its_own_cost_twice
    reading = { nil => { scanlines: 40.0, typical: 39.5, fps: nil, saturated: false } }
    out = reported(loop_of_clears(1, buffered: false), measured: reading)

    assert_match(/measured ~40\.0 of 228 scanlines/, out)
    refute_match(/a usual frame/, out)
  end

  # A run that looked and found nothing says THAT, which is the answer the estimate could
  # never give.
  def test_a_measured_run_that_found_no_tear_says_so
    reading = { nil => { scanlines: 40.0, fps: nil, saturated: false,
                         torn_rows: 0, torn_from: nil, torn_to: nil } }
    out = reported(loop_of_clears(1, buffered: false), measured: reading)

    assert_match(/tearing  measured — every row was finished before the display showed it/, out)
    assert_match(/ok — no tearing/, out)
  end

  def test_a_double_buffered_game_has_no_tearing_to_be_unsure_of
    reading = { nil => { scanlines: 40.0, fps: nil, saturated: false } }
    out = reported(loop_of_clears(1, buffered: true), measured: reading)

    refute_match(/tearing is the estimate's alone/, out)
  end
end
