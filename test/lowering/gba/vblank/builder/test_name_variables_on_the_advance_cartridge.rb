# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/builder/test_name_variables_on_the_advance"

# Scenes picked by a name, on the Advance's own cartridge: the console hands the screen from the
# title to the walk, read off its screen and sprite table in the emulator. What every run that
# plays the Advance shows is in test/console/gba/vblank/builder/test_name_variables_on_the_advance.rb,
# which keeps the game both files play in NameVariablesOnTheAdvanceGames.
class TestNameVariablesOnTheAdvanceCartridge < Minitest::Test
  include NameVariablesOnTheAdvanceGames

  def test_both_backends_hand_the_screen_between_scenes_picked_by_name
    rom = assemble_rom(scenes_by_name, name: "BYNAME")
    v = assert_emulator_loads_rom(rom, frames: 4)
    assert_equal BLUE, v.pixel_gba(120, 80), "the console shows the title's backdrop"
    v.step(2, keys: VBlank::Console::Hardware::KEY_A)
    v.step(4)
    assert_equal RED, v.pixel_gba(120, 80), "and the world once the walk has taken over"
    assert_empty v.sprites.select { |row| row.name.nil? }, "the title's text is gone"
  end
end
