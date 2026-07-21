#!/usr/bin/env ruby
# frozen_string_literal: true

# Sprite mover — a tiny complete game: steer a hand-drawn ASCII sprite around the
# screen with the D-pad. Shows off the image DSL (art with transparency), blit,
# and input, all in a few lines of plain Ruby.

require_relative "../lib/ruby_gba"

SCREEN_W = 240
SCREEN_H = 160
SPEED    = 2
SPRITE_W = 5
SPRITE_H = 5

rom = RubyGBA.build("SPRITEMV", code: "BSPM", maker: "01") do
  display :bitmap

  # A little red heart. "." is transparent, so the background shows through its
  # corners — you're steering a heart, not a rectangle.
  image :heart, "." => :transparent, "#" => :red do
    <<~ART
      .#.#.
      #####
      #####
      .###.
      ..#..
    ART
  end

  x = var :x, (SCREEN_W - SPRITE_W) / 2
  y = var :y, (SCREEN_H - SPRITE_H) / 2

  game_loop do
    wait_vblank
    clear_screen rgb(4, 6, 14) # a calm blue field

    # Hold a direction to move.
    held(:left).then  { x.sub SPEED }
    held(:right).then { x.add SPEED }
    held(:up).then    { y.sub SPEED }
    held(:down).then  { y.add SPEED }

    # blit has no run-time edge clipping yet, so keep the heart fully on-screen.
    x.clamp 0, SCREEN_W - SPRITE_W
    y.clamp 0, SCREEN_H - SPRITE_H

    blit :heart, :x, :y
  end
end

output = File.join(__dir__, "sprite_mover.gba")
rom.write(output)
puts "Built sprite_mover.gba (#{rom.size} bytes)"
