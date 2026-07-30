# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# A hardware timer: `timer :beat, per_second: N` starts a counter that ticks N times a
# second; `beat.ticks` reads how many ticks have elapsed (a Value), `beat.stop` freezes
# it. The rate is a prescaler + reload on the GBA, and a frame-clock model on the
# interpreter — both agree on the elapsed-tick count. Pinned on the interpreter and gemba.
class TestTimer < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM

  # Run a program that samples `beat.ticks` into :snap every frame and halts at
  # `stop_frame`; returns the interpreter so a test can read :snap. `per_second` sets the
  # rate; if `stop_at` is given, the timer is stopped at that frame.
  def run_ticks(per_second:, stop_frame:, stop_at: nil)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      beat = timer :beat, per_second: per_second
      fc = var :fc, 0
      var :snap, 0
      game_loop do
        wait_vblank
        add :fc, 1
        (fc == stop_at).then { beat.stop } if stop_at
        set :snap, beat.ticks
        (fc == stop_frame).then { halt }
      end
    end
    Ruby.new.run(b.program)
  end

  # At 60/sec on a 60fps model, the timer ticks once per frame — so after N frames it
  # reads N.
  def test_ticks_climb_one_per_frame_at_sixty_per_second
    assert_equal 10, run_ticks(per_second: 60, stop_frame: 10)[:snap]
  end

  # Half the rate, half the ticks: 30/sec accrues one tick every two frames.
  def test_a_slower_timer_ticks_proportionally
    assert_equal 5, run_ticks(per_second: 30, stop_frame: 10)[:snap]
  end

  # A faster timer accrues more than one tick per frame.
  def test_a_faster_timer_ticks_faster
    assert_equal 20, run_ticks(per_second: 120, stop_frame: 10)[:snap]
  end

  # Stopping freezes the count: stopped at frame 5, it reads 5 even after ten frames.
  def test_stop_freezes_the_count
    assert_equal 5, run_ticks(per_second: 60, stop_frame: 10, stop_at: 5)[:snap]
  end

  # An unstarted timer reads zero rather than erroring.
  def test_reading_an_unstarted_timer_is_zero
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      var :snap, 0
      set :snap, RubyGBA::Timer.new(self, :ghost).ticks
      halt
    end
    assert_equal 0, Ruby.new.run(b.program)[:snap]
  end

  # --- validation ---

  def test_per_second_must_be_a_positive_whole_number
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :bitmap
        timer :beat, per_second: 0
      end
    end
    assert_match(/per_second/, err.message)
  end

  def test_reading_ticks_of_a_third_counted_timer_is_a_friendly_error
    # Each read timer costs two hardware timers; the GBA has four, so a third counted
    # timer overruns and the lowering says so plainly.
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      %i[a b c].each do |name|
        t = timer name, per_second: 60
        var :"snap_#{name}", 0
        set :"snap_#{name}", t.ticks
      end
      halt
    end
    err = assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) { GBA.new.lower(b.program) }
    assert_match(/hardware timers/i, err.message)
  end

  # --- on_tick: a handler driven by the timer's overflow ---

  # Runs `beat.on_tick { add :hits, 1 }` at the given rate and halts at `stop_frame`;
  # returns the interpreter so a test can read :hits.
  def run_on_tick(per_second:, stop_frame:, stop_at: nil)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      var :hits, 0
      beat = timer :beat, per_second: per_second
      beat.on_tick { add :hits, 1 }
      fc = var :fc, 0
      game_loop do
        wait_vblank
        add :fc, 1
        (fc == stop_at).then { beat.stop } if stop_at
        (fc == stop_frame).then { halt }
      end
    end
    Ruby.new.run(b.program)
  end

  # At 60/sec on a 60fps model the handler runs once per frame — so after N frames it has
  # run N times.
  def test_on_tick_runs_the_handler_on_each_overflow
    assert_equal 10, run_on_tick(per_second: 60, stop_frame: 10)[:hits]
  end

  # A faster timer runs the handler more often — twice a frame at 120/sec.
  def test_on_tick_runs_more_often_for_a_faster_timer
    assert_equal 20, run_on_tick(per_second: 120, stop_frame: 10)[:hits]
  end

  # Stopping the timer stops its handler: stopped at frame 5, the count freezes at 5.
  def test_on_tick_stops_with_the_timer
    assert_equal 5, run_on_tick(per_second: 60, stop_frame: 10, stop_at: 5)[:hits]
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
        set :seen, beat.ticks
      end
    end
    b.emit_pending_functions
    backend = GBA.new
    rom = ROM.assemble(backend.lower(b.program), title: "TIMR", code: "BTMR", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 20, vars: backend.var_addresses)
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
      timer(:beat, per_second: 60).on_tick { add :hits, 1 }
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    backend = GBA.new
    rom = ROM.assemble(backend.lower(b.program), title: "TICK", code: "BTCK", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 20, vars: backend.var_addresses)
    hits = v.var(:hits)
    assert hits.between?(10, 30), "the on_tick handler should have run ~20 times over 20 frames, got #{hits}"
  end
end
