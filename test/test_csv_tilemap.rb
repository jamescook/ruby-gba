# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/ruby_gba"
require_relative "test_helper"
require_relative "../tools/make_example_assets" # colors of the imported tile sheet

# Importing a CSV tilemap into a background (`background from:`): a level authored in a
# map editor and exported as a grid of tile numbers, rendered without retyping it as a
# character map. These assert the observable result — the right tile lands in the right
# cell — plus the friendly errors a malformed export earns. The rendering itself reuses
# the same `:background` IR node as the character map, so both backends already agree
# (the example test cross-checks the sheet-import path on real hardware); here we drive
# the parsing and the number->tile mapping through the DSL surface.
class TestCsvTilemap < Minitest::Test
  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  Color = RubyGBA::Color
  Assets = MakeExampleAssets

  SHEET = File.expand_path("../examples/assets/tiles.png", __dir__) # brick = tile 1, floor = tile 2

  # A tiny checker tileset of two 4x4 tiles, over a green field. Numbered by the order
  # listed: tile 1 = red, tile 2 = blue.
  def checker_builder
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green
      image(:red_tile,  "#" => :red)  { "####\n####\n####\n####" }
      image(:blue_tile, "#" => :blue) { "####\n####\n####\n####" }
      tiles :checker, "R" => :red_tile, "B" => :blue_tile
    end
    b
  end

  # Write +text+ to a real .csv file for the duration of the block (its path is absolute,
  # so it resolves as-is), then clean it up.
  def with_csv(text)
    Tempfile.create(["tilemap", ".csv"]) do |f|
      f.write(text)
      f.flush
      yield f.path
    end
  end

  # Render a checker background from a CSV and return the interpreter's screen.
  def checker_screen(text)
    b = checker_builder
    with_csv(text) { |path| b.background(:board, tiles: :checker, from: path) }
    b.emit_pending_functions
    Ruby.new.run(b.program).screen
  end

  def test_numbers_pick_the_tile_by_the_order_the_tileset_lists_them
    s = checker_screen("1,2\n2,1\n") # tile 1 = red, tile 2 = blue
    assert_equal Color.resolve(:red),  s.pixel(0, 0), "cell (0,0) is tile 1 (red)"
    assert_equal Color.resolve(:blue), s.pixel(4, 0), "cell (1,0) is tile 2 (blue)"
    assert_equal Color.resolve(:blue), s.pixel(0, 4), "cell (0,1) is tile 2 (blue)"
    assert_equal Color.resolve(:red),  s.pixel(4, 4), "cell (1,1) is tile 1 (red)"
  end

  def test_zero_is_an_empty_cell_and_the_background_shows_through
    s = checker_screen("1,0\n0,1\n")
    assert_equal Color.resolve(:red),   s.pixel(0, 0), "cell (0,0) has tile 1"
    assert_equal Color.resolve(:green), s.pixel(4, 0), "cell (1,0) is 0 — the field shows through"
  end

  def test_blank_lines_and_a_trailing_comma_are_tolerated
    s = checker_screen("1,2,\n\n2,1,\n") # editor exports often end each row with a comma
    assert_equal Color.resolve(:red),  s.pixel(0, 0), "the row parses despite the trailing comma"
    assert_equal Color.resolve(:blue), s.pixel(4, 0)
  end

  def test_an_editors_flip_flags_are_stripped_so_the_tile_still_draws
    flipped = 1 | 0x8000_0000 # a horizontally-flipped tile 1, as an editor encodes it
    s = checker_screen("#{flipped},2\n")
    assert_equal Color.resolve(:red), s.pixel(0, 0), "the flip flag is dropped; tile 1 still draws"
  end

  # --- friendly errors ---

  def test_a_ragged_csv_is_a_friendly_error
    err = assert_raises(ArgumentError) { checker_screen("1,2\n1\n") }
    assert_match(/ragged rows/, err.message)
  end

  def test_a_non_numeric_cell_is_a_friendly_error
    err = assert_raises(ArgumentError) { checker_screen("1,x\n1,1\n") }
    assert_match(/grid of numbers/, err.message)
  end

  def test_a_number_with_no_matching_tile_is_a_friendly_error
    err = assert_raises(ArgumentError) { checker_screen("1,5\n") } # tileset only has tiles 1, 2
    assert_match(/tile number 5/, err.message)
  end

  def test_giving_both_a_map_and_a_from_is_a_friendly_error
    b = checker_builder
    err = assert_raises(ArgumentError) do
      with_csv("1,2\n") { |path| b.background(:board, tiles: :checker, map: "RB", from: path) }
    end
    assert_match(/not both/, err.message)
  end

  def test_giving_neither_a_map_nor_a_from_is_a_friendly_error
    b = checker_builder
    err = assert_raises(ArgumentError) { b.background(:board, tiles: :checker) }
    assert_match(/needs a map:.*or a from:/, err.message)
  end

  # --- importing the whole sheet as numbered tiles (the map-editor workflow) ---

  def test_a_whole_sheet_tileset_numbers_its_cells_for_a_csv_map
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      tiles :world, from: SHEET, tile: 8 # no characters: cell 0 -> tile 1, cell 1 -> tile 2
    end
    with_csv("1,2\n") { |path| b.background(:room, tiles: :world, from: path) }
    b.emit_pending_functions
    s = Ruby.new.run(b.program).screen
    assert_equal Assets::BRICK, s.pixel(0, 3), "CSV tile 1 is the sheet's first cell (brick)"
    assert_equal Assets::FLOOR, s.pixel(8, 3), "CSV tile 2 is the sheet's second cell (floor)"
  end

  def test_solid_tile_numbers_become_walls
    b = Builder.new
    b.instance_eval do
      screen :tiled
      tiles :world, from: SHEET, tile: 8, solid: [1] # tile 1 (brick) is a wall
    end
    bg = with_csv("1,2\n1,2\n") { |path| b.background(:room, tiles: :world, from: path) }
    refute_empty bg.solid_boxes, "the solid tile-number 1 cells become wall boxes"
  end

  def test_a_character_map_on_a_numbered_tileset_is_a_friendly_error
    b = Builder.new
    b.instance_eval { screen :tiled; tiles :world, from: SHEET, tile: 8 }
    err = assert_raises(ArgumentError) { b.background(:room, tiles: :world, map: "12") }
    assert_match(/imported as numbered tiles/, err.message)
  end

  def test_a_solid_number_not_in_the_sheet_is_a_friendly_error
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval { tiles :world, from: SHEET, tile: 8, solid: [9] } # sheet holds tiles 1..2
    end
    assert_match(/not a tile number/, err.message)
  end
end
