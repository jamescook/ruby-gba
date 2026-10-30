# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_hardware_sprites_multi"

# Several hardware sprites at once on the Advance's cartridge, read in the emulator: their
# colours, which is in front, hiding and showing. What they do on every run is in
# test/all/vblank/dsl/test_hardware_sprites_multi.rb.
class TestHardwareSpritesMultiCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include HardwareSpritesMultiGames

  private def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "MULTISPR", code: "BMSP", maker: "01")
  end

  def test_layering_and_shared_palette_on_the_console
    v = assert_emulator_loads_rom(rom_for(overlapping_pair), frames: 3)
    assert v.red?(41, 41),  "red renders, got 0x#{format('%04X', v.pixel_gba(41, 41))}"
    assert v.blue?(50, 50), "blue renders, got 0x#{format('%04X', v.pixel_gba(50, 50))}"
    assert v.blue?(46, 46), "the later sprite is in front, got 0x#{format('%04X', v.pixel_gba(46, 46))}"
  end

  def test_hide_and_show_on_the_console
    hidden = assert_emulator_loads_rom(rom_for(visibility_program(shown: true, frames: 4)), frames: 6)
    assert hidden.white?(44, 44), "a hidden sprite shows the floor, got 0x#{format('%04X', hidden.pixel_gba(44, 44))}"

    shown = assert_emulator_loads_rom(rom_for(visibility_program(shown: false, frames: 4)), frames: 6)
    assert shown.red?(44, 44), "a shown sprite appears, got 0x#{format('%04X', shown.pixel_gba(44, 44))}"
  end
end
