# frozen_string_literal: true

require "test_helper"
require "all/vblank/graphics/test_aseprite"

# Sprites imported from Aseprite files on the Advance's cartridge, read back in the emulator.
# The parsers, and what the imported sprites do on every run, are in
# test/all/vblank/graphics/test_aseprite.rb.
class TestAsepriteCartridge < Minitest::Test
  include AsepriteGames

  # --- real hardware: the imported, played animation composites on the console ---

  def test_on_console_a_played_animation_composites
    rom = ROM.assemble(GBA.new.lower(game(mode: :tiled, run: 3, play: :blink)),
                       title: "ASEPRIT", code: "BASE", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3)
    assert v.pixel_is?(44, 44, c(0, 0, 255)),
           "blink's first frame (blue) should composite on the console, got #{v.pixel_gba(44, 44).to_s(16)}"
  end

  def test_on_console_a_native_aseprite_file_composites
    rom = ROM.assemble(GBA.new.lower(game(mode: :tiled, run: 3, file: BINARY, play: :idle)),
                       title: "ASEBIN", code: "BABN", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3)
    assert v.pixel_is?(44, 44, c(0, 0, 255)),
           "a native .aseprite file: play(:idle)'s blue should composite on the console, got #{v.pixel_gba(44, 44).to_s(16)}"
  end

  def test_the_console_draws_an_aseprite_sprite_with_other_colors_too
    v = assert_emulator_loads_rom(assemble_rom(an_aseprite_sprite_drawn_with_other_colors, name: "ASECOL"), frames: 4)

    assert_equal Color.resolve(:cyan), v.pixel_gba(44, 44)
  end
end
