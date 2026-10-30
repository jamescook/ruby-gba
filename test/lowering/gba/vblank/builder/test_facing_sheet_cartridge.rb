# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_facing_sheet"

# A four-way sprite imported from a sheet, on the Advance's cartridge in the emulator. What every
# run draws from the same sheet is in test/all/vblank/builder/test_facing_sheet.rb.
class TestFacingSheetCartridge < Minitest::Test
  include FacingSheetGames

  # --- real hardware: the imported sheet composites on the console ---

  def test_on_console_the_imported_sheet_composites
    rom = ROM.assemble(GBA.new.lower(walker(mode: :tiled, face: :right, run: 3)),
                       title: "FACESHT", code: "BFSH", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3)
    assert v.pixel_is?(44, 44, color(255, 255, 0)),
           "facing right, the console should composite the imported right-facing frame (yellow), got #{v.pixel_gba(44, 44).to_s(16)}"
  end

  def test_the_console_draws_it_with_the_other_colors_too
    v = assert_emulator_loads_rom(assemble_rom(a_recolored_walker, name: "FACECOL"), frames: 4)

    assert_equal Color.resolve(:cyan), v.pixel_gba(44, 44)
  end
end
