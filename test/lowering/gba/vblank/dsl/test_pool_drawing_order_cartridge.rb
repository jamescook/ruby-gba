# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_pool_drawing_order"

# Which of two overlapping things in one pool is in front, on the Advance's cartridge: the
# crowds of test/all/vblank/dsl/test_pool_drawing_order.rb, read in the emulator.
class TestPoolDrawingOrderCartridge < Minitest::Test
  include PoolDrawingOrderGames

  # The colour name at (x, y) on the console once the script has played out, or the pixel's
  # number where no colour names it.
  private def console_color_at(prog, x, y)
    rom = ROM.assemble(GBA.new.lower(prog), title: "PDRW")
    v = assert_emulator_loads_rom(rom, frames: 14)
    COLORS.find { |color| v.pixel_is?(x, y, color) } || v.pixel_gba(x, y)
  end

  def test_the_first_spawned_is_in_front_on_the_console
    prog = first_spawned_crowd

    assert_equal :red, console_color_at(prog, 45, 45), "where both lie, the older one shows"
    assert_equal :green, console_color_at(prog, 50, 50), "and the newer one is drawn behind it"
  end

  def test_a_thing_spawned_into_a_freed_slot_is_still_behind_an_older_one_on_the_console
    prog = freed_slot_crowd

    assert_equal :red, console_color_at(prog, 45, 45), "the older one is in front, whatever slot the newer took"
    assert_equal :green, console_color_at(prog, 50, 50)
  end

  def test_three_overlapping_things_stack_oldest_in_front_on_the_console
    prog = three_deep_crowd

    assert_equal :green, console_color_at(prog, 45, 45), "all three lie here: the oldest shows"
    assert_equal :red, console_color_at(prog, 49, 49), "past the oldest, the second shows over the third"
    assert_equal :blue, console_color_at(prog, 51, 51), "and the newest shows only where it lies alone"
  end

  def test_a_recycled_thing_goes_behind_the_ones_that_were_already_there_on_the_console
    prog = recycled_crowd

    assert_equal :red, console_color_at(prog, 45, 45)
    assert_equal :green, console_color_at(prog, 50, 50)
  end

  def test_removing_the_front_one_shows_the_one_behind_on_the_console
    prog = front_removed_crowd

    assert_equal :green, console_color_at(prog, 45, 45)
    assert_equal 0, console_color_at(prog, 41, 41), "nothing is left where only the removed one was"
  end
end
