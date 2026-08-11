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
# You say it once — `camera_follows hero, across: world` — and from then on the hero
# is an ORDINARY SPRITE you move with `move`, exactly like one in a game that fits on
# a single screen. The framework does the swap: every frame it sees how far the hero
# walked, slides the world by that much, and puts the hero back where it stands. The
# world is a torus, so you can walk forever in any direction and it wraps around.
#
# That the hero stays an ordinary sprite is the part that matters. Written by hand,
# a world bigger than the screen forces you to keep the hero's world position in
# variables of your own — and then the hero is a pair of numbers rather than a
# sprite, so `move` and its automatic facing, walk cycles and poses are all out of
# reach.
#
# What you never touch: object memory, tile numbers, palettes, the sprite table,
# or a single scroll register. A tile is an `image`, the world is a `background`,
# and the hero is a `sprite`.
#
# Its companion, examples/scroll.rb, pans the same kind of world with no hero —
# the camera on its own. This is that camera locked onto a character.
#
# Run it to build examples/hero.gba:
#   ruby examples/hero.rb

require_relative "../lib/ruby_gba"

module Hero
  SPEED = 2 # pixels the hero walks per frame while a direction is held

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

    hero = sprite :guy, at: [0, 0]
    hero.center_on_screen # the middle of the screen, worked out from the hero's own size

    # ...and the camera follows them. From here the hero is an ordinary sprite you move
    # with `move`, and the world slides underneath instead: every frame the framework
    # sees how far they walked, scrolls the world by exactly that, and puts them back.
    camera_follows hero, across: world, at: [120, 80] # standing by a corner of the pond

    game_loop do
      # Hold a direction to walk. This is the same `move` any sprite takes — nothing
      # here knows the world is bigger than the screen. The world is a torus, so there's
      # no edge to bump into: keep going and it wraps.
      held(:left).then  { hero.move :left,  by: SPEED }
      held(:right).then { hero.move :right, by: SPEED }
      held(:up).then    { hero.move :up,    by: SPEED }
      held(:down).then  { hero.move :down,  by: SPEED }
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Hero::GAME.write_if_main
