# frozen_string_literal: true

require "test_helper"
require "console/gba/examples/test_grid_cursor_example"

# The grid-cursor example on the Advance's cartridge: it builds, and it renders and steers in the
# emulator. What the cursor does on every run that plays the Advance's games is in
# test/console/gba/examples/test_grid_cursor_example.rb.
class TestGridCursorExampleCartridge < Minitest::Test
  include GridCursorPlaces

  def test_it_builds_a_rom
    rom = GridCursor.build_rom(out: nil, err: nil)
    assert rom.size.positive?
  end

  def test_it_renders_and_steers_on_hardware
    rom = ROM.assemble(GBA.new.lower(GridCursor.program), title: "GRIDCURS", code: "BGRC", maker: "01")
    # Hold left: one down-edge, so the cursor steps one cell left and lights it.
    v = assert_emulator_loads_rom(rom, frames: 6, keys: KEY_LEFT)
    left_px = START_PX - CELL
    assert v.pixel_is?(left_px + 2, START_PY + 2, :cyan),
           "cursor didn't light the cell left of center — got #{v.pixel_gba(left_px + 2, START_PY + 2).to_s(16)}"
    assert v.black?(START_PX + 2, START_PY + 2), "the start cell should be erased (no trail)"
  end
end
