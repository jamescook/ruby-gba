# frozen_string_literal: true

require "test_helper"
require "native_comparison"

# The stand-in a test is handed on a native run in place of the interpreter (see
# Native::HeadlessRun): the game built with no window, driven and read back through the same
# calls a test already makes on Backends::Reference.
class TestNativeHeadlessRun < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  HeadlessRun = RubyGBA::IR::Backends::Native::HeadlessRun

  def test_a_variable_reads_back_after_the_run
    program = program_of do
      ticks = var :ticks, 0
      game_loop { ticks.add! 1 }
    end

    assert_equal 6, HeadlessRun.new.run(program, frames: 6)[:ticks]
  end

  # The program prints its own lines beside the game's variables ("frame 3", "picture …"), and a
  # game may call a variable by either word.
  def test_a_variable_may_share_a_name_with_the_lines_around_it
    program = program_of do
      frame = var :frame, 0
      picture = var :picture, 7
      game_loop do
        frame.add! 1
        picture.add! 2
      end
    end
    run = HeadlessRun.new.run(program, frames: 5)

    assert_equal [5, 17], [run[:frame], run[:picture]]
    assert_equal [1, 2, 3, 4, 5, :end], run.moments.map(&:frame)
  end

  # The block is asked for each frame's buttons while the game runs, and can look at the game
  # to decide: here it holds RIGHT only until x has reached 3, so x stops there. A block that
  # saw the game a frame late, or not at all, would hold RIGHT once too often.
  def test_buttons_for_each_frame_can_depend_on_the_game_so_far
    program = program_of do
      x = var :x, 0
      game_loop { held(:right).then { x.add! 1 } }
    end
    run = HeadlessRun.new
    run.input_each_frame { |_frame| run[:x] < 3 ? [:right] : [] }

    assert_equal 3, run.run(program, frames: 8)[:x]
  end

  def test_buttons_held_for_the_whole_run
    program = program_of do
      x = var :x, 0
      game_loop { held(:left).then { x.add! 1 } }
    end

    assert_equal 4, HeadlessRun.new.hold(:left).run(program, frames: 4)[:x]
  end

  # Every variable at once, the way the interpreter's `vars` gives them.
  def test_every_variable_reads_back_together
    program = program_of do
      a = var :a, 2
      b = var :b, 0
      game_loop { b.add! a }
    end

    assert_equal({ a: 2, b: 6 }, HeadlessRun.new.run(program, frames: 3).vars.slice(:a, :b))
  end

  # Told no number of frames, it plays as many as the interpreter does when it is not told.
  def test_a_run_given_no_frame_count_plays_the_interpreters_default
    program = program_of do
      ticks = var :ticks, 0
      game_loop { ticks.add! 1 }
    end

    assert_equal Reference::DEFAULT_FRAMES, HeadlessRun.new.run(program)[:ticks]
  end

  # A step budget is something only the interpreter keeps: the C runs as fast as it runs.
  def test_a_step_budget_is_refused_by_name
    error = assert_raises(HeadlessRun::CannotAnswer) { HeadlessRun.new.run(program_of { halt }, max_steps: 100) }

    assert_match(/max_steps/, error.message)
  end

  def test_starting_from_save_memory_is_refused_until_the_native_lowering_can_hold_one
    error = assert_raises(HeadlessRun::CannotAnswer) { HeadlessRun.new(save: SaveImage.new) }

    assert_match(/save memory/, error.message)
  end

  # A test asking something only the interpreter can answer so far is told so by name, rather
  # than meeting a NoMethodError that reads like a typo in the test.
  def test_a_question_only_the_interpreter_can_answer_yet_says_so
    error = assert_raises(HeadlessRun::CannotAnswer) { HeadlessRun.new.game_state }

    assert_match(/game_state/, error.message)
  end

  # The sound comes as so many numbers a second, and the C and the Ruby each say how many.
  def test_the_sound_rate_is_the_one_the_runtime_makes_it_at
    header = File.read(File.join(RubyGBA::IR::Backends::Native::Zig::RUNTIME_DIR, "rg_sound.h"))

    assert_match(/^#define RG_SOUND_RATE #{HeadlessRun::SOUND_RATE}$/, header)
  end

  def test_the_picture_reads_back_a_pixel_at_a_time
    program = program_of do
      screen :bitmap
      game_loop do
        clear_screen :black
        pixel 10, 20, :green
      end
    end
    run = HeadlessRun.new.run(program, frames: 2)

    assert_equal Color.resolve(:green), run.screen.pixel(10, 20)
    assert_equal Color.resolve(:black), run.screen.pixel(11, 20)
  end
end
