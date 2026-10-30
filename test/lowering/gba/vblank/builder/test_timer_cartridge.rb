# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_timer"

# A hardware timer on the Advance's cartridge: the timer really runs, and its handlers really
# answer its interrupt, read back in the emulator. How a timer counts on every run is in
# test/all/vblank/builder/test_timer.rb.
class TestTimerCartridge < Minitest::Test
  include TimerGames

  # A HANDLER IS THE TIMER'S, NOT THE LINE'S. `on_tick` says what a timer does when it
  # ticks, the way `once_a_frame` says what happens each frame, so a handler written inside
  # a routine nothing calls still answers every tick once the timer runs.
  def test_a_handler_inside_a_routine_nothing_calls_still_runs
    backend = GBA.new
    rom = ROM.assemble(backend.lower(handler_in_uncalled_routine_program), title: "TICKU", maker: "01")
    console = assert_emulator_loads_rom(rom, frames: 20, vars: backend.var_addresses).var(:hits)

    assert console.between?(10, 30), "the handler should have run ~20 times over 20 frames, got #{console}"
  end

  # A second handler for the same timer replaces the first rather than running beside it.
  def test_a_second_handler_for_a_timer_replaces_the_first
    backend = GBA.new
    rom = ROM.assemble(backend.lower(two_handlers_program), title: "TICKTWO", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 20, vars: backend.var_addresses)

    assert_equal 0, v.var(:first), "the replaced handler never runs on the console"
    assert v.var(:second).between?(10, 30), "the second handler runs, got #{v.var(:second)}"
  end

  # --- hardware: the timer really runs on the console ---

  def test_the_timer_counts_on_the_console
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      beat = timer :beat, per_second: 60
      var :seen, 0
      game_loop do
        wait_vblank
        set! :seen, beat.ticks
      end
    end
    b.finalize_program
    backend = GBA.new
    rom = ROM.assemble(backend.lower(b.program), title: "TIMR", code: "BTMR", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 20, vars: backend.var_addresses)
    seen = v.var(:seen)
    # ~20 overflows after 20 frames at 60/sec (allowing for real ~59.7fps + startup);
    # the wide window still catches a timer that never ran (0) or counted raw ticks (huge).
    assert seen.between?(10, 30), "the timer should have counted ~20 ticks over 20 frames, got #{seen}"
  end

  # An on_tick handler really runs off the timer interrupt on the console: it increments
  # a variable each overflow, alongside the VBlank the game loop sleeps on (so the
  # dispatcher is servicing two sources).
  def test_on_tick_handler_runs_on_the_console
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      var :hits, 0
      timer(:beat, per_second: 60).on_tick { add! :hits, 1 }
      game_loop { wait_vblank }
    end
    b.finalize_program
    backend = GBA.new
    rom = ROM.assemble(backend.lower(b.program), title: "TICK", code: "BTCK", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 20, vars: backend.var_addresses)
    hits = v.var(:hits)
    assert hits.between?(10, 30), "the on_tick handler should have run ~20 times over 20 frames, got #{hits}"
  end

  # A number drawn only from a tick is drawn: the routine that draws a font's digits is shared,
  # and it used to be laid out before the tick's code asked for it, so the game did not build.
  def test_a_number_drawn_only_from_a_tick_is_drawn_on_the_console
    rom = VBlank.build("TICKNUM", console: :gba, out: nil, err: nil) do
      screen :bitmap
      clear_screen :black
      shown = var :shown, 7
      timer(:beat, per_second: 60).on_tick { draw_number shown, 8, 8, :white, digits: 1 }
      game_loop {}
    end
    v = assert_emulator_loads_rom(rom, frames: 10)
    lit = (8...13).to_a.product((8...15).to_a).count { |x, y| v.white?(x, y) }

    assert_operator lit, :>, 0, "the 7 is on screen"
  end

  # A timer fast enough to be worth it has its handler kept in the console's quick memory,
  # which means the handler is copied bytes running from a different address than the ones the
  # build laid out (see Backends::GBA::Placement#IRQ_ROUTINE). It has to count exactly the
  # same either way, so this counts the same ticks with the handler in both places.
  private def ticks_counted_on_the_console(fast_code:)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      var :hits, 0
      timer(:beat, per_second: 1200).on_tick { add! :hits, 1 }
      game_loop { wait_vblank }
    end
    b.finalize_program
    backend = GBA.new(fast_code: fast_code)
    rom = ROM.assemble(backend.lower(b.program), title: "TICKF", code: "BTKF", maker: "01")
    [assert_emulator_loads_rom(rom, frames: 12, vars: backend.var_addresses).var(:hits),
     backend.iwram_report.funcs]
  end

  def test_a_moved_tick_handler_counts_the_same_ticks
    quick, moved = ticks_counted_on_the_console(fast_code: true)
    cart, left = ticks_counted_on_the_console(fast_code: false)

    assert_includes moved, VBlank::IR::Backends::GBA::Placement::IRQ_ROUTINE,
                    "a timer at 1200 a second is worth keeping in the quick memory"
    refute_includes left, VBlank::IR::Backends::GBA::Placement::IRQ_ROUTINE

    # 1200 a second over 12 frames is ~240 ticks. Where the handler runs cannot change that.
    assert_equal cart, quick, "the moved handler counted a different number of ticks"
    assert_operator quick, :>, 100, "the handler really ran (#{quick} ticks)"
  end
end
