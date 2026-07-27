#!/usr/bin/env ruby
# frozen_string_literal: true

# Maze — walk a hero through corridors it can't walk out of.
#
# A tiled room is just scenery until the walls actually stop you. Mark which tiles
# are walls when you define the tileset — `solid: ["#"]` — and tell the hero it's
# `blocked_by` the background, and that's it: the framework checks every step for you.
# Walk into a wall and you simply stop; slide along it and you keep going. No
# collision math, no bounding-box code of your own.
#
# You keep full control when you want it. `hero.can_move?(:left)` asks before moving,
# so you can do something else when you're blocked (turn around, play a bump, open a
# door), and the raw position ops (`move_to`, `x`/`y`) are never checked — an escape
# hatch for teleports.
#
# What you never touch: the collision test, the wall rectangles, the bounding boxes.
# You say which tiles are solid; the hero stops at them.
#
# Run it to build examples/maze.gba:
#   ruby examples/maze.rb

require_relative "../lib/ruby_gba"

module Maze
  SPEED = 2

  # A 30x20-tile room (240x160, the whole screen): a wall border with a grid of thick
  # pillars, leaving wide corridors between them. "#" is a wall, "." is floor.
  ROOM = [
    "##############################",
    "#............................#",
    "#...####....####....####.....#",
    "#...####....####....####.....#",
    "#............................#",
    "#............................#",
    "#...####....####....####.....#",
    "#...####....####....####.....#",
    "#............................#",
    "#............................#",
    "#...####....####....####.....#",
    "#...####....####....####.....#",
    "#............................#",
    "#............................#",
    "#...####....####....####.....#",
    "#...####....####....####.....#",
    "#............................#",
    "#............................#",
    "#............................#",
    "##############################",
  ].freeze

  GAME = proc do
    screen :tiled # tile mode: a background room + a hardware sprite over it

    # Two 8x8 tiles: a brick wall and a dark floor. A little texture in each so a run
    # of them doesn't look flat.
    image :brick, "#" => rgb(20, 10, 8), "." => rgb(26, 14, 11) do
      <<~ART
        ########
        #.#.#.#.
        ########
        .#.#.#.#
        ########
        #.#.#.#.
        ########
        .#.#.#.#
      ART
    end
    image :floor, "." => rgb(2, 2, 5), "o" => rgb(4, 4, 8) do
      <<~ART
        ........
        ..o.....
        ........
        .....o..
        ........
        ...o....
        ........
        ......o.
      ART
    end

    # The wall tiles are solid: a hero blocked_by this room can't move through them.
    tiles :dungeon, "#" => :brick, "." => :floor, solid: ["#"]
    room = background :room, tiles: :dungeon, map: ROOM

    # The hero: a small bright disc, easy to see against the dark floor.
    image :guy, "." => :transparent, "#" => rgb(31, 31, 4), "o" => rgb(31, 20, 0) do
      <<~ART
        ..####..
        .#oooo#.
        #oooooo#
        #oooooo#
        #oooooo#
        #oooooo#
        .#oooo#.
        ..####..
      ART
    end

    hero = sprite :guy, at: [8, 16] # start in the corridor along the left wall
    hero.blocked_by room            # <- walls now stop it, automatically

    game_loop do
      wait_vblank # the safe moment to move the hero

      # Hold a direction to walk. Each `move` is checked against the walls for you, so
      # the hero stops at bricks and slides along them instead of passing through.
      held(:left).then  { hero.move :left,  by: SPEED }
      held(:right).then { hero.move :right, by: SPEED }
      held(:up).then    { hero.move :up,    by: SPEED }
      held(:down).then  { hero.move :down,  by: SPEED }
    end
  end

  def self.build_rom(out: $stdout, err: $stderr)
    RubyGBA.build("MAZE", code: "BMAZ", maker: "01", out: out, err: err, &GAME)
  end

  def self.program
    builder = RubyGBA::Builder.new
    builder.instance_eval(&GAME)
    builder.emit_pending_functions
    builder.program
  end
end

if __FILE__ == $PROGRAM_NAME
  rom = Maze.build_rom
  output = File.join(__dir__, "maze.gba")
  rom.write(output)
  puts "Built maze.gba (#{rom.size} bytes)"
end
