# frozen_string_literal: true

require "test_helper"
require "console/gba/examples/test_level_example"

# The Level example (examples/level.rb) on the Advance's cartridge, read back in the
# emulator. What the game does on every run is in test/console/gba/examples/test_level_example.rb.
class TestLevelExampleCartridge < Minitest::Test
  include LevelExampleSpots

  # The same, on real hardware.
  def test_the_csv_level_renders_on_the_console
    v = assert_emulator_loads_rom(Level.build_rom(out: StringIO.new, err: StringIO.new), frames: 12)

    assert v.pixel_is?(*BRICK_AT, BRICK), "brick, got 0x#{format('%04X', v.pixel_gba(*BRICK_AT))}"
    assert v.pixel_is?(*FLOOR_AT, FLOOR), "floor, got 0x#{format('%04X', v.pixel_gba(*FLOOR_AT))}"
    assert v.pixel_is?(*BODY_AT, HERO),   "hero body, got 0x#{format('%04X', v.pixel_gba(*BODY_AT))}"
    assert v.pixel_is?(*CORNER_AT, FLOOR),
           "floor through the hero's cut-out, got 0x#{format('%04X', v.pixel_gba(*CORNER_AT))}"
  end
end
