# frozen_string_literal: true

require "test_helper"

# A TEST WRITES A save_var's NUMBER INTO SAVE MEMORY, so a game starts with a high score it
# chose rather than being played until it reaches one. The game's own code writes it, so the
# game reads it back as its own.
#
# The Advance's cartridge starting from a written save_var, read in the emulator, is in
# test/lowering/gba/vblank/ir/backends/reference/test_save_vars_into_cartridge.rb, which plays
# the game kept here in SaveVarsIntoGames.
module SaveVarsIntoGames
  # A best score and a count of games played, both kept through power-off. A raises the best
  # to 50.
  private def scores_game(save_memory: nil)
    block = proc do
      screen :bitmap
      best = save_var :best, 10
      save_var :played, 0
      game_loop { pressed(:a).then { best.set! 50 } }
    end
    save_memory ? VBlank.game("SAVEVARS", consoles: %i[gba], save_memory: save_memory, &block) : VBlank.game("SAVEVARS", consoles: %i[gba], &block)
  end
end

class TestSaveVarsInto < Minitest::Test
  include SaveVarsIntoGames

  private def scores(save_memory: nil) = scores_game(save_memory: save_memory).program

  private def boot(program, image, pressing: {}, frames: 3)
    game_player(save: image).input_each_frame { |f| Array(pressing[f]) }.run(program, frames: frames)
  end

  def test_the_game_starts_with_a_written_save_var
    image = Reference.save_vars_into(SaveImage.new, scores, best: 9999)
    run = boot(scores, image)

    assert_equal 9999, run[:best]
    assert_equal 0, run[:played], "a save_var the test leaves out starts at its default"
  end

  # --- what a test cannot write ---

  def test_a_name_that_is_not_a_save_var
    [nil, 64].each do |memory|
      err = assert_raises(ArgumentError) { Reference.save_vars_into(SaveImage.new, scores(save_memory: memory), bset: 5) }
      assert_match(/:bset/, err.message)
      assert_match(/are :best, :played\./, err.message, "save memory #{memory || 32}K")
    end
  end

  def test_a_program_with_no_save_var
    program = VBlank.game("NOSAVES", consoles: %i[gba]) { screen :bitmap; var :best, 0; game_loop { wait_vblank } }.program
    err = assert_raises(ArgumentError) { Reference.save_vars_into(SaveImage.new, program, best: 5) }
    assert_match(/no save_var/, err.message)
  end

  def test_a_save_var_holds_a_whole_number
    err = assert_raises(ArgumentError) { Reference.save_vars_into(SaveImage.new, scores, best: 9.5) }
    assert_match(/whole number/, err.message)
  end
end
