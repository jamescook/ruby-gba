# frozen_string_literal: true

require "test_helper"

# The high-score game and how it is built, shared with the cartridge's tests
# (test/lowering/gba/vblank/builder/test_save_cartridge.rb).
module SaveGames
  SAVE_MAGIC = 0x53415631 # "SAV1", the marker written alongside the saved values

  # A game that keeps a high score: sets a score of 7, and records it when it beats
  # the saved best. Beating a fresh (0) best on the first frame saves 7.
  KEEPER = Ractor.make_shareable(proc do
    screen :bitmap
    high = save_var :high_score, 0
    s = var :s, 0
    game_loop do
      wait_vblank
      s.set! 7
      (s > high).then { high.set! s }
    end
  end)

  private def build(&block)
    b = VBlank::Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end
end

# Persistence: `save_var` — a variable whose value survives power-off. It's loaded
# from the cartridge's save memory at boot (or its default on a fresh cartridge) and
# re-saved automatically whenever it changes. These tests prove the round-trip on
# every run: a power cycle is two runs sharing one save store. The Advance's cartridge
# writing real SRAM, read straight back in the emulator, and the save-type signature it
# carries are in test/lowering/gba/vblank/builder/test_save_cartridge.rb.
class TestSave < Minitest::Test
  include SaveGames

  # A game that only declares the persisted variable and never writes it — so its
  # value can only come from what was saved before (or the default on a fresh cart).
  READER = proc do
    screen :bitmap
    save_var :high_score, 0
    game_loop { wait_vblank }
  end

  # --- Reference interpreter: a power cycle is two runs sharing one save store ---

  def test_a_saved_value_comes_back_on_the_next_boot
    store = SaveImage.new
    game_player(save: store).run(build(&KEEPER), frames: 3)

    reborn = game_player(save: store).run(build(&READER), frames: 1)
    assert_equal 7, reborn[:high_score], "the saved high score should load at the next boot"
  end

  def test_a_fresh_cartridge_starts_from_the_default
    fresh = game_player(save: SaveImage.new).run(build(&READER), frames: 1)
    assert_equal 0, fresh[:high_score], "with nothing saved, a save_var starts from its default"
  end

  def test_changing_a_saved_variable_writes_it_through_immediately
    store = SaveImage.new
    game_player(save: store).run(build(&KEEPER), frames: 3)
    assert_equal 7, store.word(4), "the new high score is mirrored to its save slot, where the console keeps it"
    assert_equal SAVE_MAGIC, store.word(0), "the marker is stamped so the next boot trusts the data"
  end

  def test_the_default_is_only_ever_a_whole_number
    b = VBlank::Builder.new
    err = assert_raises(ArgumentError) { b.save_var(:hp, "lots") }
    assert_match(/whole number/, err.message)
  end

  # save_var's block of save memory ends where save_data's table of places begins, so one
  # more would overwrite every save file. Refused where it is declared, for both backends.
  def test_one_save_var_more_than_its_block_holds_is_refused
    b = VBlank::Builder.new
    1023.times { |i| b.save_var(:"kept#{i}", 0) }
    err = assert_raises(ArgumentError) { b.save_var(:one_too_many, 0) }

    assert_match(/1024 save_var/, err.message)
    assert_match(/save_data/, err.message)
  end
end
