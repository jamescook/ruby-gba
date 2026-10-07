# frozen_string_literal: true

require "test_helper"
require "differential"

# A TILE THAT IS ANOTHER TILE MIRRORED IS STORED ONCE, and the cells that show it say to draw it
# turned round. Nothing in a tileset says which tiles are mirrors of each other — a room's left
# wall is its right wall reversed, a corner is the same corner four ways — and a whole area of a
# real game can come to twice the tiles one layer can name if each is kept as drawn. A map cell
# has a bit for each way round, so the console draws a mirror for nothing.
class TestMirroredTiles < Minitest::Test
  include Differential

  # A tile with one corner marked, so each of its mirrors is a different picture: the mark
  # top-left, top-right, bottom-left and bottom-right.
  CORNER = ["r#######", "########", "########", "########",
            "########", "########", "########", "########"].freeze
  def self.flip_rows(rows, across:, down:)
    rows = rows.map(&:reverse) if across
    down ? rows.reverse : rows
  end

  def self.corner_tiles(builder)
    builder.instance_eval do
      { ul: [false, false], ur: [true, false], dl: [false, true], dr: [true, true] }.each do |name, (across, down)|
        art = TestMirroredTiles.flip_rows(CORNER, across: across, down: down)
        image(name, "#" => :green, "r" => :red) { art.join("\n") }
      end
      tiles :corners, "a" => :ul, "b" => :ur, "c" => :dl, "d" => :dr, "e" => :ul
    end
  end

  def self.corners_program(map: ["abcd", "dcba", "eeee"])
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :tiled
      TestMirroredTiles.corner_tiles(self)
      background :room, tiles: :corners, map: map
      game_loop {}
    end
    b.finalize_program
    b.program
  end

  def build(&block)
    RubyGBA.build("MIRROR", out: StringIO.new, err: StringIO.new, &block)
  end

  def test_each_mirror_draws_the_right_way_round
    assert_backends_agree(self.class.corners_program, frames: 2)
  end

  # A cell changed while the game runs, and a map put up whole, name a mirror the same way the
  # first map did.
  def test_set_tile_and_show_map_draw_a_mirror_the_right_way_round
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :tiled
      TestMirroredTiles.corner_tiles(self)
      room = background :room, tiles: :corners, map: { first: ["aaaa"], second: ["dcba"] }
      frames = var :frames, 0
      game_loop do
        frames.add! 1
        (frames == 1).then { room.show_map :second }
        (frames == 2).then { room.set_tile 0, 0, "b" }
      end
    end
    b.finalize_program
    assert_backends_agree(b.program, frames: 4)
  end

  # +count+ different tiles, each with a red mark in its top-left corner and its own number
  # written in blue along two middle rows, so no two are the same and none is another one
  # mirrored. Then, for the first +mirrored+ of them, the other three ways round. Keyed 1 up.
  def self.numbered_tiles(builder, count, mirrored)
    builder.instance_eval do
      pictures = []
      count.times do |n|
        rows = Array.new(8) { "g" * 8 }
        rows[0] = "r#{'g' * 7}"
        16.times { |bit| rows[3 + (bit / 8)][bit % 8] = "b" if n[bit] == 1 }
        pictures << rows
      end
      mirrored.times do |n|
        [[true, false], [false, true], [true, true]].each do |across, down|
          pictures << TestMirroredTiles.flip_rows(pictures[n], across: across, down: down)
        end
      end
      keys = pictures.each_with_index.to_h do |rows, i|
        image(:"t#{i}", "g" => :green, "r" => :red, "b" => :blue) { rows.join("\n") }
        [i + 1, :"t#{i}"]
      end
      tiles :many, **keys
      keys.size
    end
  end

  def numbered_room(count, mirrored)
    build do
      screen :tiled
      total = TestMirroredTiles.numbered_tiles(self, count, mirrored)
      background :room, tiles: :many, map: (1..total).each_slice(40).to_a
      game_loop {}
    end
  end

  # 1,200 tiles as drawn, which is past what one layer's map can name, and 300 once the
  # mirrors are shared.
  def test_a_layer_that_fits_once_its_mirrors_are_shared_builds
    rom = numbered_room(300, 300)
    assert_equal 900, rom.built.video_memory.tiles.mirrored
  end

  def test_a_layer_still_too_big_says_how_many_mirrors_it_found
    error = assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) { numbered_room(1100, 20) }
    assert_match(/60 of its tiles were another of its tiles mirrored/, error.message)
  end

  def test_a_tile_and_its_mirrors_take_the_memory_of_one
    rom = build do
      screen :tiled
      TestMirroredTiles.corner_tiles(self)
      background :room, tiles: :corners, map: ["abcd"]
      game_loop {}
    end
    tiles = rom.built.video_memory.tiles
    # The blank tile every empty cell points at is 64 bytes; one small tile is 32.
    assert_equal 64 + 32, tiles.used, "one picture kept, three drawn from it turned round"
    assert_equal 3, tiles.mirrored
  end
end
