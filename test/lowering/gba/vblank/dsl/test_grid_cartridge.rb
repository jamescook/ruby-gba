# frozen_string_literal: true

require "test_helper"

# A grid of cells on the Advance's cartridge: the board lowers to a cartridge, and the cell it
# paints is read back in the emulator. What a grid paints on every run is in
# test/all/vblank/dsl/test_grid.rb.
class TestGridCartridge < Minitest::Test
  # ---- cross-backend: the same board renders on the console ----

  private def grid_rom
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      board = grid :board, cols: 30, rows: 20, cell: 8, over: :black
      board.set_cell 3, 2, :white   # the 8x8 square at (24, 16)
      halt
    end
    builder.finalize_program
    ROM.assemble(GBA.new.lower(builder.program), title: "GRIDTEST", code: "BGRD", maker: "01")
  end

  def test_grid_lowers_to_a_valid_rom
    assert grid_rom.size.positive?
  end

  # ---- hardware: the same cell paints on the console ----

  def test_a_cell_renders_white_on_the_console
    v = assert_emulator_loads_rom(grid_rom, frames: 2)
    assert v.white?(28, 20), "cell (3,2) not white on hardware — got #{v.pixel_gba(28, 20).to_s(16)}"
    assert v.black?(4, 4), "an unpainted cell should stay the background"
  end
end
