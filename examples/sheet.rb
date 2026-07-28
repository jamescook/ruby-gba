#!/usr/bin/env ruby
# frozen_string_literal: true

# Sheet — bring your art in from PNG files instead of typing it out.
#
# Small pictures are lovely to draw right in the code (see maze.rb's ASCII tiles),
# but real games keep their art in image files drawn in a proper tool. `sheet` pulls
# many pictures out of ONE image at once — a tile sheet, or a sprite sheet of
# animation frames — and names each cell. Every named cell becomes an ordinary
# image, so it drops straight into `tiles`, `sprite`, or `blit`: an imported tile
# and a hand-drawn one are the same thing at the point you use them.
#
#   sheet TILES, tile: 8,  as: { brick: [0, 0], floor: [1, 0] }
#   sheet HERO,  tile: 16, as: { walk1: 0, walk2: 1, walk3: 2, walk4: 3 }, transparent: true
#
# The two PNGs live next to this file in assets/ (regenerate them with
# tools/make_example_assets.rb). The tile sheet paints the room; the sprite sheet's
# four frames animate the hero as it walks. Nothing here mentions palettes, VRAM, or
# how the console stores color — importing handles all of that.
#
# Run it to build examples/sheet.gba:
#   ruby examples/sheet.rb

require_relative "../lib/ruby_gba"

module Sheet
  SPEED = 2

  # The art files, imported at build time.
  TILES = File.join(__dir__, "assets", "tiles.png") # a 2-cell tile sheet (brick, floor)
  HERO  = File.join(__dir__, "assets", "hero.png")  # a 4-frame walk-cycle sprite sheet

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

  GAME = proc do
    screen :tiled # tile mode: a background room + a hardware sprite over it

    # Import the tile sheet: cell [0,0] is the brick, cell [1,0] the floor. Each cell
    # becomes an image, exactly as if it had been drawn inline.
    sheet TILES, tile: 8, as: { brick: [0, 0], floor: [1, 0] }
    tiles :dungeon, "#" => :brick, "." => :floor, solid: ["#"]
    room = background :room, tiles: :dungeon, map: ROOM

    # Import the sprite sheet: four 16x16 walk frames, addressed by their cell number
    # (0..3, left to right). transparent: true honors the cut-out background so only
    # the figure draws, not a box around it.
    sheet HERO, tile: 16, as: { walk1: 0, walk2: 1, walk3: 2, walk4: 3 }, transparent: true

    # frames: cycles those four pictures into a walk animation (one every 8 frames);
    # blocked_by keeps the hero out of the walls.
    hero = sprite :hero, at: [16, 16], frames: %i[walk1 walk2 walk3 walk4], rate: 8
    hero.blocked_by room

    game_loop do
      wait_vblank # the safe moment to move the hero

      held(:left).then  { hero.move :left,  by: SPEED }
      held(:right).then { hero.move :right, by: SPEED }
      held(:up).then    { hero.move :up,    by: SPEED }
      held(:down).then  { hero.move :down,  by: SPEED }
    end
  end

  def self.build_rom(out: $stdout, err: $stderr)
    RubyGBA.build("SHEET", code: "BSHT", maker: "01", out: out, err: err, &GAME)
  end

  def self.program
    builder = RubyGBA::Builder.new
    builder.instance_eval(&GAME)
    builder.emit_pending_functions
    builder.program
  end
end

if __FILE__ == $PROGRAM_NAME
  rom = Sheet.build_rom
  output = File.join(__dir__, "sheet.gba")
  rom.write(output)
  puts "Built sheet.gba (#{rom.size} bytes)"
end
