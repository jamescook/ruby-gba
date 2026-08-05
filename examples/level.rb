#!/usr/bin/env ruby
# frozen_string_literal: true

# Level — draw a level you designed in a map editor, not typed into the code.
#
# examples/sheet.rb builds its room from an inline text grid (the ROOM array). That's
# lovely for a small room, but real levels are drawn in an editor like Tiled and
# exported — a big grid of tile numbers in a .csv file. You import that file directly:
#
#   tiles :world, from: "tiles.png", tile: 8          # import the WHOLE sheet, tiles numbered 1, 2, …
#   background :room, tiles: :world, from: "level.csv" # the editor's export IS the map
#
# `tiles from:` with no characters cuts the sheet into numbered tiles — 1, 2, 3…
# left-to-right, the exact numbering an editor writes into its CSV (a 0 there means an
# empty cell). `background from:` reads that CSV and stamps each number's tile. So the
# map lives in a file an artist can edit, and nothing here mentions palettes, VRAM, or
# how the console stores a tile map — importing handles all of that. The sheet's first
# tile (number 1) is a brick; solid: [1] makes it a wall the hero can't cross.
#
# The art and the map are found next to this script, in assets/ (drawn/written by
# tools/make_example_assets.rb). Run it to build examples/level.gba:
#   ruby examples/level.rb

require_relative "../lib/ruby_gba"

module Level
  SPEED = 2

  TILES = "assets/tiles.png" # a 2-cell tile sheet (brick is tile 1, floor is tile 2)
  HERO  = "assets/hero.png"  # a 4-frame walk-cycle sprite sheet
  MAP   = "assets/level.csv" # a 30x20 tilemap exported as CSV (1 = brick, 2 = floor)

  GAME = RubyGBA.game("LEVEL", code: "BLVL", maker: "01") do
    screen :tiled # tile mode: a background room + a hardware sprite over it

    # Import the whole tile sheet as numbered tiles, then read the CSV level straight
    # in. solid: [1] marks the brick (tile 1) as a wall.
    tiles :world, from: TILES, tile: 8, solid: [1]
    room = background :room, tiles: :world, from: MAP

    # The same imported, animated, cut-out hero as sheet.rb — kept out of the walls.
    hero = sprite :hero, at: [16, 16], frames_from: HERO, tile: 16, rate: 8, transparent: true
    hero.blocked_by room

    game_loop do
      held(:left).then  { hero.move :left,  by: SPEED }
      held(:right).then { hero.move :right, by: SPEED }
      held(:up).then    { hero.move :up,    by: SPEED }
      held(:down).then  { hero.move :down,  by: SPEED }
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Level::GAME.write_if_main
