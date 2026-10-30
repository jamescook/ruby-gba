# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_save"

# `save_var` ON THE ADVANCE'S CARTRIDGE: the game writes real SRAM, read straight back in the
# emulator, and the cartridge carries the signature that says it saves. The round-trip played on
# every run is in test/all/vblank/builder/test_save.rb.
class TestSaveCartridge < Minitest::Test
  include SaveGames

  SRAM = 0x0E000000 # where save memory is mapped

  # --- Console (the emulator): the game writes real SRAM, read straight back ---

  def test_the_console_writes_the_high_score_into_battery_ram
    rom = VBlank::Cartridge::ROM.assemble(GBA.new.lower(build(&KEEPER)), title: "SAVE", code: "BSAV", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 6)

    assert_equal SAVE_MAGIC, sram_word(v, SRAM), "the marker should be written to save memory"
    assert_equal 7, sram_word(v, SRAM + 4), "the high score should sit in its save slot"
  end

  # --- The save-type signature the emulator/flashcart scans for ---

  def test_a_saving_rom_carries_the_sram_signature
    code = GBA.new.lower(build(&KEEPER))
    assert_includes code, "SRAM_V".b, "a ROM that saves must declare its save type"
  end

  def test_a_rom_that_saves_nothing_has_no_signature
    code = GBA.new.lower(build { screen :bitmap; game_loop { wait_vblank } })
    refute_includes code, "SRAM_V".b, "a ROM that persists nothing should not claim a save chip"
  end

  private

  # Read a 4-byte little-endian value out of the console's save memory, one byte at a
  # time (SRAM is an 8-bit bus, so a byte read is the honest way to see what's there).
  def sram_word(verifier, address)
    (0..3).sum { |i| verifier.mem8(address + i) << (i * 8) }
  end
end
