# frozen_string_literal: true

require "test_helper"
require "console/gba/examples/test_tiles_example"

# The tiles example (examples/tiles.rb) on the Advance's cartridge, read back in the emulator.
# What every run that plays the Advance is held to is in
# test/console/gba/examples/test_tiles_example.rb.
class TestTilesExampleCartridge < Minitest::Test
  include TilesExamplePoints

  # Tile mode draws the whole layer from data uploaded once at boot, so a couple of
  # frames is plenty — there's no per-tile stamping to wait on.
  def test_the_room_renders_on_the_console
    v = assert_emulator_loads_rom(Tiles.build_rom(err: StringIO.new), frames: 3)
    assert v.pixel_is?(*WALL, :gray), "wall renders on hardware, got 0x#{format('%04X', v.pixel_gba(*WALL))}"
    assert v.blue?(*WATER),  "water renders on hardware, got 0x#{format('%04X', v.pixel_gba(*WATER))}"
    assert v.green?(*GRASS), "grass renders on hardware, got 0x#{format('%04X', v.pixel_gba(*GRASS))}"
  end

  # RIGHT walks into the next room, which is the whole map handed over at once. The grass
  # patch of the hall is water in the cavern, so one pixel says which room is showing.
  # Tapped rather than held, because `pressed` reads the press edge.
  RIGHT = 0x0010

  def test_walking_into_the_next_room_hands_the_background_that_whole_map
    tap_right = ->(frame) { frame > 3 && frame < 6 ? RIGHT : 0 }
    v = assert_emulator_loads_rom(Tiles.build_rom(err: StringIO.new), frames: 12, keys: tap_right)

    assert v.blue?(*GRASS),
           "the cavern's water stands where the hall's grass did, got 0x#{format('%04X', v.pixel_gba(*GRASS))}"
    assert v.pixel_is?(*WALL, :gray), "and its wall border is still a wall"
  end
end
