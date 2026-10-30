# frozen_string_literal: true

require "test_helper"

# THE TESTS OF vblank/ir/backends/reference/test_save_vars_into.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
#
# A TEST WRITES A save_var's NUMBER INTO SAVE MEMORY, so a game starts with a high score it
# chose rather than being played until it reaches one. The game's own code writes it, so the
# game reads it back as its own.
class TestSaveVarsIntoOnTheAdvance < Minitest::Test
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

  private def scores(save_memory: nil) = scores_game(save_memory: save_memory).program

  private def boot(program, image, pressing: {}, frames: 3)
    game_player(save: image).input_each_frame { |f| Array(pressing[f]) }.run(program, frames: frames)
  end

  # On flash the save_vars are kept together and saved a pass after one changes; the written
  # number is in save memory when the call returns all the same.
  def test_flash_takes_a_written_save_var
    image = Reference.save_vars_into(SaveImage.new, scores(save_memory: 64), best: 9999, played: 4)
    run = boot(scores(save_memory: 64), image)

    assert_equal 9999, run[:best]
    assert_equal 4, run[:played]
  end

  # The game saves over a written number as it would over its own: A raises the best, and
  # the next power-on starts with that.
  def test_the_game_saves_over_a_written_save_var
    [nil, 64].each do |memory|
      program = scores(save_memory: memory)
      image = Reference.save_vars_into(SaveImage.new, program, best: 9999)
      boot(program, image, pressing: { 1 => :a }, frames: 400)

      assert_equal 50, boot(program, image)[:best], "save memory #{memory || 32}K"
    end
  end

  # --- the console starts from a written save_var too ---

  private def console_best(save_memory: nil)
    game = scores_game(save_memory: save_memory)
    rom = game.build_rom(out: nil, err: nil, profile: false)
    [1234, 9999].map do |best|
      image = Reference.save_vars_into(SaveImage.new, game.program, best: best, played: 7)
      v = assert_emulator_loads_rom(rom, frames: 6, save: image, vars: rom.var_addresses)
      [v.var(:best), v.var(:played)]
    end
  end

  # --- what a test cannot write ---

end
