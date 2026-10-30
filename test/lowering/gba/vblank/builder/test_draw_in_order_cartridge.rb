# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_draw_in_order"

# SPRITES DRAWN IN AN ORDER THE GAME WORKS OUT, on the Advance's own cartridge: where the
# console's sprite table keeps each one, read in the emulator. What the order does, asked of
# every run, is in test/all/vblank/builder/test_draw_in_order.rb, which keeps the game both
# files play in DrawInOrderGames.
class TestDrawInOrderCartridge < Minitest::Test
  include DrawInOrderGames

  # The rows of an ordered run move about the console's table, so asking the console for a
  # sprite by name has to follow them.
  def test_the_console_still_knows_which_sprite_is_which
    v = assert_emulator_loads_rom(assemble_rom(two_program(66), name: "ORDER"), frames: 4)

    assert_equal [[68, 66]], v.sprites(:hero).map { |row| [row.x, row.y] }
    assert_equal [ENEMY_AT], v.sprites(:enemy).map { |row| [row.x, row.y] }
    assert_operator v.sprites(:hero).first.slot, :<, v.sprites(:enemy).first.slot, "the hero is in front"
  end
end
