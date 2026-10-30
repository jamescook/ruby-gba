# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_computed_tilemap"

# A map the build computes, on the Advance's cartridge: the board it renders and the wall it
# stops a mover at, read back in the emulator. What the maps do on every run is in
# test/all/vblank/builder/test_computed_tilemap.rb.
class TestComputedTilemapCartridge < Minitest::Test
  include ComputedTilemapGames

  def test_a_computed_map_stops_a_mover_on_the_console
    v = assert_emulator_loads_rom(assemble_rom(walled_room, name: "COMPWALL"), frames: 30,
                                  keys: VBlank::Console::Hardware::KEY_RIGHT)
    assert v.red?(28, 20), "the hero stops flush against the wall"
    refute v.red?(36, 20), "the hero never crossed into the wall"
  end

  # --- Hardware: the same computed board renders on the console ---

  def test_a_computed_board_renders_on_the_console
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
    end
    numbered_tileset(b)
    b.instance_eval do
      background :board, tiles: :room, map: [[0, 1], [1, 0]]
      halt
    end
    b.finalize_program
    rom = assemble_rom(b.program, name: "COMPUTED")
    v = assert_emulator_loads_rom(rom, frames: 2)
    assert v.red?(1, 1),  "tile 0 renders in cell (0,0)"
    assert v.blue?(5, 1), "tile 1 renders in cell (1,0)"
  end
end
