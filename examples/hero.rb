#!/usr/bin/env ruby
# frozen_string_literal: true

# Hero — walk a character through a world bigger than the screen, with the camera
# following along.
#
# This is the follow-you camera almost every adventure game uses: the hero stays
# planted in the middle of the screen, and when you walk, the WORLD slides past
# underneath. That's two things you've seen on their own — a SPRITE (the hero) and
# a scrolling BACKGROUND (the world) — working together. The console draws the
# hero on top of the moving scenery for free, so the hero never smears and the
# scenery never tears.
#
# The trick is a tiny bit of bookkeeping: we remember where the hero is in the
# WORLD (which can be far bigger than the screen), keep the hero's picture pinned
# to the screen's center, and each frame point the camera at the hero — so the
# window onto the world is always centered on them. The world is a torus, so you
# can walk forever in any direction and it simply wraps around.
#
# What you never touch: object memory, tile numbers, palettes, the sprite table,
# or a single scroll register. A tile is an `image`, the world is a `background`,
# the hero is a `sprite`, and "follow the hero" is one `scroll_to` a frame.
#
# Its companion, examples/scroll.rb, pans the same kind of world with no hero —
# the camera on its own. This is that camera locked onto a character.
#
# Run it to build examples/hero.gba:
#   ruby examples/hero.rb

require_relative "../lib/ruby_gba"

module Hero
  SPEED = 2 # pixels the hero walks per frame while a direction is held

  # An 8x8 sprite sits centered on the 240x160 screen when its top-left is here.
  CENTER_X = 116
  CENTER_Y = 76

  # A pond of water tiles, a few cells across, dropped into the grass as a landmark
  # you can watch slide by as you walk (and walk back around to, since the world wraps).
  POND_COLS = (10..12)
  POND_ROWS = (10..11)

  # A 32x32 world (256x256 pixels — far bigger than the screen): grass, the pond, and
  # trees scattered across it so there's plenty of scenery moving past as you walk.
  MAP = (0...32).map do |r|
    (0...32).map do |c|
      if POND_ROWS.cover?(r) && POND_COLS.cover?(c) then "~" # the pond
      elsif ((r * 3) + (c * 5)) % 11 == 0            then "T" # scattered trees
      else "."                                              # grass
      end
    end.join
  end.freeze

  GAME = RubyGBA.game("HERO", code: "BHRO", maker: "01") do
    screen :tiled # tile mode: a scrolling background for the world + a hardware sprite on top

    image :grass, "." => rgb(3, 18, 5), "'" => rgb(5, 24, 7) do
      <<~ART
        ........
        ..'.....
        ........
        .....'..
        ........
        ...'....
        ........
        ......'.
      ART
    end
    image :tree, "^" => rgb(0, 26, 0), "|" => rgb(12, 7, 2), "." => rgb(3, 18, 5) do
      <<~ART
        ...^^...
        ..^^^^..
        .^^^^^^.
        ^^^^^^^^
        ..^^^^..
        ...||...
        ...||...
        ..|||...
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

    tiles :terrain, "." => :grass, "T" => :tree, "~" => :water
    world = background :world, tiles: :terrain, map: MAP

    # The hero: a little round face, its corners see-through so the grass shows around
    # it, its eyes a second color. It's pinned to the center of the screen and never
    # moves from there — the world moves instead.
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

    sprite :guy, at: [CENTER_X, CENTER_Y]

    # Where the hero stands in the WORLD (not on the screen). We start them near a
    # corner of the pond and move THIS as you press the d-pad; the sprite itself stays
    # put in the center.
    hero_x = var :hero_x, 120
    hero_y = var :hero_y, 80

    game_loop do
      wait_vblank # the safe moment to move the camera, so the whole view shifts together

      # Hold a direction to walk. We move the hero's world position; the world is a
      # torus, so there's no edge to bump into — keep going and it wraps.
      held(:left).then  { hero_x.sub SPEED }
      held(:right).then { hero_x.add SPEED }
      held(:up).then    { hero_y.sub SPEED }
      held(:down).then  { hero_y.add SPEED }

      # Point the camera at the hero: put the window's top-left where the hero is,
      # backed off by half the screen, so the hero lands dead center. That one line is
      # the whole follow-cam — the console slides the world and composites the hero
      # over it.
      world.scroll_to hero_x - CENTER_X, hero_y - CENTER_Y
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Hero::GAME.write_if_main
