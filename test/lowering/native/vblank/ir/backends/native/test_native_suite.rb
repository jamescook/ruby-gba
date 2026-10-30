# frozen_string_literal: true

require "test_helper"
require "differential"

# Sits in the native lowering's own folder, so it fails if anything but the native lowering's
# run plays it. Every test in this folder is the native lowering's alone, and the GBA lowering's
# run leaves the folder out: this is the one that says so the day that stops working
# (TestSuites::LOWERING_FOLDERS).
class TestNativeSuite < Minitest::Test
  include Differential

  def test_a_test_in_the_native_lowerings_folder_runs_only_on_its_run
    assert_equal :native, VBlank::Testing.lowering, "a test in the native lowering's folder ran on a #{VBlank::Testing.lowering} run"
  end

  # A test of the Advance's cartridge belongs in test/lowering/gba/; reached here, it fails saying so.
  def test_a_test_of_the_cartridge_fails_on_a_native_run_and_says_where_it_goes
    failed = assert_raises(Minitest::Assertion) { require_emulator! }

    assert_match(%r{test/lowering/gba/}, failed.message)
  end

  # A test that asks whether the console draws what the interpreter draws has no console to ask
  # here. So on a native run the same line asks it of the game as C: the same program and the
  # same held buttons, compared with the interpreter on every frame.
  def test_a_whole_picture_comparison_is_made_of_the_game_as_c_on_a_native_run
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

    assert_kind_of CheckedPlayer, played
    assert_equal 4, played[:x], "the buttons were held on all four frames, so the game moved four times"
  end

  # ...and a test that asks something native cannot answer yet says so, with its reason.
  def test_a_test_native_cannot_play_yet_skips_with_its_reason
    skipped = assert_raises(Minitest::Skip) { skip_on_native "reads the sprites by name" }

    assert_match(/reads the sprites by name/, skipped.message)
  end
end
