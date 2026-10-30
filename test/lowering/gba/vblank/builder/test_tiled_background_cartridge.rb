# frozen_string_literal: true

require "test_helper"

# A tiled background on the Advance's cartridge: the board of
# test/all/vblank/builder/test_tiled_background.rb, read in the emulator.
class TestTiledBackgroundCartridge < Minitest::Test
  # A 4x4 solid tile of one color, as ASCII art (small, so the grid math is easy
  # to read: cell (c, r) covers x 4c..4c+3, y 4r..4r+3).
  private def solid_tile(builder, name, color)
    builder.image(name, "#" => color) { "####\n####\n####\n####" }
  end

  # --- Hardware: the same board renders on the console ---

  def test_the_board_renders_on_the_console
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
    end
    solid_tile(b, :red_tile, :red)
    solid_tile(b, :blue_tile, :blue)
    b.instance_eval do
      tiles :checker, "R" => :red_tile, "B" => :blue_tile
      background :board, tiles: :checker, map: "RB\nBR"
      halt
    end
    b.finalize_program
    rom = ROM.assemble(GBA.new.lower(b.program), title: "TILES", code: "BTIL", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 2)
    assert v.red?(1, 1),  "the red tile renders in cell (0,0)"
    assert v.blue?(5, 1), "the blue tile renders in cell (1,0)"
  end
end
