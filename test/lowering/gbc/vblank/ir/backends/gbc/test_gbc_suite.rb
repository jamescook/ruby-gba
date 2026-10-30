# frozen_string_literal: true

require "test_helper"

# Sits in the Game Boy Color lowering's own folder, so it fails if anything but that lowering's run
# plays it. Every test in this folder is that lowering's alone, and the other runs leave the folder
# out: this is the one that says so the day that stops working (TestSuites::LOWERING_FOLDERS).
class TestGBCSuite < Minitest::Test
  def test_a_test_in_the_gbc_lowerings_folder_runs_only_on_its_run
    assert_equal :gbc, VBlank::Testing.lowering, "a test in the Game Boy Color lowering's folder ran on a " \
                                                  "#{VBlank::Testing.lowering} run"
  end

  def test_a_game_is_played_as_a_game_boy_color_cartridge_on_this_run
    assert_kind_of VBlank::Testing::CartridgeCheckedPlayer.for(:gbc), game_player
  end

  # A test of the Advance's cartridge belongs in test/lowering/gba/; reached here, it fails saying so.
  def test_a_test_of_the_advance_cartridge_fails_here_and_says_where_it_goes
    failed = assert_raises(Minitest::Assertion) { require_emulator! }

    assert_match(%r{test/lowering/gba/}, failed.message)
  end

  # A test's program that names no console is played here as a Color program, on the Color's
  # screen, and checked against the interpreter playing it the same way. (A test of what only the
  # Advance can do is not in this run at all: test/console/gba.)
  def test_a_tests_program_is_played_as_a_color_program
    program = VBlank::IR::Build.program(VBlank::IR::Build.screen(:bitmap), VBlank::IR::Build.pixel(1, 1, :red),
                                         VBlank::IR::Build.halt)
    screen = game_player.run(program, frames: 2).screen

    assert_equal [160, 144], [screen.width, screen.height]
    assert_equal VBlank::Graphics::Color.resolve(:red), screen.pixel(1, 1)
  end
end
