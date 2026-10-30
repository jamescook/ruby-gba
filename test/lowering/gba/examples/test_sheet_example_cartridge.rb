# frozen_string_literal: true

require "test_helper"

require "stringio"
require "console/gba/examples/test_sheet_example"

# The Sheet example's cartridge (examples/sheet.rb): it builds clean, and the imported tiles and
# sprite render on real hardware, read in the emulator. What the game shows is in
# test/console/gba/examples/test_sheet_example.rb.
class TestSheetExampleCartridge < Minitest::Test
  include SheetExampleArt

  def test_the_example_builds_clean
    rom = Sheet.build_rom(out: StringIO.new, err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # The same as the interpreter's, on real hardware.
  def test_imported_tiles_and_sprite_render_on_the_console
    v = assert_emulator_loads_rom(Sheet.build_rom(out: StringIO.new, err: StringIO.new), frames: 12)

    assert v.pixel_is?(*BRICK_AT, BRICK), "brick, got 0x#{format('%04X', v.pixel_gba(*BRICK_AT))}"
    assert v.pixel_is?(*FLOOR_AT, FLOOR), "floor, got 0x#{format('%04X', v.pixel_gba(*FLOOR_AT))}"
    assert v.pixel_is?(*BODY_AT, HERO),   "hero body, got 0x#{format('%04X', v.pixel_gba(*BODY_AT))}"
    assert v.pixel_is?(*CORNER_AT, FLOOR),
           "floor through the hero's cut-out, got 0x#{format('%04X', v.pixel_gba(*CORNER_AT))}"
  end
end
