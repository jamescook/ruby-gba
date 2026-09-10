#!/usr/bin/env ruby
# frozen_string_literal: true

# Tiles — draw a whole scene out of a handful of little reusable pictures.
#
# Most console games don't draw a level pixel by pixel. They draw it out of TILES:
# small images (here 8x8) stamped onto a grid by a map. You paint four little tiles
# once — a wall, a floor, water, grass — then describe the room as a block of
# characters, and the framework stamps the right tile into every cell. The map even
# reads like the room looks.
#
# Notice what you never touch: where the tile pictures live in video memory, the
# background-control registers, any of the console's tile machinery. A tile is just
# an `image`, a tileset says which character means which tile, and `background`
# paints the grid. That's the whole surface.
#
# A room is not static, either, and it changes at two scales.
#
# ONE CELL AT A TIME: `room.set_tile col, row, "."` is how a door opens, a pot breaks,
# a bomb takes a wall out, or a pushed block moves. Without it every one of those has
# to be a sprite drawn over the scenery, out of a budget a game would rather spend on
# things that move. Here the inner chamber's door opens when you press A and shuts
# when you press B, and it is one line each way, in the map's own characters.
#
# A WHOLE ROOM AT ONCE: give `background` several maps instead of one and
# `room.show_map :cavern` hands it a different one — which is what walking through a
# door is in a game with a lot of rooms. Written a cell at a time the same thing is
# hundreds of `set_tile` calls in one frame, and the screen would show half of each
# room while they went in. LEFT and RIGHT walk between the three rooms here.
#
# Open the door, walk next door and come back, and it is shut again: a map comes back
# exactly as it was drawn. A game that remembers an opened door opens it again on the
# way in, which is where it wants that decision anyway.
#
# Run it to build examples/tiles.gba:
#   ruby examples/tiles.rb

require_relative "../lib/ruby_gba"

module Tiles
  GAME = RubyGBA.game("TILES", code: "BTIL", maker: "01") do
    screen :tiled # tile mode: the console draws the background layer from tiles + a map

  # Four 8x8 tiles, hand-drawn like any other image. A second character in each
  # gives a little texture so a wall of them doesn't look flat.
  image :wall, "#" => :gray, "." => rgb(10, 10, 10) do
    <<~ART
      .######.
      ########
      ########
      ########
      ########
      ########
      ########
      .######.
    ART
  end

  image :floor, "." => rgb(5, 5, 8), "o" => rgb(9, 9, 12) do
    <<~ART
      ........
      ...o....
      ........
      ......o.
      ........
      .o......
      ........
      ....o...
    ART
  end

  image :water, "~" => :blue, "=" => rgb(12, 12, 31) do
    <<~ART
      ~~~~~~~~
      ~~==~~~~
      ~~~~~~~~
      ~~~~~~==
      ==~~~~~~
      ~~~~~~~~
      ~~~==~~~
      ~~~~~~~~
    ART
  end

  image :grass, "," => :green, "'" => rgb(0, 20, 0) do
    <<~ART
      ,,,,,,,,
      ,,',,,,'
      ,,,,,,,,
      ',,,,,,,
      ,,,,',,,
      ,,,,,,,,
      ,,',,,,,
      ,,,,,,',
    ART
  end

  # The tileset: which character in a map means which tile.
  tiles :dungeon, "#" => :wall, "." => :floor, "~" => :water, "," => :grass

  # Three rooms, each drawn as characters. Read the first top-down: a walled room with
  # a pool of water and a patch of grass. Each character becomes its 8x8 tile.
  #
  # They are given as a Hash rather than one map, which is what makes them rooms the
  # game can walk between rather than one picture. The first is the one showing when the
  # game starts, and they must all be the same size, because they take turns in one grid
  # of cells.
  room = background :room, tiles: :dungeon, map: {
    hall: <<~MAP,
      ########################
      #......................#
      #..~~~~~..........,,,..#
      #..~~~~~..........,,,..#
      #..~~~~~..........,,,..#
      #......................#
      #.....##########.......#
      #.....#........#.......#
      #.....#........#.......#
      #.....##########.......#
      #......................#
      #..,,,.................#
      #..,,,.......~~~~~~~...#
      #..,,,.......~~~~~~~...#
      #............~~~~~~~...#
      #......................#
      ########################
    MAP
    cavern: <<~MAP,
      ########################
      ##....................##
      #......................#
      #...~~~~~~~~~~~~~~~~...#
      #..~~~~~~~~~~~~~~~~~~..#
      #..~~~~~~~~~~~~~~~~~~..#
      #...~~~~~~~~~~~~~~~~...#
      #......................#
      #..###..###..###..###..#
      #..###..###..###..###..#
      #......................#
      #...~~~~~~~~~~~~~~~~...#
      #..~~~~~~~~~~~~~~~~~~..#
      #...~~~~~~~~~~~~~~~~...#
      #......................#
      ##....................##
      ########################
    MAP
    meadow: <<~MAP,
      ########################
      #,,,,,,,,,,,,,,,,,,,,,,#
      #,,,,,,,,,,,,,,,,,,,,,,#
      #,,,,,,,,,,,,,,,,,,,,,,#
      #,,,,,,,,,......,,,,,,,#
      #,,,,,,,,........,,,,,,#
      #,,,,,,,..........,,,,,#
      #,,,,,,,....~~~~..,,,,,#
      #,,,,,,,....~~~~..,,,,,#
      #,,,,,,,..........,,,,,#
      #,,,,,,,,........,,,,,,#
      #,,,,,,,,,......,,,,,,,#
      #,,,,,,,,,,,,,,,,,,,,,,#
      #,,,,,,,,,,,,,,,,,,,,,,#
      #,,,,,,,,,,,,,,,,,,,,,,#
      #,,,,,,,,,,,,,,,,,,,,,,#
      ########################
    MAP
  }

    # The inner chamber's doorway: one cell of the wall along its bottom edge. A is the
    # door opening and B is it shutting, each one cell becoming a different tile — the
    # tileset's own characters, at a column and row of the map, with nothing about video
    # memory anywhere in sight.
    door_col = 10
    door_row = 9

    # Which room you are in. `show_map` is given the number rather than a name here,
    # because that is the shape a game with a lot of rooms has: the room number IS the
    # map number, and walking is arithmetic on it.
    where = var :where, 0

    game_loop do
      pressed(:a).then { room.set_tile door_col, door_row, "." }
      pressed(:b).then { room.set_tile door_col, door_row, "#" }

      pressed(:right).then { where.add 1 }
      pressed(:left).then { where.sub 1 }
      where.clamp 0, room.map_count - 1
      room.show_map where
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Tiles::GAME.write_if_main
