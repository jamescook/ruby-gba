# frozen_string_literal: true

require "test_helper"

# A game built as a Game Boy Color cartridge and played in the emulator does what the interpreter
# does, pass for pass (GBC::CheckedRun): the game's numbers, its lists, its buttons and its routines,
# each the way the native lowering's statements say them and the runtime in SM83 carries them out.
# Each test is a small game of its own that leans on one of those, read back where a test of the
# game would read it; a disagreement anywhere along the run fails it.
class TestGBCCheckedRun < Minitest::Test
  GBC = RubyGBA::IR::Backends::GBC

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

  def test_a_list_read_out_of_range_stops_the_game_in_the_interpreters_words
    error = assert_raises(RubyGBA::IR::ProgramError) do
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
    run = GBC::CheckedRun.new
    run.input_each_frame { |frame| frame % 3 == 1 ? %i[a right] : [] }.run(program_of do
      held_a = var :held_a, 0
      presses = var :presses, 0
      game_loop do
        held(:a).then { held_a.add! 1 }
        pressed(:right).then { presses.add! 1 }
      end
    end, frames: 12)

    assert_equal 4, run[:presses]
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

  # A routine whose code is more than a bank holds is cut into parts, each in a bank of its own.
  def test_a_routine_bigger_than_a_bank_is_cut_into_parts_that_still_agree
    run = checked(frames: 3) do
      seed 777
      hits = var :hits, 0
      game_loop { 160.times { chance(50).then { hits.add! 1 } } }
    end

    assert_operator run[:hits], :>, 0
  end

  def test_a_routine_that_can_call_itself_is_refused_in_plain_words
    program = RubyGBA::IR::Build.program(
      RubyGBA::IR::Build.func(:again, RubyGBA::IR::Build.call(:again)), RubyGBA::IR::Build.call(:again)
    )
    error = assert_raises(GBC::LoweringError) { GBC.new.build(program) }

    assert_match(/can call itself again/, error.message)
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program
  end

  def checked(frames: nil, &game)
    GBC::CheckedRun.new.run(program_of(&game), frames: frames)
  end
end
