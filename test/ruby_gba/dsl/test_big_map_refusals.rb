# frozen_string_literal: true

require "test_helper"

# WHAT A BACKGROUND WITH A MAP BIGGER THAN THE CONSOLE'S GRID CANNOT DO. Such a background
# holds only the cells around the view and copies them in again as the view moves (see
# IR::TileMap.streams?), so changing one cell, turning the layer, or bending its rows would
# each reach cells that are not there.
class TestBigMapRefusals < Minitest::Test
  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  def big_ground(builder)
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :ground, "." => :floor
    end
  end

  def test_one_cell_of_a_big_map_cannot_be_changed
    test = self
    error = assert_raises(ArgumentError) do
      program do
        test.big_ground(self)
        ground = background :ground, tiles: :ground, map: ["." * 80] * 20
        game_loop { ground.set_tile 1, 1, "." }
      end
    end
    assert_includes error.message, "set_tile cannot change"
  end

  def test_a_big_map_cannot_turn
    test = self
    error = assert_raises(ArgumentError) do
      program do
        test.big_ground(self)
        background(:ground, tiles: :ground, map: ["." * 80] * 80).rotate(10)
        game_loop {}
      end
    end
    assert_includes error.message, "must hold its whole map at once"
  end

  def test_the_rows_of_a_big_map_cannot_bend
    test = self
    error = assert_raises(ArgumentError) do
      program do
        test.big_ground(self)
        ground = background :ground, tiles: :ground, map: ["." * 80] * 20
        ground.scroll_each_row { |row| row & 3 }
        game_loop {}
      end
    end
    assert_includes error.message, "a bent row can show cells outside them"
  end

  def test_maps_of_different_sizes_cannot_bend_either
    test = self
    error = assert_raises(ArgumentError) do
      program do
        test.big_ground(self)
        ground = background :ground, tiles: :ground, map: { hut: ["...."] * 4, hall: ["......"] * 6 }
        ground.scroll_each_row { |row| row & 3 }
        game_loop {}
      end
    end
    assert_includes error.message, "not all one size"
  end
end
