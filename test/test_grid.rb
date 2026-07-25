# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# grid: a board of equal-sized cells you paint one at a time. The point is that
# the game talks in *cell* coordinates (0, 1, 2 …), never pixels — set_cell and
# clear_cell do the "* cell" arithmetic and the erase-to-background trick that a
# game like Snake otherwise hand-rolls. So the test of correctness is "one cell
# paints exactly its own square, at the right place, in the right color, and
# nothing else moves" — asserted on the interpreter's screen.
class TestGrid < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  def interpret_screen(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    Ruby.new.run(builder.program).screen
  end

  # Assert every pixel of a w-by-h region is one color.
  def assert_region_is(screen, x, y, w, h, color)
    want = Color.resolve(color)
    h.times do |dy|
      w.times { |dx| assert_equal want, screen.pixel(x + dx, y + dy), "(#{x + dx},#{y + dy}) not #{color}" }
    end
  end

  # ---- one cell paints exactly its own square, in cell coordinates ----

  def test_set_cell_paints_one_cell_at_its_pixel_position
    # Cell (3, 2) on an 8px grid is the 8x8 square whose top-left is (24, 16).
    # Note there is no "* 8" anywhere in the program — that's grid's whole job.
    scr = interpret_screen do
      screen :bitmap
      board = grid :board, cols: 30, rows: 20, cell: 8, over: :black
      board.set_cell 3, 2, :white
    end

    assert_region_is scr, 24, 16, 8, 8, :white
    # the neighbor cell to the right is untouched — still the background
    assert_equal Color.resolve(:black), scr.pixel(32, 16)
  end

  def test_clear_cell_fills_the_background_and_leaves_neighbors_alone
    scr = interpret_screen do
      screen :bitmap
      board = grid :board, cols: 30, rows: 20, cell: 8, over: :blue
      board.set_cell 3, 2, :white   # paint two adjacent cells
      board.set_cell 4, 2, :white
      board.clear_cell 3, 2         # then vacate the left one
    end

    assert_region_is scr, 24, 16, 8, 8, :blue   # cleared back to `over`
    assert_region_is scr, 32, 16, 8, 8, :white  # its neighbor is untouched
  end

  def test_cell_coordinates_can_be_runtime_variables
    # A cell coordinate held in a variable (a moving piece) is scaled the same way.
    scr = interpret_screen do
      screen :bitmap
      grid(:board, cols: 30, rows: 20, cell: 8, over: :black).tap do |board|
        cx = var :cx, 1
        board.set_cell cx, 0, :red     # (1, 0) -> the 8x8 square at (8, 0)
      end
    end

    assert_region_is scr, 8, 0, 8, 8, :red
    assert_equal Color.resolve(:black), scr.pixel(0, 0) # cell (0,0) still empty
  end

  # ---- misuse is a friendly, plain-language error, not a silent bad write ----

  def test_a_literal_cell_outside_the_board_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      interpret_screen do
        screen :bitmap
        board = grid :board, cols: 30, rows: 20, cell: 8, over: :black
        board.set_cell 30, 0, :white   # columns are 0..29; 30 is off the board
      end
    end
    assert_match(/col/, err.message)
    assert_match(/0..29/, err.message)
  end

  def test_an_odd_cell_size_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      interpret_screen do
        screen :bitmap
        grid :board, cols: 10, rows: 10, cell: 7, over: :black # odd cell can't fast-fill
      end
    end
    assert_match(/even/, err.message)
  end

  def test_a_board_bigger_than_the_screen_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      interpret_screen do
        screen :bitmap
        grid :board, cols: 40, rows: 20, cell: 8, over: :black # 40*8 = 320px > 240
      end
    end
    assert_match(/320px wide/, err.message)
    assert_match(/240px/, err.message)
  end

  # ---- cross-backend: the same board renders on the console ----

  def grid_rom
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      board = grid :board, cols: 30, rows: 20, cell: 8, over: :black
      board.set_cell 3, 2, :white   # the 8x8 square at (24, 16)
      halt
    end
    builder.emit_pending_functions
    ROM.assemble(GBA.new.lower(builder.program), title: "GRIDTEST", code: "BGRD", maker: "01")
  end

  def test_grid_lowers_to_a_valid_rom
    assert grid_rom.size.positive?
  end

  # ---- hardware: the same cell paints on the console ----

  def test_a_cell_renders_white_on_gemba
    v = assert_gemba_loads_rom(grid_rom, frames: 2)
    assert v.white?(28, 20), "cell (3,2) not white on hardware — got #{v.pixel_gba(28, 20).to_s(16)}"
    assert v.black?(4, 4), "an unpainted cell should stay the background"
  end
end
