# frozen_string_literal: true

require "test_helper"
require "native_comparison"

# What a test opted into native runs is handed there (see CheckedNativeRun): the game played as
# C, and then the same buttons played on the interpreter, with the run stopped at the first frame
# the two do not agree on — so a file's hand-picked checks are backed by every variable and
# every pixel of every frame.
class TestCheckedNativeRun < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  Moment = CheckedNativeRun::Moment

  def test_a_run_both_agree_on_answers_like_the_native_one
    program = program_of do
      x = var :x, 0
      game_loop { held(:right).then { x.add! 1 } }
    end
    run = CheckedNativeRun.new
    run.input_each_frame { |_frame| run[:x] < 3 ? [:right] : [] }

    assert_equal 3, run.run(program, frames: 8)[:x]
  end

  # A step budget is the interpreter's own measure, so it says how many frames fit in one, and
  # the C plays that many: the answer is the interpreter's for the same budget.
  def test_a_step_budget_plays_the_frames_the_interpreter_fits_in_it
    program = program_of do
      x = var :x, 0
      game_loop { held(:right).then { x.add! 1 } }
    end
    interpreter = Reference.new.hold(:right).run(program, max_steps: 60)

    played = CheckedNativeRun.new.hold(:right).run(program, max_steps: 60)

    assert_operator interpreter[:x], :>, 2, "the budget should hold a few frames"
    assert_equal interpreter[:x], played[:x]
    assert_equal interpreter.frame, played.moments.map(&:frame).grep(Integer).max
  end

  def test_a_step_budget_on_a_game_that_never_waits_for_the_screen_cannot_be_played
    builder = Builder.new(options: RubyGBA::Cartridge::Options.new(frame_sync: :manual))
    builder.instance_eval do
      x = var :x, 0
      game_loop { x.add! 1 }
    end
    builder.finalize_program
    program = builder.program

    error = assert_raises(CheckedNativeRun::HeadlessRun::CannotAnswer) { CheckedNativeRun.new.run(program, max_steps: 60) }

    assert_match(/never waits for the screen/, error.message)
  end

  def test_the_first_frame_they_disagree_on_is_named_with_what_differs
    agreed = Moment.new(frame: 1, variables: { x: 0 }, picture: 7, sounds: 0)
    want = [agreed, Moment.new(frame: 2, variables: { x: 1 }, picture: 7, sounds: 1),
            Moment.new(frame: 3, variables: { x: 2 }, picture: 9, sounds: 1)]
    got = [agreed, Moment.new(frame: 2, variables: { x: 2 }, picture: 8, sounds: 2),
           Moment.new(frame: 3, variables: { x: 2 }, picture: 9, sounds: 1)]

    difference = CheckedNativeRun.first_difference(want, got)

    assert_match(/frame 2/, difference)
    assert_match(/x: C has 2, Reference 1/, difference)
    assert_match(/picture/, difference)
    assert_match(/sound log holds 2 entries in the C and 1/, difference)
  end

  def test_runs_that_agree_have_no_difference
    same = [Moment.new(frame: 1, variables: { x: 0 }, picture: 7, sounds: 0)]

    assert_nil CheckedNativeRun.first_difference(same, same)
  end

  def test_the_first_sound_they_disagree_on_is_named
    difference = CheckedNativeRun.sounds_difference([[:enabled], [:note, :tune, 262]], [[:enabled], [:note, :tune, 294]])

    assert_match(/entry 1 of the sound log: C has \[:note, :tune, 294\], Reference \[:note, :tune, 262\]/, difference)
    assert_nil CheckedNativeRun.sounds_difference([[:enabled]], [[:enabled]])
  end
end
