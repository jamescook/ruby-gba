# frozen_string_literal: true

require "test_helper"

# The games with tick handlers, kept once for this file and for the tests of the same games on
# the Advance's cartridge (test/lowering/gba/vblank/builder/test_timer_cartridge.rb).
module TimerGames
  # A timer whose handler is written inside a routine nothing calls, counting into :hits.
  private def handler_in_uncalled_routine_program
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      var :hits, 0
      beat = timer :beat, per_second: 60
      func(:setup) { beat.on_tick { add! :hits, 1 } }
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # A timer given two handlers, the first counting into :first and the second into :second.
  private def two_handlers_program
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      var :first, 0
      var :second, 0
      beat = timer :beat, per_second: 60
      beat.on_tick { add! :first, 1 }
      beat.on_tick { add! :second, 1 }
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end
end

# A hardware timer: `timer :beat, per_second: N` starts a counter that ticks N times a
# second; `beat.ticks` reads how many ticks have elapsed (a Value), `beat.stop` freezes
# it. The rate is a prescaler + reload on the GBA, and a frame-clock model on the
# interpreter — both agree on the elapsed-tick count. Pinned here on every run, and on the
# Advance's cartridge in test/lowering/gba/vblank/builder/test_timer_cartridge.rb.
class TestTimer < Minitest::Test
  include TimerGames

  # Run a program that samples `beat.ticks` into :snap every frame and halts at
  # `stop_frame`; returns the interpreter so a test can read :snap. `per_second` sets the
  # rate; if `stop_at` is given, the timer is stopped at that frame.
  private def run_ticks(per_second:, stop_frame:, stop_at: nil)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      beat = timer :beat, per_second: per_second
      fc = var :fc, 0
      var :snap, 0
      game_loop do
        wait_vblank
        add! :fc, 1
        (fc == stop_at).then { beat.stop } if stop_at
        set! :snap, beat.ticks
        (fc == stop_frame).then { halt }
      end
    end
    game_player.run(b.program, frames: stop_frame + 1)
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

  # A WHOLE TICK COUNTS ON THE FRAME IT FALLS DUE, at any rate. Ten a second is a tick every six
  # frames, so six frames in it reads 1; three a second reads 3 a second in. Counted by adding a
  # tenth of a tick a frame as a fraction, the sum lands a hair under the whole tick, and the
  # count read one short on exactly those frames.
  def test_a_tick_counts_on_the_frame_it_falls_due
    assert_equal 1, run_ticks(per_second: 10, stop_frame: 6)[:snap]
    assert_equal 3, run_ticks(per_second: 3, stop_frame: 60)[:snap]
    assert_equal 2, run_ticks(per_second: 1, stop_frame: 120)[:snap]
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
      set! :snap, VBlank::DSL::Timer.new(self, :ghost).ticks
      halt
    end
    assert_equal 0, game_player.run(b.program)[:snap]
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
        set! :"snap_#{name}", t.ticks
      end
      halt
    end
    err = assert_raises(VBlank::IR::Backends::GBA::LoweringError) { GBA.new.lower(b.program) }
    assert_match(/hardware timers/i, err.message)
  end

  # Sampled sound takes two of the four for itself, which nothing in the program says — so a
  # program that runs out because of it is told so.
  def test_running_out_of_timers_beside_sampled_sound_says_the_sound_took_two
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      tone = sample :tone, pcm: [0, 50, 100, 50], rate: 8192
      counted = timer :counted, per_second: 60
      timer :plain, per_second: 60
      var :snap, 0
      game_loop do
        tone.play
        set! :snap, counted.ticks
      end
    end
    err = assert_raises(VBlank::IR::Backends::GBA::LoweringError) { GBA.new.lower(b.program) }
    assert_match(/hardware timers/i, err.message)
    assert_match(/sampled sound uses two/i, err.message)
  end

  # --- on_tick: a handler driven by the timer's overflow ---

  # Runs `beat.on_tick { add! :hits, 1 }` at the given rate and halts at `stop_frame`;
  # returns the interpreter so a test can read :hits.
  private def run_on_tick(per_second:, stop_frame:, stop_at: nil)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      var :hits, 0
      beat = timer :beat, per_second: per_second
      beat.on_tick { add! :hits, 1 }
      fc = var :fc, 0
      game_loop do
        wait_vblank
        add! :fc, 1
        (fc == stop_at).then { beat.stop } if stop_at
        (fc == stop_frame).then { halt }
      end
    end
    game_player.run(b.program)
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

  # A HANDLER IS THE TIMER'S, NOT THE LINE'S. `on_tick` says what a timer does when it
  # ticks, the way `once_a_frame` says what happens each frame, so a handler written inside
  # a routine nothing calls still answers every tick once the timer runs — on both runners.
  def test_a_handler_inside_a_routine_nothing_calls_still_runs
    assert_equal 10, game_player.run(handler_in_uncalled_routine_program, frames: 10)[:hits]
  end

  # A HANDLER CAN DRAW. On a painted screen it draws what the game's own lines draw, a number
  # here; on a tear-free one what it draws goes on the page being drawn, so the loop's next
  # clear takes it away before that page is shown and the screen stays blue. (A Color keeps one
  # page, the one being drawn, so there too the clear covers it before the run ends.) Every lowering
  # plays these against the interpreter, picture and all.
  def test_a_handler_draws_on_a_painted_screen
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      hits = var :hits, 0
      beat = timer :beat, per_second: 30
      beat.on_tick do
        hits.add! 1
        draw_number :hits, 8, 8, :white, digits: 2
      end
      game_loop { wait_vblank }
    end

    played = game_player.run(b.program, frames: 10)
    assert_equal 5, played[:hits]
    refute_equal played.screen.pixel(0, 0), played.screen.pixel(8 + 6, 8 + 3), "the number is drawn"
  end

  def test_a_handler_draws_on_the_page_being_drawn_on_a_tear_free_screen
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      beat = timer :beat, per_second: 60
      beat.on_tick { draw_rect_at 40, 40, 16, 16, :red }
      game_loop { clear_screen :blue }
    end

    assert_equal Color.resolve(:blue), game_player.run(b.program, frames: 6).screen.pixel(44, 44)
  end

  # A HANDLER READS THE BUTTONS of the frame it ticks on: A held for three frames is three ticks
  # holding it and one press, and a tap later is one more of each.
  def test_a_handler_reads_the_buttons_of_its_frame
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      downs = var :downs, 0
      presses = var :presses, 0
      beat = timer :beat, per_second: 60
      beat.on_tick do
        held(:a).then { downs.add! 1 }
        pressed(:a).then { presses.add! 1 }
      end
      game_loop { wait_vblank }
    end
    played = game_player.input_each_frame { |frame| (4..6).cover?(frame) || frame == 9 ? [:a] : [] }
                        .run(b.program, frames: 12)

    assert_equal [4, 2], [played[:downs], played[:presses]]
  end

  # The fastest rate a timer can be given counts as the interpreter counts it, with nothing
  # going round in the sum of a frame's sixtieths.
  def test_the_fastest_rate_counts_every_tick
    assert_equal (2_147_483_647 * 3 / 60) % 65_536, run_ticks(per_second: 2_147_483_647, stop_frame: 3)[:snap]
  end

  # A second handler for the same timer replaces the first rather than running beside it,
  # on both runners.
  def test_a_second_handler_for_a_timer_replaces_the_first
    i = game_player.run(two_handlers_program, frames: 10)

    assert_equal [0, 10], [i[:first], i[:second]]
  end
end
