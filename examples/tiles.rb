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
# (This paints a static room. Scrolling a map bigger than the screen, and stacking
# layers, build on this same surface — the code here won't change when they land.)
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

  # The room, drawn as characters. Read it top-down: a walled room with a pool of
  # water and a patch of grass. Each character becomes its 8x8 tile.
  background :room, tiles: :dungeon, map: <<~MAP
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

    halt # a static scene — nothing moves, so stop here
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Tiles::GAME.write_if_main
