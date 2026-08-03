#!/usr/bin/env ruby
# frozen_string_literal: true

# Sheet — bring your art in from PNG files instead of typing it out.
#
# Small pictures are lovely to draw right in the code (see maze.rb's ASCII tiles),
# but real games keep their art in image files drawn in a proper tool. You import
# right where you use the art, with no in-between step:
#
#   tiles :dungeon, from: "tiles.png", tile: 8, "#" => 0, "." => 1   # the map-character IS the tile
#   sprite :hero, at: [x, y], frames_from: "hero.png", tile: 16, rate: 8, transparent: true
#
# `tiles from:` cuts the tile sheet into 8x8 tiles and lets each map character point
# at one (a cell number, counting left-to-right). `sprite frames_from:` cuts the
# sprite sheet into 16x16 frames and cycles them as a walk animation — nothing to
# name or number. Image paths are found next to this script (the two PNGs live in
# assets/, drawn by tools/make_example_assets.rb). Nothing here mentions palettes,
# VRAM, or how the console stores color — importing handles all of that.
#
# Run it to build examples/sheet.gba:
#   ruby examples/sheet.rb

require_relative "../lib/ruby_gba"

module Sheet
  SPEED = 2

  # The art files, imported at build time — found next to this script.
  TILES = "assets/tiles.png" # a 2-cell tile sheet (brick, then floor)
  HERO  = "assets/hero.png"  # a 4-frame walk-cycle sprite sheet

  # A 30x20-tile room (the whole 240x160 screen): a wall border around open floor
  # with a few pillars. "#" is a wall, "." is floor.
  ROOM = [
    "##############################",
    "#............................#",
    "#............................#",
    "#......####........####......#",
    "#......####........####......#",
    "#............................#",
    "#............................#",
    "#............................#",
    "#............####............#",
    "#............####............#",
    "#............####............#",
    "#............................#",
    "#............................#",
    "#......####........####......#",
    "#......####........####......#",
    "#............................#",
    "#............................#",
    "#............................#",
    "#............................#",
    "##############################",
  ].freeze

  GAME = RubyGBA.game("SHEET", code: "BSHT", maker: "01") do
    screen :tiled # tile mode: a background room + a hardware sprite over it

    # Import the tile sheet straight into the tileset: "#" is its first tile (the
    # brick), "." its second (the floor). solid: makes the brick a wall.
    tiles :dungeon, from: TILES, tile: 8, "#" => 0, "." => 1, solid: ["#"]
    room = background :room, tiles: :dungeon, map: ROOM

    # Import the sprite sheet's four 16x16 frames and cycle them into a walk animation
    # (one every 8 frames). transparent: true honors the cut-out background so only
    # the figure draws, not a box; blocked_by keeps the hero out of the walls.
    hero = sprite :hero, at: [16, 16], frames_from: HERO, tile: 16, rate: 8, transparent: true
    hero.blocked_by room

    game_loop do
      wait_vblank # the safe moment to move the hero

      held(:left).then  { hero.move :left,  by: SPEED }
      held(:right).then { hero.move :right, by: SPEED }
      held(:up).then    { hero.move :up,    by: SPEED }
      held(:down).then  { hero.move :down,  by: SPEED }
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Sheet::GAME.write_if_main
