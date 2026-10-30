# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# The game played as JavaScript, and then the same buttons played on the interpreter, with the run
# stopped at the first frame the two do not agree on (JS::CheckedRun) — which is what a test is
# handed on a JavaScript run (VBlank::Testing::JSCheckedPlayer), so a file's hand-picked checks
# are backed by every variable and every pixel of every frame. The checking is the native
# lowering's own (Native::CheckedRun); what is held here is that it checks the JavaScript.
class TestJSCheckedRun < Minitest::Test
  CheckedRun = VBlank::IR::Backends::JS::CheckedRun
  LIB = VBlank.root.join("lib").to_s

  # The same game, with an interpreter whose top left pixel is always one colour off, played with
  # the library alone: the disagreement is reported all the way to the replay that names the pixel.
  GAME_THAT_DISAGREES = <<~RUBY
    require "vblank"

    module OnePixelOff
      def shown = super.dup.tap { |pixels| pixels[0] ^= 1 }
    end
    VBlank::IR::Backends::Reference::Framebuffer.prepend(OnePixelOff)

    game = VBlank.game "CHECKED", consoles: %i[gba] do
      game_loop { pixel 10, 10, :red }
    end
    begin
      VBlank::IR::Backends::JS::CheckedRun.new.run(game.program, frames: 3)
      puts "agreed"
    rescue VBlank::IR::Backends::JS::CheckedRun::Disagreement => e
      puts e.message
    end
  RUBY

  private def program_of(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  def test_a_disagreement_is_reported_with_only_the_library
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", LIB, "-", stdin_data: GAME_THAT_DISAGREES)

    assert status.success?, "the game's own process failed:\n#{err}"
    assert_match(/the JavaScript lowering and the interpreter disagree at frame 1: the picture differs/, out)
    assert_match(/the first at \(0, 0\): JS shows/, out, "the replay names the pixel")
  end

  # The test helper's player reports a disagreement as a failed test, in words that name the side.
  def test_the_checked_player_fails_a_test_on_a_disagreement
    wrapper = Class.new(VBlank::Testing::JSCheckedPlayer) do
      def play_on_interpreter(...) = super.tap { |_, moments| moments.first.variables[:x] = 99 }
    end
    program = program_of do
      x = var :x, 0
      game_loop { x.add! 1 }
    end

    error = assert_raises(Minitest::Assertion) { wrapper.new.run(program, frames: 2) }

    assert_match(/x: JS has \d+, Reference 99/, error.message)
  end

  # A step budget is the interpreter's own measure, so it says how many frames fit in one, and the
  # JavaScript plays that many.
  def test_a_step_budget_plays_the_frames_the_interpreter_fits_in_it
    program = program_of do
      x = var :x, 0
      game_loop { held(:right).then { x.add! 1 } }
    end
    interpreter = Reference.new.hold(:right).run(program, max_steps: 60)

    played = CheckedRun.new.hold(:right).run(program, max_steps: 60)

    assert_operator interpreter[:x], :>, 2, "the budget should hold a few frames"
    assert_equal interpreter[:x], played[:x]
  end

  def test_a_button_held_for_the_whole_run_is_down_before_the_first_frame
    program = program_of do
      early = var :early, 0
      held(:a).then { early.set! 1 }
      game_loop {}
    end

    assert_equal 1, CheckedRun.new.hold(:a).run(program, frames: 2)[:early]
  end

  # A game that saves is played both ways from the same save memory, and what the JavaScript left
  # in it is there for the next run, as a power cycle.
  def test_save_memory_outlasts_a_run
    program = program_of do
      count = save_var :count, 0
      count.add! 1
      game_loop {}
    end
    store = SaveImage.new

    CheckedRun.new(save: store).run(program, frames: 2)
    again = CheckedRun.new(save: store).run(program, frames: 2)

    assert_equal 2, again[:count]
  end

  # A question only the interpreter answers so far names this lowering and its own skip.
  def test_a_question_only_the_interpreter_can_answer_yet_names_the_javascript_skip
    error = assert_raises(VBlank::IR::Backends::JS::HeadlessRun::CannotAnswer) do
      VBlank::IR::Backends::JS::HeadlessRun.new.frames_each_pass { 2 }
    end

    assert_match(/JavaScript lowering/, error.message)
    assert_match(/skip_on_js/, error.message)
  end
end
