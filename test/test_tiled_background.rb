# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Tiled backgrounds (`tiles` + `background`): draw a level out of a small set of
# reusable tile images stamped onto a grid by a character map. This is the
# hide-the-hardware surface — the dev writes tiles and a map, never charblocks or
# background-control registers. These assert the observable result: the right tile
# lands in the right grid cell, on the interpreter and on real hardware.
#
# (This is the surface + static rendering; the hardware tile-mode lowering that
# makes it efficient and scrollable is the next slice. The user code here does not
# change when that lands.)
class TestTiledBackground < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Reference = RubyGBA::IR::Backends::Reference
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  # A 4x4 solid tile of one color, as ASCII art (small, so the grid math is easy
  # to read: cell (c, r) covers x 4c..4c+3, y 4r..4r+3).
  def solid_tile(builder, name, color)
    builder.image(name, "#" => color) { "####\n####\n####\n####" }
  end

  # Build a 2x2 checker of two tiles and return the finished interpreter run.
  def checker_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
    end
    solid_tile(b, :red_tile, :red)
    solid_tile(b, :blue_tile, :blue)
    b.instance_eval do
      tiles :checker, "R" => :red_tile, "B" => :blue_tile
      background :board, tiles: :checker, map: <<~MAP
        RB
        BR
      MAP
    end
    b.emit_pending_functions
    b.program
  end

  def test_each_tile_lands_in_its_grid_cell
    i = Reference.new.run(checker_program)
    red = Color.resolve(:red)
    blue = Color.resolve(:blue)
    # 4x4 tiles: cell (0,0)=R, (1,0)=B, (0,1)=B, (1,1)=R.
    assert_equal red,  i.screen.pixel(0, 0), "cell (0,0) is the red tile"
    assert_equal blue, i.screen.pixel(4, 0), "cell (1,0) is the blue tile (one tile over)"
    assert_equal blue, i.screen.pixel(0, 4), "cell (0,1) is the blue tile (one tile down)"
    assert_equal red,  i.screen.pixel(4, 4), "cell (1,1) is the red tile"
  end

  def test_a_blank_map_cell_leaves_the_background_showing
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green # the field behind the tiles
    end
    solid_tile(b, :red_tile, :red)
    b.instance_eval do
      tiles :sparse, "R" => :red_tile
      background :spots, tiles: :sparse, map: ["R ", " R"] # a space = empty cell
    end
    b.emit_pending_functions
    i = Reference.new.run(b.program)
    assert_equal Color.resolve(:red),   i.screen.pixel(0, 0), "cell (0,0) has a tile"
    assert_equal Color.resolve(:green), i.screen.pixel(4, 0), "cell (1,0) is blank — the field shows"
  end

  # --- Guardrail behavior (friendly, non-jargon errors) ---

  def test_an_undefined_tile_image_is_a_friendly_error
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval { tiles :bad, "#" => :nonexistent }
    end
    assert_match(/not a defined image/, err.message)
  end

  def test_a_map_character_not_in_the_tileset_is_a_friendly_error
    b = Builder.new
    solid_tile(b, :red_tile, :red)
    b.instance_eval { tiles :one, "R" => :red_tile }
    err = assert_raises(ArgumentError) do
      b.instance_eval { background :oops, tiles: :one, map: "RX" } # X is unmapped
    end
    assert_match(/not in tileset/, err.message)
  end

  def test_mismatched_tile_sizes_are_a_friendly_error
    b = Builder.new
    solid_tile(b, :small, :red)                                   # 4x4
    b.image(:big, "#" => :blue) { "########\n########" }          # 8x2
    err = assert_raises(ArgumentError) do
      b.instance_eval { tiles :mixed, "s" => :small, "b" => :big }
    end
    assert_match(/same size/, err.message)
  end

  def test_a_ragged_map_is_a_friendly_error
    b = Builder.new
    solid_tile(b, :red_tile, :red)
    b.instance_eval { tiles :one, "R" => :red_tile }
    err = assert_raises(ArgumentError) do
      b.instance_eval { background :ragged, tiles: :one, map: "RRR\nRR" } # rows 3 and 2 wide
    end
    assert_match(/same length/, err.message)
  end

  # In tile mode the console's tile hardware only handles 8x8 tiles, so a tileset
  # of another size gets a friendly build error naming the fix (rather than a black
  # screen). Bitmap mode has no such limit — it stamps any size — so this is only
  # about screen :tiled.
  def test_tiled_mode_requires_8x8_tiles
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :small, :red) # 4x4
    b.instance_eval do
      tiles :set, "R" => :small
      background :bg, tiles: :set, map: "R"
    end
    b.emit_pending_functions
    err = assert_raises(GBA::LoweringError) { GBA.new.lower(b.program) }
    assert_match(/8x8 tiles/, err.message)
  end

  # --- Hardware: the same board renders on the console ---

  def test_the_board_renders_on_the_console
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
    end
    solid_tile(b, :red_tile, :red)
    solid_tile(b, :blue_tile, :blue)
    b.instance_eval do
      tiles :checker, "R" => :red_tile, "B" => :blue_tile
      background :board, tiles: :checker, map: "RB\nBR"
      halt
    end
    b.emit_pending_functions
    rom = ROM.assemble(GBA.new.lower(b.program), title: "TILES", code: "BTIL", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 2)
    assert v.red?(1, 1),  "the red tile renders in cell (0,0)"
    assert v.blue?(5, 1), "the blue tile renders in cell (1,0)"
  end
end
