# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_hardware_sprite_facing"

# A hardware sprite's poses on the Advance's cartridge, read back in the emulator. What every
# run is held to is in test/all/vblank/dsl/test_hardware_sprite_facing.rb.
class TestHardwareSpriteFacingCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include HardwareSpriteFacingGames

  private def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "FACING", code: "BFAC", maker: "01")
  end

  def test_facing_swaps_the_pose_on_the_console
    vl = assert_emulator_loads_rom(rom_for(facing_program), frames: 42, keys: KEY_LEFT)
    assert vl.blue?(10, 43), "left-facing pose renders blue, got 0x#{format('%04X', vl.pixel_gba(10, 43))}"

    vr = assert_emulator_loads_rom(rom_for(facing_program), frames: 42, keys: KEY_RIGHT)
    assert vr.red?(138, 43), "right-facing pose renders red, got 0x#{format('%04X', vr.pixel_gba(138, 43))}"
  end
end
