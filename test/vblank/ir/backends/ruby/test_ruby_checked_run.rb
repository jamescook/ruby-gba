# frozen_string_literal: true

require "test_helper"

# The game played as Ruby, and then the same buttons played on the interpreter, with the run
# stopped at the first frame the two do not agree on (Ruby::CheckedRun) — which is what a test is
# handed on the Ruby lowering's run. The checking is the native lowering's own (Native::CheckedRun);
# what is held here is that it checks the Ruby.
class TestRubyCheckedRun < Minitest::Test
  CheckedRun = VBlank::IR::Backends::Ruby::CheckedRun

  private def program_of(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  def test_a_game_played_as_ruby_counts_its_frames
    program = program_of do
      x = var :x, 0
      game_loop { x.add! 3 }
    end

    assert_equal 15, CheckedRun.new.run(program, frames: 5)[:x]
  end

  # A condition is a number, and in Ruby nought is true: a branch whose condition is nought must
  # still not be taken, nor a loop whose condition is nought be entered.
  def test_a_condition_that_is_nought_is_not_taken
    program = program_of do
      x = var :x, 0
      taken = var :taken, 0
      game_loop do
        x.add! 1
        (x > 100).then { taken.add! 1 }.else { taken.add! 10 }
      end
    end

    assert_equal 30, CheckedRun.new.run(program, frames: 3)[:taken]
  end

  # Scenes take over from each other, and a game can end by itself, drawing nothing either way.
  def test_scenes_take_over_and_a_game_halts
    program = program_of do
      count = var :count, 0
      var :state, 0
      scene(:counting) do
        count.add! 1
        (count == 3).then { set! :state, 1 }
      end
      scene(:done) { halt }
      game_loop { case_var(:state) { when_val 0, :counting; when_val 1, :done } }
    end

    assert_equal 3, CheckedRun.new.run(program, frames: 10)[:count]
  end

  # What the interpreter refuses stops the game in the interpreter's words.
  def test_a_push_onto_a_full_list_stops_the_game
    program = program_of do
      trail = list :trail, capacity: 2
      game_loop { trail.push 1 }
    end

    error = assert_raises(VBlank::IR::ProgramError) { CheckedRun.new.run(program, frames: 5) }
    assert_match(/list :trail is full/, error.message)
  end

  # A routine the game calls by its number, and buttons the test holds, both reach the game.
  def test_routines_and_buttons_reach_the_game
    program = program_of do
      x = var :x, 0
      which = var :which, 0
      func(:add_one) { x.add! 1 }
      func(:add_ten) { x.add! 10 }
      game_loop do
        call %i[add_one add_ten], number: which
        held(:a).then { which.set! 1 }
      end
    end

    run = CheckedRun.new.input_each_frame { |frame| frame >= 2 ? [:a] : [] }.run(program, frames: 4)
    assert_equal 1 + 1 + 10 + 10, run[:x]
  end
end
