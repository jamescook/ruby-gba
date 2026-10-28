# frozen_string_literal: true

require "test_helper"

# A game built as a Super Nintendo cartridge and played in bsnes does what the interpreter does,
# pass for pass (SNES::CheckedRun): the game's numbers, its lists, its buttons and its routines, each
# carried out by 65816 code and its runtime. Each test is a small game of its own that leans on one
# of those, read back where a test of the game would read it; a disagreement anywhere along the run
# fails it.
class TestSNESCheckedRun < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  def test_arithmetic_that_wraps_divides_and_shifts_agrees_with_the_interpreter
    run = checked(frames: 40) do
      a = var :a, 7
      b = var :b, -3
      c = var :c, 0
      game_loop do
        a.set! (a * 1103) + 12_345
        b.set! (b - a) / 7
        c.set! ((a % 97) ^ (b >> 3)) | ((a << 5) & 0xFF00)
      end
    end

    refute_equal 0, run[:a]
  end

  def test_comparisons_clamps_and_turning_round_agree_with_the_interpreter
    run = checked(frames: 30) do
      a = var :a, -40
      b = var :b, 0
      flags = var :flags, 0
      game_loop do
        a.add! 3
        b.set! a.clamp(-20, 20)
        flags.set! 0
        (a < 0).then { flags.add! 1 }
        (a <= b).then { flags.add! 2 }
        (a > -5).then { flags.add! 4 }
        (a >= b).then { flags.add! 8 }
        (a == b).then { flags.add! 16 }
        (a != 7).then { flags.add! 32 }
        ((a > 0) & (b > 10)).then { flags.add! 64 }
        b.set! b.abs - a.flip
      end
    end

    assert_operator run[:flags], :>, 0
  end

  def test_fractions_multiplied_and_divided_agree_with_the_interpreter
    run = checked(frames: 30) do
      speed = var :speed, 1.25
      at = var :at, -3.5
      game_loop do
        at.set! (at * speed) / 1.75
        speed.add! 0.125
      end
    end

    assert run[:speed].positive?
  end

  def test_a_list_pushed_shifted_and_read_agrees_with_the_interpreter
    run = checked(frames: 24) do
      trail = list :trail, capacity: 5, width: :byte
      n = var :n, 120
      sum = var :sum, 0
      game_loop do
        n.add! 3
        trail.push n
        (trail.length > 4).then { trail.shift }
        sum.set! trail[0] + trail[trail.length - 1]
      end
    end

    assert_equal 5 - 1, run.list(:trail).length
  end

  # A run of a table copied into a list lands in the list's own slots: the list declared before it
  # in work RAM keeps what it holds.
  def test_a_table_copied_into_a_list_agrees_and_leaves_the_list_before_it_alone
    run = checked(frames: 6) do
      lut = table :lut, [10, 20, 30, 40, 50], width: :byte, signed: false
      first = list :first, capacity: 3
      narrow = list :narrow, capacity: 4, width: :byte
      at = var :at, 0
      got = var :got, 0
      first.push 5
      game_loop do
        narrow.copy_from lut, at: at, count: 3
        got.set! narrow[2] + lut[at]
        at.set! (at + 1) % 4
      end
    end

    assert_equal [5], run.list(:first)
  end

  def test_a_list_read_out_of_range_stops_the_game_in_the_interpreters_words
    error = assert_raises(VBlank::IR::ProgramError) do
      checked(frames: 5) do
        body = list :body, capacity: 4
        body.push 10
        x = var :x, 0
        game_loop { x.set! body[3] }
      end
    end

    assert_match(/index 3 is out of range for list :body \(valid indexes are 0\.\.0\)/, error.message)
  end

  def test_buttons_held_and_pressed_reach_the_game_on_the_frames_they_are_held
    run = SNES::CheckedRun.new
    run.input_each_frame { |frame| frame % 3 == 1 ? %i[a right] : [] }.run(program_of do
      held_a = var :held_a, 0
      presses = var :presses, 0
      shoulders = var :shoulders, 0
      game_loop do
        held(:a).then { held_a.add! 1 }
        pressed(:right).then { presses.add! 1 }
        held(:l).then { shoulders.add! 1 }
      end
    end, frames: 12)

    assert_equal 4, run[:presses]
  end

  # Each of the ten buttons pressed in turn, alone, a frame apart: each is counted under its own
  # name, so one wired to another's bit shows as a count in the wrong place.
  BUTTONS = %i[a b select start right left up down r l].freeze

  def test_every_button_reaches_the_game_under_its_own_name
    run = SNES::CheckedRun.new
    run.input_each_frame { |frame| frame.even? ? [BUTTONS[(frame / 2) % BUTTONS.size]] : [] }
    run.run(program_of do
      BUTTONS.each do |button|
        count = var :"#{button}_count", 0
        game_loop_part = -> { pressed(button).then { count.add! 1 } }
        once_a_frame(&game_loop_part)
      end
      game_loop {}
    end, frames: 44)

    counts = BUTTONS.map { |button| run[:"#{button}_count"] }
    assert(counts.all? { |count| count >= 2 }, counts.inspect)
  end

  def test_buttons_held_from_power_on_are_pressed_at_the_first_frame
    run = SNES::CheckedRun.new.hold(:start, :b)
    run.run(program_of do
      started = var :started, 0
      game_loop do
        pressed(:start).then { started.add! 1 }
        held(:b).then { started.add! 10 }
      end
    end, frames: 5)

    assert_operator run[:started], :>, 0
  end

  # A painted screen's first pass ends late in its frame, so the frame's blank, frame 1, has read
  # the controller before the run sees the pass is over. A press on frame 1 alone still reaches
  # the second pass, as it does on the interpreter: 1, where the press was lost it is 0.
  def test_a_press_on_frame_one_reaches_a_game_whose_first_pass_ends_late
    run = SNES::CheckedRun.new
    run.input_each_frame { |frame| frame == 1 ? [:a] : [] }.run(program_of do
      screen :bitmap
      presses = var :presses, 0
      game_loop do
        clear_screen :black
        pressed(:a).then { presses.add! 1 }
        draw_text "HI", 40, 30, :white
      end
    end, frames: 3)

    assert_equal 1, run[:presses]
  end

  # What is left after dividing by a power of two takes the divisor's sign, as Ruby's `%` does: -1
  # % 16 is 15. Counted down through nought and far below it, by 1, 2, 16, 1024 and 2^30.
  def test_what_is_left_by_a_power_of_two_takes_the_divisors_sign
    run = checked(frames: 12) do
      a = var :a, 2_000_037
      left = var :left, 0
      game_loop do
        left.set! (a % 1) + ((a % 2) * 10) + ((a % 16) * 100) + ((a % 1024) * 10_000) + (a % 1_073_741_824)
        a.sub! 777_781
      end
    end

    assert_operator run[:a], :<, 0
  end

  def test_scenes_picked_by_a_variable_agree_with_the_interpreter
    run = checked(frames: 20) do
      state = var :state, 0
      ticks = var :ticks, 0
      scene(:title) { ticks.add! 1; (ticks > 3).then { state.set! 1 } }
      scene(:play) { ticks.add! 10; (ticks > 50).then { state.set! 0; ticks.set! 0 } }
      game_loop do
        case_var :state do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end

    assert_operator run[:ticks], :>, 0
  end

  def test_a_routine_picked_by_a_number_and_a_counted_loop_agree_with_the_interpreter
    run = checked(frames: 12) do
      total = var :total, 0
      pick = var :pick, 0
      func(:one) { total.add! 1 }
      func(:two) { total.add! 20 }
      func(:three) { total.add! 300 }
      game_loop do
        call %i[one two three], number: pick
        pick.set! (pick + 1) % 4
        repeat(3) { |i| total.add! i }
      end
    end

    assert_operator run[:total], :>, 0
  end

  def test_a_game_that_halts_ends_where_the_interpreter_ends
    run = checked(frames: 60) do
      x = var :x, 0
      game_loop do
        x.add! 1
        (x >= 9).then { halt }
      end
    end

    assert_equal 9, run[:x]
  end

  def test_a_game_that_never_waits_runs_to_its_end
    run = checked do
      x = var :x, 5
      x.set! x * x
    end

    assert_equal 25, run[:x]
  end

  def test_randomness_and_timers_agree_with_the_interpreter
    run = checked(frames: 40) do
      seed 777
      hits = var :hits, 0
      ticks = var :ticks, 0
      rings = var :rings, 0
      beat = timer :beat, per_second: 13
      beat.on_tick { rings.add! 1 }
      game_loop do
        chance(50).then { hits.add! 1 }
        ticks.set! beat.ticks
      end
    end

    assert_operator run[:hits], :>, 0
  end

  # A pass too heavy for one frame spans several, and what keeps real time — `once_a_frame` —
  # moves on by every frame the pass took, on the interpreter too.
  def test_a_pass_that_takes_several_frames_keeps_real_time_as_the_interpreter_does
    run = checked(frames: 12) do
      x = var :x, 1
      frames = var :frames, 0
      passes = var :passes, 0
      once_a_frame { frames.add! 1 }
      game_loop do
        passes.add! 1
        repeat(60) { x.set! (x * 1103) + 12_345 }
      end
    end

    assert_operator run[:frames], :>, run[:passes], "a pass spanned more than one frame"
  end

  def test_a_routine_that_can_call_itself_is_refused_in_plain_words
    program = VBlank::IR::Build.program(
      VBlank::IR::Build.func(:again, VBlank::IR::Build.call(:again)), VBlank::IR::Build.call(:again)
    )
    error = assert_raises(SNES::LoweringError) { SNES.new.build(program) }

    assert_match(/can call itself again/, error.message)
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :snes }
  end

  def checked(frames: nil, &game)
    SNES::CheckedRun.new.run(program_of(&game), frames: frames)
  end
end
