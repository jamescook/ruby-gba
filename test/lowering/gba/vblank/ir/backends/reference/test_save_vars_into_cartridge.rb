# frozen_string_literal: true

require "test_helper"
require "all/vblank/ir/backends/reference/test_save_vars_into"

# A save_var's number written into save memory by a test, read back by the Advance's own
# cartridge in the emulator: the console starts from it, on battery memory and on flash. Writing
# the number and what every run's game reads back is in
# test/all/vblank/ir/backends/reference/test_save_vars_into.rb, which keeps the game both files
# play in SaveVarsIntoGames.
class TestSaveVarsIntoCartridge < Minitest::Test
  include SaveVarsIntoGames

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

  def test_the_console_starts_from_a_written_save_var
    assert_equal [[1234, 7], [9999, 7]], console_best
  end

  def test_the_console_starts_from_a_written_save_var_on_flash
    assert_equal [[1234, 7], [9999, 7]], console_best(save_memory: 64)
  end
end
