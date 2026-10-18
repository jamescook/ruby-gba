# frozen_string_literal: true

require "test_helper"
require "differential"

# Sits in the JavaScript lowering's own folder, so it fails if anything but the JavaScript
# lowering's run plays it. Every test in this folder is that lowering's alone, and the other runs
# leave the folder out: this is the one that says so the day that stops working
# (TestSuites::LOWERING_FOLDERS).
class TestJSSuite < Minitest::Test
  include Differential

  def test_a_test_in_the_js_lowerings_folder_runs_only_on_its_run
    assert_equal :js, RubyGBA::Testing.lowering, "a test in the JavaScript lowering's folder ran on a #{RubyGBA::Testing.lowering} run"
  end

  def test_a_game_is_played_as_javascript_on_this_run
    assert_kind_of RubyGBA::Testing::JSCheckedPlayer, game_player
  end

  # A file of tests about the game keeps its tests of the cartridge, which skip themselves here.
  def test_a_test_of_the_cartridge_skips_itself_on_a_js_run_and_says_why
    skipped = assert_raises(Minitest::Skip) { require_emulator! }

    assert_match(/emulator/, skipped.message)
  end

  # A test that asks whether the console draws what the interpreter draws has no console to ask
  # here, so the same line asks it of the game as JavaScript, compared with the interpreter on
  # every frame.
  def test_a_whole_picture_comparison_is_made_of_the_game_as_javascript_on_a_js_run
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      x = var :x, 0
      game_loop do
        clear_screen :black
        draw_rect_at x, 20, 2, 2, :green
        held(:right).then { x.add! 1 }
      end
    end
    builder.finalize_program

    played = assert_backends_agree(builder.program, frames: 4, keys: [:right])

    assert_kind_of RubyGBA::Testing::JSCheckedPlayer, played
    assert_equal 4, played[:x], "the buttons were held on all four frames, so the game moved four times"
  end

  def test_a_test_javascript_cannot_play_yet_skips_with_its_reason
    skipped = assert_raises(Minitest::Skip) { skip_on_js "reads the sprites by name" }

    assert_match(/reads the sprites by name/, skipped.message)
  end
end
