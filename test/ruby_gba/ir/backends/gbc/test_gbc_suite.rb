# frozen_string_literal: true

require "test_helper"

# Sits in the Game Boy Color lowering's own folder, so it fails if anything but that lowering's run
# plays it. Every test in this folder is that lowering's alone, and the other runs leave the folder
# out: this is the one that says so the day that stops working (TestSuites::LOWERING_FOLDERS).
class TestGBCSuite < Minitest::Test
  def test_a_test_in_the_gbc_lowerings_folder_runs_only_on_its_run
    assert_equal :gbc, RubyGBA::Testing.lowering, "a test in the Game Boy Color lowering's folder ran on a " \
                                                  "#{RubyGBA::Testing.lowering} run"
  end

  def test_a_game_is_played_as_a_game_boy_color_cartridge_on_this_run
    assert_kind_of RubyGBA::Testing::GBCCheckedPlayer, game_player
  end

  # A file of tests about the game keeps its tests of the Advance's cartridge, which skip
  # themselves here.
  def test_a_test_of_the_advance_cartridge_skips_itself_and_says_why
    skipped = assert_raises(Minitest::Skip) { require_emulator! }

    assert_match(/emulator/, skipped.message)
  end

  # A game laid out for the Advance's screen that draws is not played here, and says why.
  def test_a_game_drawing_on_the_advances_screen_skips_itself
    program = RubyGBA::IR::Build.program(RubyGBA::IR::Build.screen(:bitmap), RubyGBA::IR::Build.pixel(1, 1, :red))
    skipped = assert_raises(Minitest::Skip) { game_player.run(program) }

    assert_match(/laid out for the Advance/, skipped.message)
  end
end
