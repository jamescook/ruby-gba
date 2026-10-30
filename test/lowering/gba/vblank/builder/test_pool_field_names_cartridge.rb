# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_pool_field_names"

# What a pool's fields can be called, on the Advance's cartridge: the same numbers read off the
# running cartridge in the emulator. What the games do on every run is in
# test/all/vblank/builder/test_pool_field_names.rb.
class TestPoolFieldNamesCartridge < Minitest::Test
  include PoolFieldNamesGames

  # The variable +name+ on the console, run for as long as the game's run reads it after
  # +frames+ frames.
  private def var_on_console(prog, name, frames: 4)
    rom = assemble_rom(prog)
    assert_emulator_loads_rom(rom, frames: frames + 2, vars: rom.var_addresses).var(name)
  end

  def test_a_field_called_frame_keeps_its_number_on_a_pool_that_animates
    assert_equal 7, var_on_console(frame_field_game, :seen), "the field is the number it was given"
  end

  def test_a_field_called_colors_keeps_its_number_on_a_pool_told_to_draw_with_others
    assert_equal 5, var_on_console(colors_field_game, :seen)
  end

  def test_a_field_can_be_called_anything_the_pool_calls_its_own
    prog = own_words_game

    assert_equal own_words_sum, var_on_console(prog, :sum), "the first and third instance's numbers, as they were written"
    assert_equal 2, var_on_console(prog, :live)
  end

  def test_two_pools_whose_names_and_fields_spell_the_same_words_are_kept_apart
    prog = two_pools_game

    assert_equal 39, var_on_console(prog, :seen)
    assert_equal 40, var_on_console(prog, :long_seen)
  end
end
