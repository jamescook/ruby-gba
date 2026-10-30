# frozen_string_literal: true

require "test_helper"
require "all/vblank/ir/backends/reference/test_save_into"

# THE TESTS OF vblank/ir/backends/reference/test_save_into.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file, and the
# Advance's cartridge starting from a written copy is in
# test/lowering/gba/vblank/ir/backends/reference/test_save_into_cartridge.rb.
#
# A TEST WRITES A SAVE INTO SAVE MEMORY, so a game starts from a save it chose rather than
# being played until it saves one. The copy is the one the game itself would have written,
# so the game treats it the same as its own: good, read by peek and load, saved over, erased
# and copied like any other.
class TestSaveIntoOnTheAdvance < Minitest::Test
  include SaveIntoGames

  private def boot(program, image, pressing: {}, frames: 3)
    game_player(save: image).input_each_frame { |f| Array(pressing[f]) }.run(program, frames: frames)
  end

  def test_flash_save_memory_takes_a_written_copy
    program = files(save_memory: 64)
    image = SaveImage.new
    Reference.save_into(image, program, :file, 0, hearts: 12, name: [1, 2])
    run = boot(program, image)

    assert_equal [1, 12, [1, 2]], [run[:first_good], run[:hearts], run.list(:name)]
  end
end
