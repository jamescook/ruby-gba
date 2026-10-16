# frozen_string_literal: true

require "test_helper"
require "native_comparison"

# A game's logic, written out as C and built with no window, ends every frame with the same
# variables the interpreter ends it with. Each test is a small game built through the DSL; the
# answer is whatever the interpreter says, frame by frame (see NativeComparison).
class TestNativeLogic < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  def test_a_counter_in_a_game_loop_counts_every_frame
    program = program_of do
      ticks = var :ticks, 0
      game_loop { ticks.add! 1 }
    end

    assert_native_matches_reference program, frames: 6
  end

  # A game can come to set a variable to itself, by a helper that takes where to keep an answer
  # and is handed the place the answer already is. It changes nothing, and it has to build.
  def test_a_variable_set_to_itself_builds_and_changes_nothing
    program = program_of do
      x = var :x, 4
      game_loop do
        x.add! 3
        copy! :x, :x
        x.set! x
      end
    end

    last = assert_native_matches_reference program, frames: 3
    assert_equal 13, last.variables.fetch(:x), "three passes each added three, and nothing else moved it"
  end

  # TIMERS. A rate that is no whole number of ticks a frame, so the part of a tick left over has
  # to be carried the way the interpreter carries it; a fast one whose handler runs several times
  # a frame; a handler written inside a routine nothing calls, which is still its timer's; a
  # second handler that takes the first one's place; a timer stopped and started again, which
  # counts from nought; a handler that calls a routine and stops its own timer; and a timer
  # that is read and never started.
  def test_timers_tick_and_run_their_handlers_as_the_interpreters_do
    program = program_of do
      n = var :n, 0
      uneven = timer :uneven, per_second: 100
      fast = timer :fast, per_second: 250
      restarted = timer :restarted, per_second: 60
      once = timer :once, per_second: 90
      var :uneven_hits, 0
      var :fast_hits, 0
      var :replaced, 0
      var :once_hits, 0
      var :reads, 0
      func(:count_once) { add! :once_hits, 1 }
      func(:nobody_calls_this) { uneven.on_tick { add! :uneven_hits, 1 } }
      fast.on_tick { add! :replaced, 1 }
      fast.on_tick { add! :fast_hits, 1 }
      once.on_tick do
        call :count_once
        once.stop
      end
      game_loop do
        n.add! 1
        (n == 5).then { restarted.stop }
        (n == 8).then { timer :restarted, per_second: 60 }
        set! :reads, uneven.ticks + (fast.ticks * 100) + (restarted.ticks * 10_000) +
                     RubyGBA::DSL::Timer.new(self, :never_started).ticks
      end
    end

    moments = reference_snapshots(program, frames: 14, buttons: {})

    assert_native_matches_reference program, frames: 14

    last = moments.last.variables

    assert_equal 0, last[:replaced], "the first handler should never run"
    assert_operator last[:fast_hits], :>, 40, "the fast one runs several times a frame"
    assert_operator last[:uneven_hits], :>, 14, "more than once a frame, and not a whole number of times"
    assert_equal 1, last[:once_hits], "stopped by its own first tick"
    assert_operator moments[6].variables[:reads] / 10_000, :>, moments[9].variables[:reads] / 10_000,
                    "the one started again counts from nought"
  end

  # Running off the top of a number wraps round to the bottom, and the division, remainder and
  # shifts keep Ruby's and the console's meanings, not C's.
  def test_numbers_wrap_divide_and_shift_the_way_the_interpreter_does
    program = program_of do
      big = var :big, 2_147_483_600
      neg = var :neg, -7
      quotient = var :quotient, 0
      left = var :left, 0
      shifted = var :shifted, 0
      game_loop do
        big.add! 20
        quotient.set! neg / 2
        left.set! neg % 64
        shifted.set! neg >> 1
      end
    end

    assert_native_matches_reference program, frames: 4
  end

  def test_a_button_held_and_a_button_pressed_are_read_each_frame
    program = program_of do
      x = var :x, 0
      presses = var :presses, 0
      game_loop do
        held(:right).then { x.add! 1 }
        pressed(:a).then { presses.add! 1 }
        pressed(:any).then { x.add! 100 }
      end
    end

    assert_native_matches_reference program, frames: 8,
                                             buttons: { 2 => %i[right], 3 => %i[right a], 4 => %i[a], 6 => %i[a] }
  end

  def test_branches_with_else_and_joined_conditions
    program = program_of do
      n = var :n, 0
      kind = var :kind, 0
      game_loop do
        n.add! 1
        ((n > 2) & (n < 5)).then { kind.set! 1 }.else { kind.set! 2 }
        ((n == 1) | (n == 6)).then { kind.add! 10 }
      end
    end

    assert_native_matches_reference program, frames: 7
  end

  def test_a_counted_loop_and_one_that_stops_early
    program = program_of do
      total = var :total, 0
      found = var :found, 0
      game_loop do
        total.set! 0
        repeat(5) { |i| total.add! i }
        repeat(10, stop_when: found >= 3) { found.add! 1 }
      end
    end

    assert_native_matches_reference program, frames: 3
  end

  def test_a_beat_and_a_one_shot_count_frames
    program = program_of do
      beats = var :beats, 0
      shot = var :shot, 0
      game_loop do
        every(3) { beats.add! 1 }
        after(4) { shot.add! 1 }
      end
    end

    assert_native_matches_reference program, frames: 10
  end

  def test_scenes_take_turns_by_a_state_variable
    program = program_of do
      state = var :state, 0
      in_title = var :in_title, 0
      in_play = var :in_play, 0
      func(:bump) { in_play.add! 1 }
      scene(:title) do
        in_title.add! 1
        (in_title >= 2).then { state.set! 1 }
      end
      scene(:playing) { call :bump }
      game_loop do
        case_var :state do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end

    assert_native_matches_reference program, frames: 6
  end

  def test_a_routine_picked_by_a_number
    program = program_of do
      which = var :which, -1
      hits = var :hits, 0
      func(:one) { hits.add! 1 }
      func(:ten) { hits.add! 10 }
      game_loop do
        call %i[one ten], number: which
        which.add! 1
      end
    end

    assert_native_matches_reference program, frames: 5
  end

  def test_numbers_holding_a_fraction
    program = program_of do
      speed = var :speed, 1.5
      pos = var :pos, 0.0
      ratio = var :ratio, 0.0
      game_loop do
        pos.add! speed
        speed.set! speed * 1.25
        ratio.set! pos / speed
      end
    end

    assert_native_matches_reference program, frames: 6
  end

  def test_a_table_read_wraps_or_clamps_its_index
    program = program_of do
      sine = table :sine, [0, 3, 6, 9]
      odd = table :odd, [5, 6, 7]
      i = var :i, -2
      a = var :a, 0
      b = var :b, 0
      game_loop do
        a.set! sine[i]
        b.set! odd[i]
        i.add! 1
      end
    end

    assert_native_matches_reference program, frames: 7
  end

  def test_a_list_pushed_shifted_and_read_back
    program = program_of do
      trail = list :trail, capacity: 4
      small = list :small, capacity: 2, width: :byte
      n = var :n, 0
      first = var :first, 0
      size = var :size, 0
      squeezed = var :squeezed, 0
      game_loop do
        n.add! 1
        (trail.length >= 4).then { trail.shift }
        trail.push n * 10
        first.set! trail[0]
        size.set! trail.length
        (small.length == 0).then { small.push 200 }
        squeezed.set! small[0]
      end
    end

    final = assert_native_matches_reference(program, frames: 9).variables

    assert_equal [60, 4, -56], final.values_at(:first, :size, :squeezed)
  end

  def test_a_pool_spawns_walks_and_retires_its_things
    program = program_of do
      sparks = pool :spark, x: 0, life: 0, capacity: 3
      total = var :total, 0
      alive = var :alive, 0
      game_loop do
        sparks.spawn(x: 5, life: 3)
        total.set! 0
        sparks.each do |s|
          s.x.add! 1
          s.life.sub! 1
          total.add! s.x
          (s.life <= 0).then { s.remove }
        end
        alive.set! sparks.count
      end
    end

    final = assert_native_matches_reference(program, frames: 8).variables

    assert_operator final[:alive], :>, 0
    assert_operator final[:total], :>, 0
  end

  def test_a_once_a_frame_body_runs_every_frame
    program = program_of do
      ticks = var :ticks, 0
      passes = var :passes, 0
      once_a_frame { ticks.add! 1 }
      game_loop { passes.add! 1 }
    end

    assert_native_matches_reference program, frames: 5
  end

  def test_calling_the_routine_a_named_state_says
    program = program_of do
      mode = var :mode, :idle
      score = var :score, 0
      func(:idle) do
        score.add! 1
        mode.set! :chase
      end
      func(:chase) { score.add! 10 }
      game_loop { call mode }
    end

    assert_native_matches_reference program, frames: 4
  end

  def test_pushing_onto_a_full_list_stops_the_program_as_the_interpreter_does
    program = program_of do
      full = list :full, capacity: 2
      game_loop { full.push 1 }
    end

    # One error for a game that goes wrong, whichever lowering played it, so a game's own test
    # asserts one thing.
    assert_raises(RubyGBA::IR::ProgramError) { reference_snapshots(program, frames: 4, buttons: {}) }
    error = assert_raises(RubyGBA::IR::ProgramError) { native_snapshots(program, frames: 4, buttons: {}, mode: :checked) }
    assert_includes error.message, "list :full is full"
  end

  def test_random_numbers_follow_the_same_stream
    program = program_of do
      seed 1234
      var :r, 0
      hits = var :hits, 0
      game_loop do
        roll :r, 1..6
        chance(30).then { hits.add! 1 }
      end
    end

    assert_native_matches_reference program, frames: 8
  end
end
