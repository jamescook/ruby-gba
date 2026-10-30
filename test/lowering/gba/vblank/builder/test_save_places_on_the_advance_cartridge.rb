# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/builder/test_save_places_on_the_advance"

# Where each `save_data` record goes at power-on, on the Advance's cartridge: its save memory
# read back in the emulator. The rules one at a time, on every run that plays the Advance's
# games, are in test/console/gba/vblank/builder/test_save_places_on_the_advance.rb.
class TestSavePlacesOnTheAdvanceCartridge < Minitest::Test
  include SavePlacesGames

  # The console runs the same rules on the same save memory and ends with the same table.
  def test_the_console_slides_records_together_the_way_the_interpreter_does
    third = ((ROOM / 3) / 4) * 4
    records = { left: {}, right: {}, big: { bytes: (third * 3 / 4) & ~3 } }
    rows = [row(:left, START + third), row(:right, START + (2 * third))]
    oracle = placed(records, rows)
    rom = assemble_rom(game(records), name: "SLIDE")
    v = assert_emulator_loads_rom(rom, frames: 12, save: SaveImage.new.write_table(rows))
    table = (0...(Layout::PACKED.data_start - Layout::PACKED.table_at)).to_h do |i| # both halves of the table
      [Layout::PACKED.table_at + i, v.mem8(VBlank::Console::Hardware::SRAM_START + Layout::PACKED.table_at + i)]
    end
    by_key = records.keys.to_h { |name| [Layout.record_key(name), name] }

    assert_equal oracle, SaveImage.new(bytes: table).table.to_h { |one| [by_key.fetch(one.key), [one.at, one.copies]] }
  end
end
