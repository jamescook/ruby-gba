# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/dsl/test_sprite_draws_with_on_the_advance"

# A sprite drawing with other lists of colours, on the Advance's cartridge: which of the
# console's sixteen groups of sprite colours the ship really wears, read back in the emulator.
# What it draws on every Advance run is in
# test/console/gba/vblank/dsl/test_sprite_draws_with_on_the_advance.rb.
class TestSpriteDrawsWithOnTheAdvanceCartridge < Minitest::Test
  include SpriteDrawsWithOnTheAdvanceGames

  # SIXTEEN IS EXACTLY ENOUGH: the ship's own colours and fifteen lists, one group each, with
  # nothing left over. The first group of the table is one of the sixteen. Its first entry is
  # never drawn, as in every group, so sprites can have it.
  def test_a_sprite_and_fifteen_lists_take_all_sixteen_groups
    console = assert_emulator_loads_rom(assemble_rom(ship_drawn_with_fifteen_lists, name: "SIXTEEN"), frames: 2)
    worn = Array.new(17) do
      console.step
      console.sprites(:ship).first.palette
    end

    assert_equal 16, worn.uniq.size, "the ship wore sixteen different groups"
    assert_equal Color.resolve(:black), console.pixel_gba(120, 120), "the colour behind everything is as it was"
  end
end
