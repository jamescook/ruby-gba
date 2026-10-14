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
    assert_equal interpreter.frame, CheckedNativeRun.last_frame(played.moments)
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

    assert_match(/before it first waits for the screen/, error.message)
  end

  # Watching a run leaves it a checked one: what each_vblank gives back is the checked run
  # itself, so the run a test goes on to make is still compared with the interpreter. The block
  # reads the game as C, at each frame boundary.
  def test_a_watched_run_is_still_a_checked_one
    program = program_of do
      x = var :x, 0
      game_loop { x.add! 2 }
    end
    seen = []
    run = CheckedNativeRun.new

    watched = run.each_vblank { |frame| seen << [frame, run[:x]] }

    assert_same run, watched
    watched.run(program, frames: 3)
    assert_equal [[1, 0], [2, 2], [3, 4]], seen
  end

  # A sprite drawn at +x+ across, showing the picture of its own name.
  def drawn(name, x) = RubyGBA::Diagnostics::DrawnSprite.new(name: name, x: x, y: 40, picture: name)

  def test_the_first_frame_they_disagree_on_is_named_with_what_differs
    agreed = Moment.new(frame: 1, variables: { x: 0 }, picture: 7, sounds: 0, sprites: [])
    want = [agreed, Moment.new(frame: 2, variables: { x: 1 }, picture: 7, sounds: 1, sprites: [drawn(:coin, 8), drawn(:hero, 20)]),
            Moment.new(frame: 3, variables: { x: 2 }, picture: 9, sounds: 1, sprites: [])]
    got = [agreed, Moment.new(frame: 2, variables: { x: 2 }, picture: 8, sounds: 2, sprites: [drawn(:coin, 8), drawn(:hero, 22)]),
           Moment.new(frame: 3, variables: { x: 2 }, picture: 9, sounds: 1, sprites: [])]

    difference = CheckedNativeRun.first_difference(want, got)

    assert_match(/frame 2/, difference)
    assert_match(/x: C has 2, Reference 1/, difference)
    assert_match(/picture/, difference)
    assert_match(/sound log holds 2 entries in the C and 1/, difference)
    assert_match(/sprite 1 of those drawn: C has :hero at \(22, 40\) showing :hero, Reference :hero at \(20, 40\)/, difference)
  end

  # A sprite one of them drew and the other did not is a difference too.
  def test_a_sprite_only_one_of_them_drew_is_named
    want = [Moment.new(frame: 1, variables: {}, picture: 7, sounds: 0, sprites: [drawn(:hero, 20)])]
    got = [Moment.new(frame: 1, variables: {}, picture: 7, sounds: 0, sprites: [])]

    assert_match(/sprite 0 of those drawn: C has none, Reference :hero at \(20, 40\)/,
                 CheckedNativeRun.first_difference(want, got))
  end

  def test_runs_that_agree_have_no_difference
    same = [Moment.new(frame: 1, variables: { x: 0 }, picture: 7, sounds: 0, sprites: [drawn(:hero, 20)])]

    assert_nil CheckedNativeRun.first_difference(same, same)
  end

  def test_the_first_sound_they_disagree_on_is_named
    difference = CheckedNativeRun.sounds_difference([[:enabled], [:note, :tune, 262]], [[:enabled], [:note, :tune, 294]])

    assert_match(/entry 1 of the sound log: C has \[:note, :tune, 294\], Reference \[:note, :tune, 262\]/, difference)
    assert_nil CheckedNativeRun.sounds_difference([[:enabled]], [[:enabled]])
  end
end
