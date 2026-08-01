# frozen_string_literal: true

require_relative "test_helper"

# Persistence: `save_var` — a variable whose value survives power-off. It's loaded
# from the cartridge's save memory at boot (or its default on a fresh cartridge) and
# re-saved automatically whenever it changes. These tests prove the round-trip on
# both backends: the reference interpreter models a power cycle with an injected save
# store, and the console (gemba) writes real SRAM the test reads straight back.
class TestSave < Minitest::Test
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby
  GBA  = RubyGBA::IR::Backends::GBA
  SAVE_MAGIC = 0x53415631 # "SAV1", the marker written alongside the saved values
  SRAM = 0x0E000000       # where save memory is mapped

  # A game that keeps a high score: sets a score of 7, and records it when it beats
  # the saved best. Beating a fresh (0) best on the first frame saves 7.
  KEEPER = proc do
    screen :bitmap
    high = save_var :high_score, 0
    s = var :s, 0
    game_loop do
      wait_vblank
      s.set 7
      (s > high).then { high.set s }
    end
  end

  # A game that only declares the persisted variable and never writes it — so its
  # value can only come from what was saved before (or the default on a fresh cart).
  READER = proc do
    screen :bitmap
    save_var :high_score, 0
    game_loop { wait_vblank }
  end

  def build(&block)
    b = RubyGBA::Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # --- Reference interpreter: a power cycle is two runs sharing one save store ---

  def test_a_saved_value_comes_back_on_the_next_boot
    store = {}
    Ruby.new(save: store).run(build(&KEEPER), frames: 3)

    reborn = Ruby.new(save: store).run(build(&READER), frames: 1)
    assert_equal 7, reborn[:high_score], "the saved high score should load at the next boot"
  end

  def test_a_fresh_cartridge_starts_from_the_default
    fresh = Ruby.new(save: {}).run(build(&READER), frames: 1)
    assert_equal 0, fresh[:high_score], "with nothing saved, a save_var starts from its default"
  end

  def test_changing_a_saved_variable_writes_it_through_immediately
    store = {}
    Ruby.new(save: store).run(build(&KEEPER), frames: 3)
    assert_equal 7, store[0], "the new high score is mirrored to its save slot"
    assert_equal SAVE_MAGIC, store[:magic], "the marker is stamped so the next boot trusts the data"
  end

  def test_the_default_is_only_ever_a_whole_number
    b = RubyGBA::Builder.new
    err = assert_raises(ArgumentError) { b.save_var(:hp, "lots") }
    assert_match(/whole number/, err.message)
  end

  # --- Console (gemba): the game writes real SRAM, read straight back ---

  def test_the_console_writes_the_high_score_into_battery_ram
    rom = RubyGBA::ROM.assemble(GBA.new.lower(build(&KEEPER)), title: "SAVE", code: "BSAV", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)

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
