# frozen_string_literal: true

require "test_helper"

# THE TESTS OF vblank/builder/test_save_var_record.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
#
# A `save_var` ON 64K OR 128K OF SAVE MEMORY, which is flash: the save_vars are kept in a
# record of their own that saves itself a pass after one of them changes, rather than written
# in place as they are on 32K.
class TestSaveVarRecordOnTheAdvance < Minitest::Test
  include VBlank::Console::Hardware

  # The frame A is pressed on: after the first power-on of a fresh chip has written its table.
  PRESS = 8

  # A game whose save_var :best starts at 3 and is set to 7 when A is pressed — or, with
  # +every_frame+, goes up by one every frame. +more+ declares a second save_var after it, the
  # way an update to the game would.
  private def game(every_frame: false, more: false)
    VBlank.game("FLASHVAR", consoles: %i[gba], save_memory: 64) do
      screen :bitmap
      best = save_var :best, 3
      save_var :wins, 5 if more
      game_loop do
        every_frame ? best.add!(1) : pressed(:a).then { best.set! 7 }
      end
    end
  end

  private def rom_of(game) = game.build_rom(out: nil, err: nil, profile: false)

  # The save memory after A is pressed and the save has had time to go in.
  private def saved_by_playing(game)
    store = SaveImage.new(kilobytes: 64)
    game_player(save: store).input_each_frame { |f| f == PRESS ? [:a] : [] }.run(game.program, frames: 24)
    store
  end

  # An update that adds a save_var finds the one saved before it, and starts the new one at
  # its default.
  def test_an_update_that_adds_a_save_var_keeps_the_saved_one
    store = saved_by_playing(game)
    back = game_player(save: store).run(game(more: true).program, frames: 2)

    assert_equal 7, back[:best]
    assert_equal 5, back[:wins]
  end

  # How many saves the save_vars' record holds: the newer of its two halves' sequence numbers,
  # each one more than the last save's. A half never written reads as -1.
  private def saves_made(chip)
    row = chip.table.find { |one| one.key == VBlank::IR::SaveLayout.record_key(:_save_vars) }
    [0, chip.memory.block].map { |half| chip.word(row.at + half + VBlank::IR::SaveLayout::SEQUENCE_AT) }.max
  end

end
