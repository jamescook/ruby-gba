# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_hardware_sprite"

# Hardware sprites on the Advance's cartridge: the hero game of
# test/all/vblank/dsl/test_hardware_sprite.rb, read in the emulator.
class TestHardwareSpriteCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include HardwareSpriteGames

  private def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "HWSPRITE", code: "BHWS", maker: "01")
  end

  def test_the_sprite_renders_on_the_console
    v = assert_emulator_loads_rom(rom_for(hero_program(frames: 2)), frames: 3)
    assert v.red?(44, 44),  "the hero renders on hardware, got 0x#{format('%04X', v.pixel_gba(44, 44))}"
    assert v.blue?(8, 8),   "the floor renders behind it, got 0x#{format('%04X', v.pixel_gba(8, 8))}"
  end

  def test_a_moving_sprite_leaves_no_trail_on_the_console
    v = assert_emulator_loads_rom(rom_for(hero_program(frames: 3)), frames: 5, keys: KEY_RIGHT)
    assert v.red?(60, 44),  "the hero moved right, got 0x#{format('%04X', v.pixel_gba(60, 44))}"
    assert v.blue?(44, 44), "no trail at the start column, got 0x#{format('%04X', v.pixel_gba(44, 44))}"
  end
end
