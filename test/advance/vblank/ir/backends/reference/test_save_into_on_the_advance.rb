# frozen_string_literal: true

require "test_helper"

# THE TESTS OF vblank/ir/backends/reference/test_save_into.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# A TEST WRITES A SAVE INTO SAVE MEMORY, so a game starts from a save it chose rather than
# being played until it saves one. The copy is the one the game itself would have written,
# so the game treats it the same as its own: good, read by peek and load, saved over, erased
# and copied like any other.
class TestSaveIntoOnTheAdvance < Minitest::Test
  private def built(save_memory: nil, &block)
    save_memory ? VBlank.game("PUTSAVE", consoles: %i[gba], save_memory: save_memory, &block) : VBlank.game("PUTSAVE", consoles: %i[gba], &block)
  end

  private def files(save_memory: nil) = files_game(save_memory: save_memory).program

  # Two copies of a file keeping the hearts and a name, and a record of options keeping a
  # volume that holds a fraction. At power-on the game says whether copy 0 and copy 1 are good,
  # peeks at copy 1's hearts, and loads copy 0 and the options. A saves copy 0 with 7 hearts;
  # SELECT erases copy 1; START copies copy 0 over copy 1.
  private def files_game(save_memory: nil)
    built(save_memory: save_memory) do
      screen :bitmap
      hearts = var :hearts, 3
      name = list :name, capacity: 6, width: :byte
      volume = var :volume, 0.5
      first_good = var :first_good, 0
      second_good = var :second_good, 0
      second_hearts = var :second_hearts, 0
      file = save_data(:file, copies: 2) { keep hearts, name }
      options = save_data(:options) { keep volume }
      file[0].good?.then { first_good.set! 1 }
      file[1].good?.then { second_good.set! 1 }
      second_hearts.set! file[1].peek(hearts)
      file[0].load
      options[0].load
      game_loop do
        pressed(:a).then do
          hearts.set! 7
          file[0].save
        end
        pressed(:select).then { file[1].erase }
        pressed(:start).then { file.copy 0, to: 1 }
      end
    end
  end

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

  # --- the console starts from a written copy too ---

  # The cartridge built from the same game, booted on each image: the copy is good, and the
  # game loads what was written. Nothing is rebuilt between the two.
  private def console_starts_from(save_memory: nil)
    game = files_game(save_memory: save_memory)
    rom = game.build_rom(out: nil, err: nil, profile: false)
    [3, 15].map do |hearts|
      image = Reference.save_into(SaveImage.new, game.program, :file, 0, hearts: hearts, name: [1, 2, 3])
      Reference.save_into(image, game.program, :file, 1, hearts: hearts + 1)
      v = assert_emulator_loads_rom(rom, frames: 6, save: image, vars: rom.var_addresses)
      [v.var(:first_good), v.var(:hearts), v.var(:second_hearts)]
    end
  end

  # --- what a test can get wrong ---

end
