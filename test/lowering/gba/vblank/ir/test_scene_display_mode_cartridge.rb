# frozen_string_literal: true

require "test_helper"
require "all/vblank/ir/test_scene_display_mode"

# Per-scene bitmap<->tiled switching on the Advance's cartridge: the crossing lowers to a
# cartridge, and the console reconfigures its display on it, read back in the emulator. The
# model on every run is in test/all/vblank/ir/test_scene_display_mode.rb.
class TestSceneDisplayModeCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include SceneDisplayModeGames

  # A program that crosses the bitmap/tiled boundary lowers to a GBA ROM — the backend
  # switches the whole display per scene (the mode register plus the VRAM/OAM layout),
  # so it no longer refuses the program. (Its behavior on the console is asserted by the
  # the emulator test below.)
  def test_a_mixed_bitmap_and_tiled_program_lowers_to_a_rom
    code = GBA.new.lower(bitmap_to_tiled_program)
    assert_operator code.bytesize, :>, 0
  end

  # The same crossing on real hardware (the emulator): the console shows the direct-color
  # bitmap title, and after START it reconfigures the whole display — the mode
  # register, the sprite table, the VRAM the tiles/sprites live in — so the tiled
  # scene's hardware sprite renders and the bitmap title's red is gone.
  def test_the_switch_flips_the_display_on_the_console
    rom = ROM.assemble(GBA.new.lower(bitmap_to_tiled_program), title: "MIX", code: "BMIX", maker: "01")

    title = assert_emulator_loads_rom(rom, frames: 4) # no input: the Mode 3 bitmap title
    assert title.red?(0, 0),
           "the bitmap title is red on the console, got 0x#{format('%04X', title.pixel_gba(0, 0))}"

    play = assert_emulator_loads_rom(rom, frames: 8, keys: KEY_START) # START -> the tiled scene
    assert play.green?(103, 79),
           "the tiled hardware sprite renders after the switch, got 0x#{format('%04X', play.pixel_gba(103, 79))}"
    refute play.red?(0, 0),
           "the bitmap title's red is gone once the display crosses into tiled, got 0x#{format('%04X', play.pixel_gba(0, 0))}"
  end
end
