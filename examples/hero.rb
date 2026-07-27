#!/usr/bin/env ruby
# frozen_string_literal: true

# Hero — walk a little character around a tiled room with the d-pad.
#
# This is what most console games are: a SPRITE (a moving character) on top of a
# tiled BACKGROUND (the scenery). You draw the room out of tiles, draw the hero as
# one small picture, and then just move the hero — hold a direction and it walks.
#
# Notice you never draw the hero yourself and never clear the screen. On a tiled
# screen a sprite is drawn by the console's own sprite hardware: it's composited
# over the room every frame, so it leaves no trail and moving it is nothing more
# than changing its position. Its see-through pixels let the floor show around it.
# The exact same `sprite` handle works on a `screen :bitmap` too (there it's drawn
# in software) — so this code reads the same either way.
#
# What you never touch: object memory, tile numbers, palettes, the sprite table.
# A tile is an `image`, the room is a `background`, and the hero is a `sprite`.
#
# Run it to build examples/hero.gba:
#   ruby examples/hero.rb

require_relative "../lib/ruby_gba"

module Hero
  # A bordered room that fills the screen: a wall around the edge, floor inside.
  # 30x20 tiles of 8x8 = 240x160, the whole screen.
  ROOM = (["#" * 30] + Array.new(18, "##{'.' * 28}#") + ["#" * 30]).freeze

  GAME = proc do
    screen :tiled # tile mode: a background layer for the room + hardware sprites on top

    # Two 8x8 tiles for the room — a stone wall and a floor. A second character in
    # each adds a little texture so a wall of them doesn't look flat.
    image :wall, "#" => :gray, "." => rgb(9, 9, 9) do
      <<~ART
        ########
        #......#
        ########
        ...####.
        ########
        .####...
        ########
        #......#
      ART
    end

    image :floor, "." => rgb(4, 4, 7), "o" => rgb(8, 8, 11) do
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

    tiles :dungeon, "#" => :wall, "." => :floor
    background :room, tiles: :dungeon, map: ROOM

    # The hero: a little round face. Its corners are see-through, so the floor shows
    # around it instead of a square; the eyes are a second color.
    image :guy, "." => :transparent, "#" => :red, "o" => :white do
      <<~ART
        ..####..
        .######.
        ##o##o##
        ########
        ########
        ########
        .######.
        ..####..
      ART
    end

    hero = sprite :guy, at: [116, 76] # start near the middle of the room

    game_loop do
      wait_vblank # the safe moment to change the screen — the framework draws the hero here

      # Hold a direction to walk. `move` turns the direction into position math;
      # `by:` is the speed. No draw call — the console repaints the hero for you.
      held(:left).then  { hero.move :left,  by: 2 }
      held(:right).then { hero.move :right, by: 2 }
      held(:up).then    { hero.move :up,    by: 2 }
      held(:down).then  { hero.move :down,  by: 2 }

      # Keep the hero inside the walls (the room's floor spans 8..224 across, 8..144 down).
      hero.x.clamp 8, 224
      hero.y.clamp 8, 144
    end
  end

  def self.build_rom(out: $stdout, err: $stderr)
    RubyGBA.build("HERO", code: "BHRO", maker: "01", out: out, err: err, &GAME)
  end

  # The IR program (no ROM, no emulator) — the headless form tests read pixels from.
  def self.program
    builder = RubyGBA::Builder.new
    builder.instance_eval(&GAME)
    builder.emit_pending_functions
    builder.program
  end
end

if __FILE__ == $PROGRAM_NAME
  rom = Hero.build_rom
  output = File.join(__dir__, "hero.gba")
  rom.write(output)
  puts "Built hero.gba (#{rom.size} bytes)"
end
