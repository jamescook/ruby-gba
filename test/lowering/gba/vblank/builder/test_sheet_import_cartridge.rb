# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_sheet_import"

# A sprite sliced from a sheet, on the Advance's cartridge, read back in the emulator. What the
# importer and the verbs do on every run is in test/all/vblank/builder/test_sheet_import.rb.
class TestSheetImportCartridge < Minitest::Test
  include SheetImportGames

  def test_the_console_draws_a_sheet_sprite_with_other_colors_too
    v = assert_emulator_loads_rom(assemble_rom(a_sheet_sprite_drawn_with_other_colors, name: "SHTCOL"), frames: 4)

    assert_equal Color.resolve(:yellow), v.pixel_gba(12, 12)
  end
end
