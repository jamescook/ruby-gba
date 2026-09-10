#!/usr/bin/env ruby
# frozen_string_literal: true

# Scroll — pan a camera around a world bigger than the screen with the D-pad.
#
# A tiled background can be larger than the 240x160 screen; you move the visible
# WINDOW over it with `scroll_by` (or `scroll_to`), and the console's background
# hardware does the sliding for free — no redrawing, no scroll registers to touch.
# The world here is 64x64 tiles — 512x512 pixels, more than four screenfuls — so
# there's a lot more world than screen in every direction; scroll far enough and it
# WRAPS, because a background is a torus. That's the groundwork a follow-you camera
# is built on.
#
# 64x64 is the biggest a background gets, and it is bigger than one piece of video
# memory holds — the console reads a map that size as four squares side by side and
# stacked. You would never know: you write the rows you want and the framework picks
# the smallest shape that holds them, laying the cells out where the console expects
# to find them.
#
# What you never touch: the scroll registers, where the map lives in video memory,
# how it is cut up, how wrapping works. You say where the window sits, in pixels,
# and it goes there.
#
# (This pans an empty world — the camera on its own. Put a sprite on top and follow
# it and you have a follow-you camera: see examples/hero.rb.)
#
# Run it to build examples/scroll.gba:
#   ruby examples/scroll.rb

require_relative "../lib/ruby_gba"

module Scroll
  SPEED = 2

  # A 64x64 world: grass, two lakes well apart, and trees scattered across it — so
  # there's plenty to see slide by, and the two lakes are far enough apart that you
  # have to pan a long way to find the second one.
  SIDE = 64
  LAKES = [[10..14, 12..19], [42..48, 38..50]].freeze

  MAP = (0...SIDE).map do |r|
    (0...SIDE).map do |c|
      if LAKES.any? { |rows, cols| rows.cover?(r) && cols.cover?(c) } then "~"
      elsif ((r * 3) + (c * 5)) % 11 == 0                             then "T" # scattered trees
      else "."                                                                 # grass
      end
    end.join
  end.freeze

  GAME = RubyGBA.game("SCROLL", code: "BSCR", maker: "01") do
    screen :tiled # tile mode: one big background layer we slide the window over

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

    game_loop do
      # Hold a direction to pan the camera that way; the world slides under it.
      held(:left).then  { world.scroll_by(-SPEED, 0) }
      held(:right).then { world.scroll_by(SPEED, 0) }
      held(:up).then    { world.scroll_by(0, -SPEED) }
      held(:down).then  { world.scroll_by(0, SPEED) }
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Scroll::GAME.write_if_main
