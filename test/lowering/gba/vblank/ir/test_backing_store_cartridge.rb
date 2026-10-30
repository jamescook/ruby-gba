# frozen_string_literal: true

require "test_helper"
require "all/vblank/ir/test_backing_store"

# The backing-store primitive on the Advance's cartridge: the round-trip of
# test/all/vblank/ir/test_backing_store.rb, read in the emulator.
class TestBackingStoreCartridge < Minitest::Test
  include BackingStoreGames

  # ---- hardware: the same round-trip on the console ----

  def test_restore_reinstates_the_patch_on_the_console
    rom = ROM.assemble(GBA.new.lower(cover_and_restore([10, 10], [10, 10])),
                       title: "BACKSTOR", code: "BBKS", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 2)
    assert v.red?(12, 12), "the red patch wasn't restored on hardware — got #{v.pixel_gba(12, 12).to_s(16)}"
    assert v.blue?(10, 10), "the blue surround wasn't restored on hardware"
    refute v.pixel_is?(14, 14, :green), "green survived the restore on hardware"
  end
end
