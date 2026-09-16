# frozen_string_literal: true

require "test_helper"
require_relative "../../../tools/make_example_assets" # colors of the imported tile sheet

# A map the BUILD computes rather than a person types. There are three ways a game
# gets a level — somebody types it as characters, an editor exports it as a CSV of
# numbers, or the build works it out — and only the first two had a spelling. A
# generated map had to be squeezed through one of them: written as characters, which
# caps a screenful at however many distinct characters a person will read, or written
# out to a CSV file on disk and read straight back in.
#
# So a `map:` row may be an Array as well as a String, and its cells are whatever the
# tileset is keyed by — which need not be one character. That is the same verb, the
# same argument and the same tileset; only the two rules change. `nil` is the blank
# cell in an Array row, which is what a space is in a String row.
class TestComputedTilemap < Minitest::Test
  Assets = MakeExampleAssets

  SHEET = File.expand_path("../../../examples/assets/tiles.png", __dir__) # brick = tile 1, floor = tile 2

  # A 4x4 solid tile of one colour, so the grid arithmetic reads easily: cell (c, r)
  # covers x 4c..4c+3, y 4r..4r+3.
  def solid_tile(builder, name, color)
    builder.image(name, "#" => color) { "####\n####\n####\n####" }
  end

  # A tileset keyed by NUMBERS rather than characters — what a decoder hands over,
  # since the tile it read is a number and was never a character at all.
  def numbered_tileset(builder)
    solid_tile(builder, :tile_red, :red)
    solid_tile(builder, :tile_blue, :blue)
    builder.instance_eval { tiles :room, 0 => :tile_red, 1 => :tile_blue }
  end

  def checker_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
    end
    numbered_tileset(b)
    b.instance_eval do
      background :board, tiles: :room, map: [[0, 1],
                                             [1, 0]]
    end
    b.emit_pending_functions
    b.program
  end

  def test_a_row_of_tileset_keys_stamps_the_same_tiles_a_row_of_characters_would
    i = Reference.new.run(checker_program)
    red = Color.resolve(:red)
    blue = Color.resolve(:blue)
    assert_equal red,  i.screen.pixel(0, 0), "cell (0,0) is tile 0"
    assert_equal blue, i.screen.pixel(4, 0), "cell (1,0) is tile 1, one tile over"
    assert_equal blue, i.screen.pixel(0, 4), "cell (0,1) is tile 1, one tile down"
    assert_equal red,  i.screen.pixel(4, 4), "cell (1,1) is tile 0"
  end

  def test_nil_is_the_blank_cell_in_a_row_of_keys
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :green # the field behind the tiles
    end
    numbered_tileset(b)
    b.instance_eval do
      background :spots, tiles: :room, map: [[0, nil],
                                             [nil, 0]]
    end
    b.emit_pending_functions
    i = Reference.new.run(b.program)
    assert_equal Color.resolve(:red),   i.screen.pixel(0, 0), "cell (0,0) has a tile"
    assert_equal Color.resolve(:green), i.screen.pixel(4, 0), "cell (1,0) is blank — the field shows"
  end

  # The point of the whole thing: a screenful of tiles a person could not have typed,
  # because there are more of them than there are characters worth reading. 100 tiles
  # is already over the printable-ASCII ceiling of 94.
  def test_a_map_can_use_more_tiles_than_there_are_characters_to_type
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
    end
    100.times { |n| solid_tile(b, :"tile_#{n}", RubyGBA::Graphics::Color.rgb(n % 32, 0, 0)) }
    keyed = (0...100).to_h { |n| [n, :"tile_#{n}"] }
    b.instance_eval do
      tiles :many, keyed
      background :field, tiles: :many, map: (0...10).map { |r| (0...10).map { |c| (r * 10) + c } }
    end
    b.emit_pending_functions
    i = Reference.new.run(b.program)
    assert_equal RubyGBA::Graphics::Color.rgb(0, 0, 0),  i.screen.pixel(0, 0),   "cell (0,0) is tile 0"
    assert_equal RubyGBA::Graphics::Color.rgb(99 % 32, 0, 0), i.screen.pixel(36, 36),
                 "cell (9,9) is tile 99 — a tile no character could have selected"
  end

  # Several maps taking turns in one grid, each written as a grid of keys.
  def test_several_computed_maps_can_take_turns
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
    end
    numbered_tileset(b)
    b.instance_eval do
      background :rooms, tiles: :room, map: { hall: [[0, 0]], cave: [[1, 1]] }
    end
    b.emit_pending_functions
    i = Reference.new.run(b.program)
    assert_equal Color.resolve(:red), i.screen.pixel(0, 0), "the first map is the one showing at boot"
  end

  # ART IMPORTED FROM A SHEET, LEVEL WORKED OUT BY THE BUILD — the combination that
  # had no spelling at all. A tileset imported whole is keyed by the tile numbers the
  # sheet was sliced into, so a grid of those numbers selects its tiles with no CSV
  # file in between.
  def test_a_grid_of_numbers_draws_a_sheet_tileset_with_no_csv_file
    b = Builder.new
    b.instance_eval do
      screen :tiled
      tiles :world, from: SHEET, tile: 8 # no characters: cell 0 -> tile 1, cell 1 -> tile 2
      background :room, tiles: :world, map: [[1, 2]]
    end
    b.emit_pending_functions
    s = Reference.new.run(b.program).screen
    assert_equal Assets::BRICK, s.pixel(0, 3), "tile 1 is the sheet's first cell"
    assert_equal Assets::FLOOR, s.pixel(8, 3), "tile 2 is the sheet's second cell"
  end

  # The one combination with no answer: characters over a tileset that has none. The
  # error now names both ways out, since a grid of numbers is one of them.
  def test_a_character_map_on_a_numbered_tileset_still_says_how_to_write_it
    b = Builder.new
    b.instance_eval { screen :tiled }
    b.instance_eval { tiles :world, from: SHEET, tile: 8 }
    err = assert_raises(ArgumentError) { b.background(:room, tiles: :world, map: "12") }
    assert_match(/imported as numbered tiles/, err.message)
    assert_match(/rows of its tile numbers/, err.message)
  end

  # `solid:` says which TILES block, and it never said how they were named — so it
  # takes the tileset's keys whatever they are, with nothing new to write. Worth
  # asserting rather than assuming: a wall that quietly stops blocking is a game you
  # can walk out of, and nothing on screen says so.
  def test_a_computed_map_still_stops_a_mover_at_its_solid_tiles
    b = Builder.new
    solid8 = (["########"] * 8).join("\n")
    b.instance_eval do
      screen :tiled
      image(:t_wall,  "#" => :blue) { solid8 }
      image(:t_floor, "#" => rgb(8, 8, 8)) { solid8 }
      image(:t_hero,  "#" => :red) { solid8 }
      tiles :dungeon, 0 => :t_floor, 1 => :t_wall, solid: [1]
      # A 10x5-tile room with one wall at cell (4, 2) — px (32, 16). Worked out, not typed.
      room = background :room, tiles: :dungeon,
                               map: Array.new(5) { |r| (0...10).map { |c| r == 2 && c == 4 ? 1 : 0 } }
      hero = sprite :t_hero, at: [16, 16]
      hero.blocked_by room
      game_loop do
        wait_vblank
        held(:right).then { hero.move :right, by: 2 }
      end
    end
    b.emit_pending_functions
    s = Reference.new.input_each_frame { [:right] }.run(b.program, max_steps: 3_000).screen
    assert_equal Color.resolve(:red),  s.pixel(28, 20), "the hero rests flush against the wall"
    refute_equal Color.resolve(:red),  s.pixel(36, 20), "the hero never entered the wall cell"
  end

  # --- Friendly errors ---

  def test_a_key_the_tileset_does_not_have_is_a_friendly_error
    b = Builder.new
    numbered_tileset(b)
    err = assert_raises(ArgumentError) do
      b.instance_eval { background :oops, tiles: :room, map: [[0, 7]] }
    end
    assert_match(/not in tileset/, err.message)
    assert_match(/7/, err.message, "the error names the key that is not there")
  end

  # A tileset written out by hand has a handful of keys and the error names them all.
  # One a computed level draws on can have hundreds, and listing those buries the one
  # fact the reader came for.
  def test_a_big_tilesets_error_says_how_many_tiles_it_has_rather_than_naming_them_all
    b = Builder.new
    100.times { |n| solid_tile(b, :"tile_#{n}", RubyGBA::Graphics::Color.rgb(n % 32, 0, 0)) }
    keyed = (0...100).to_h { |n| [n, :"tile_#{n}"] }
    b.instance_eval { tiles :many, keyed }
    err = assert_raises(ArgumentError) do
      b.instance_eval { background :oops, tiles: :many, map: [[500]] }
    end
    assert_match(/500 is not in tileset :many/, err.message)
    assert_match(/has 100 tiles/, err.message)
    refute_match(/\b50\b/, err.message, "it does not read out every key it has")
  end

  def test_a_ragged_grid_of_keys_is_a_friendly_error
    b = Builder.new
    numbered_tileset(b)
    err = assert_raises(ArgumentError) do
      b.instance_eval { background :ragged, tiles: :room, map: [[0, 1, 0], [1, 0]] }
    end
    assert_match(/same length/, err.message)
  end

  # --- Hardware: the same computed board renders on the console ---

  def test_a_computed_board_renders_on_the_console
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
    end
    numbered_tileset(b)
    b.instance_eval do
      background :board, tiles: :room, map: [[0, 1], [1, 0]]
      halt
    end
    b.emit_pending_functions
    rom = ROM.assemble(GBA.new.lower(b.program), title: "COMPUTED", code: "DCMP", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 2)
    assert v.red?(1, 1),  "tile 0 renders in cell (0,0)"
    assert v.blue?(5, 1), "tile 1 renders in cell (1,0)"
  end
end
