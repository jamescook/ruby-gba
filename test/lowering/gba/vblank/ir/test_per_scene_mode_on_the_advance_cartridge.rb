# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/ir/test_per_scene_mode_on_the_advance"

# A rotozoom scene taking over from a painted title, on the Advance's cartridge in the emulator,
# held to the interpreter (game_player on the gba run). What the game shows on every run that
# plays the Advance is in test/console/gba/vblank/ir/test_per_scene_mode_on_the_advance.rb.
class TestPerSceneModeOnTheAdvanceCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include PerSceneModeOnTheAdvanceGames

  def test_a_bitmap_title_is_gone_once_a_rotozoom_scene_takes_over
    spun = spun_after_start
    rom = assemble_rom(rotozoom_after_a_bitmap_title, name: "SPINOVER")
    v = assert_emulator_loads_rom(rom, frames: 10, keys: ->(f) { f == 3 ? KEY_START : 0 })
    refute v.red?(0, 0), "the console leaves it behind, got 0x#{format('%04X', v.pixel_gba(0, 0))}"
    assert_equal v.pixel_gba(0, 0), spun.screen.pixel(0, 0), "and both show the same thing there"
  end
end
