# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# The tick-rate guardrail, and the pricing behind it.
#
# A timer interrupts the game a fixed number of times a second and the handler has until the
# next tick to finish. It is not a queue: a tick that arrives while the last one is still being
# answered is LOST. So a handler that outruns the gap answers every second tick, or every
# third, and the game runs at a fraction of the rate its author wrote down — with no crash, no
# glitch, and the rate written on a `timer` line far from the handler that makes it too much.
#
# The rule is measured, not assumed, and the last test here is the one that measures it.
class TestTickRateGuardrail < Minitest::Test
  Check = RubyGBA::IR::Guardrails::Checks::TickRate
  Cost = RubyGBA::IR::CostModel

  # A timer at +hz+ whose handler is +ops+ statements long.
  def timed_game(hz:, ops:)
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      ticks = var :ticks, 0
      filler = var :filler, 0
      timer(:beat, per_second: hz).on_tick do
        ticks.add 1
        (ops - 1).times { filler.add 1 }
      end
      game_loop { }
    end
    b.emit_pending_functions
    b.program
  end

  # --- what the model charges ---

  # A handler with room to spare is charged for every tick it was asked for.
  def test_a_handler_that_keeps_up_is_priced_at_the_rate_it_asked_for
    timer = Cost.new(fast_interrupts: true).tick_verdict(timed_game(hz: 8_000, ops: 20)).timers.first

    assert_equal 8_000, timer.delivered
    assert_in_delta 8_000 / 60.0, timer.ticks, 0.01
  end

  # One that cannot is charged for the ticks the console can deliver, which is the rate
  # divided by whole steps: at a little under two gaps per tick it answers every second one.
  # Priced at the rate ASKED, the estimate read twice what the console spends.
  def test_a_handler_that_cannot_keep_up_is_priced_at_what_the_console_delivers
    timer = Cost.new(fast_interrupts: true).tick_verdict(timed_game(hz: 30_000, ops: 80)).timers.first

    assert_equal 15_000, timer.delivered, "a handler over one gap long answers every second tick"
    assert_operator timer.cost, :<, 30_000 / 60.0 * timer.each,
                    "and is charged for the ticks it answers, not the ticks it was sent"
  end

  # --- what the author is told ---

  def test_a_handler_that_loses_ticks_warns_and_names_the_rate_that_fits
    findings = Check.new.detect(timed_game(hz: 30_000, ops: 80))

    assert_equal 1, findings.length
    assert findings.first.warning?, "it is advisory — a game may want as many ticks as it can get"
    assert_match(/30000 ticks a second/, findings.first.message, "what was asked for")
    assert_match(/per_second: 15000/, findings.first.message, "and what would actually arrive")
  end

  # A handler with room to spare says nothing, which is what keeps the warning worth reading.
  def test_a_handler_that_keeps_up_is_quiet
    assert_empty Check.new.detect(timed_game(hz: 8_000, ops: 20))
    assert_empty Check.new.detect(timed_game(hz: 4_000, ops: 80))
  end

  # THE NARROW CASE, and the one that decides whether this warning can be trusted: a handler
  # that keeps up ONLY because the build keeps it in the console's quick memory. Priced at
  # cartridge speed it looks two and a half times too slow and this cries wolf; measured, the
  # console delivers every one of its 30,000 ticks. A guardrail runs before the build has
  # decided where anything lives, so it has to price the handler's best case.
  def test_a_handler_that_only_keeps_up_from_quick_memory_is_quiet
    game = timed_game(hz: 30_000, ops: 20)

    assert_empty Check.new.detect(game)
    assert_equal 30_000, Cost.new(fast_interrupts: true).tick_verdict(game).timers.first.delivered
  end

  # A timer with no handler cannot lose anything.
  def test_a_timer_with_no_handler_is_quiet
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      timer :beat, per_second: 60_000
      game_loop { }
    end
    b.emit_pending_functions

    assert_empty Check.new.detect(b.program)
  end

  def test_it_runs_in_the_default_validation_pass
    report = RubyGBA::IR::Guardrails::Validator.new.run(timed_game(hz: 30_000, ops: 80), autofix: false)

    assert(report.warnings.any? { |w| w.check == :tick_rate },
           "the tick-rate guardrail should be registered as a builtin")
  end

  # --- and the rule itself, against the console ---

  # THE MEASUREMENT THE REST OF THIS RESTS ON. The handler counts its own ticks into a
  # variable, so the number the console really delivered can be read straight out of memory
  # and compared with the number the model predicted. Without this the rule is a story about
  # interrupts; with it, it is a fact about this console.
  def test_the_console_delivers_the_ticks_the_model_predicts
    [[8_000, 20], [30_000, 20], [30_000, 80], [50_000, 40]].each do |hz, ops|
      rom = RubyGBA.build("TICKS", code: "BTKR", maker: "01", err: StringIO.new, out: StringIO.new) do
        screen :bitmap
        ticks = var :ticks, 0
        filler = var :filler, 0
        timer(:beat, per_second: hz).on_tick do
          ticks.add 1
          (ops - 1).times { filler.add 1 }
        end
        game_loop { }
      end
      predicted = rom.cost_model.tick_verdict(rom.source_program).timers.first.ticks

      assert_in_delta predicted, ticks_a_frame(rom), predicted * 0.1,
                      "at #{hz} a second with a #{ops}-statement handler, the model predicts " \
                      "#{predicted.round(1)} ticks a frame"
    end
  end

  FRAMES = 40

  # How many times the handler really ran, per frame, read from the counter it keeps.
  def ticks_a_frame(rom)
    address = rom.var_addresses[:ticks]
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ticks.gba")
      rom.write(path)
      probe = RubyGBA::Emulator.probe(path)
      probe.step(12) # settle: reach the steady state before reading anything
      before = probe.read32(address)
      probe.step(FRAMES)
      after = probe.read32(address)
      probe.close
      return (after - before) / FRAMES.to_f
    end
  end
end
