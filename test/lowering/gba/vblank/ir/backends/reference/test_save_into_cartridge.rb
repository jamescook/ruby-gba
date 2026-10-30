# frozen_string_literal: true

require "test_helper"
require "all/vblank/ir/backends/reference/test_save_into"

# A save a test wrote into save memory, read by the Advance's cartridge in the emulator. What the
# game does with such a save on every run is in test/all/vblank/ir/backends/reference/test_save_into.rb.
class TestSaveIntoCartridge < Minitest::Test
  include SaveIntoGames

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

  # Copy 0 loaded, and copy 1 peeked at without loading it.
  def test_the_console_starts_from_a_written_copy
    assert_equal [[1, 3, 4], [1, 15, 16]], console_starts_from
  end

  def test_the_console_starts_from_a_written_copy_on_flash
    assert_equal [[1, 3, 4], [1, 15, 16]], console_starts_from(save_memory: 64)
  end
end
