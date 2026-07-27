#!/usr/bin/env ruby
# frozen_string_literal: true

# Scroll — pan a camera around a world bigger than the screen with the D-pad.
#
# A tiled background can be larger than the 240x160 screen; you move the visible
# WINDOW over it with `scroll_by` (or `scroll_to`), and the console's background
# hardware does the sliding for free — no redrawing, no scroll registers to touch.
# The world here is 32x32 tiles (256x256 pixels), so there's more world than screen
# in every direction; scroll far enough and it WRAPS, because a background is a
# torus. That's the groundwork a follow-you camera is built on.
#
# What you never touch: the scroll registers, where the map lives in video memory,
# how wrapping works. You say where the window sits, in pixels, and it goes there.
#
# (This pans an empty world — the camera on its own. Put a sprite on top and follow
# it and you have a follow-you camera: see examples/hero.rb.)
#
# Run it to build examples/scroll.gba:
#   ruby examples/scroll.rb

require_relative "../lib/ruby_gba"

module Scroll
  SPEED = 2

  # A 32x32 world: grass, a lake in the middle, and trees scattered across it — so
  # there's plenty to see slide by as you pan.
  MAP = (0...32).map do |r|
    (0...32).map do |c|
      if (10..14).cover?(r) && (12..19).cover?(c) then "~" # a lake
      elsif ((r * 3) + (c * 5)) % 11 == 0            then "T" # scattered trees
      else "."                                              # grass
      end
    end.join
  end.freeze

  GAME = proc do
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
      wait_vblank # scroll here, in the safe window, so the whole view moves together

      # Hold a direction to pan the camera that way; the world slides under it.
      held(:left).then  { world.scroll_by(-SPEED, 0) }
      held(:right).then { world.scroll_by(SPEED, 0) }
      held(:up).then    { world.scroll_by(0, -SPEED) }
      held(:down).then  { world.scroll_by(0, SPEED) }
    end
  end

  def self.build_rom(out: $stdout, err: $stderr)
    RubyGBA.build("SCROLL", code: "BSCR", maker: "01", out: out, err: err, &GAME)
  end

  def self.program
    builder = RubyGBA::Builder.new
    builder.instance_eval(&GAME)
    builder.emit_pending_functions
    builder.program
  end
end

if __FILE__ == $PROGRAM_NAME
  rom = Scroll.build_rom
  output = File.join(__dir__, "scroll.gba")
  rom.write(output)
  puts "Built scroll.gba (#{rom.size} bytes)"
end
