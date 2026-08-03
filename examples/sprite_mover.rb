#!/usr/bin/env ruby
# frozen_string_literal: true

# Sprite mover — steer a little hand-drawn heart around the screen with the D-pad.
#
# The heart is a `sprite`: a named image that owns its position and moves around
# leaving no trail. That's the whole point of this example. A sprite remembers the
# pixels underneath itself and paints them back when it moves, and the framework
# redraws it for you each frame during the vertical blank (the safe window to touch
# the screen). So there's no `clear_screen` in the loop and no `blit` — the field is
# painted once up front, and moving the heart is just changing `hero.x`/`hero.y`.
# Compare the redraw-everything way (clear the whole screen and re-blit every
# frame): that does more work each frame and tears once there's enough on screen.
#
# Run it to build examples/sprite_mover.gba:
#   ruby examples/sprite_mover.rb

require_relative "../lib/ruby_gba"

module SpriteMover
  SCREEN_W = 240
  SCREEN_H = 160
  SPEED    = 2
  SPRITE_W = 5
  SPRITE_H = 5
  HALF_W   = SPRITE_W / 2 # how far the heart may hang off a vertical edge
  HALF_H   = SPRITE_H / 2 # ... and off a horizontal edge

  # The game as a block the builder runs, so a test can drive the exact program
  # that ships — the headless interpreter runs THIS, the console runs the ROM.
  GAME = RubyGBA.game("SPRITEMV", code: "BSPM", maker: "01") do
    screen :bitmap

    # A little red heart. "." is transparent, so the field shows through its corners
    # — you're steering a heart, not a rectangle.
    image :heart, "." => :transparent, "#" => :red do
      <<~ART
        .#.#.
        #####
        #####
        .###.
        ..#..
      ART
    end

    # Paint the field ONCE, before the loop. From here on the heart is a sprite that
    # restores the field pixels under itself as it moves, so nothing else redraws.
    clear_screen rgb(4, 6, 14) # a calm blue field

    hero = sprite :heart, at: [(SCREEN_W - SPRITE_W) / 2, (SCREEN_H - SPRITE_H) / 2]

    game_loop do
      wait_vblank # the framework repaints the heart right here, in the safe window

      # Hold a direction to move — say it the way you'd think it: press left, move
      # left. `by:` is the speed; no x/y arithmetic in sight.
      held(:left).then  { hero.move :left,  by: SPEED }
      held(:right).then { hero.move :right, by: SPEED }
      held(:up).then    { hero.move :up,    by: SPEED }
      held(:down).then  { hero.move :down,  by: SPEED }

      # A sprite clips at the screen edges, so let the heart slide half off any side
      # or corner — just not so far it vanishes. It stays put until you steer back.
      hero.x.clamp(-HALF_W, SCREEN_W - SPRITE_W + HALF_W)
      hero.y.clamp(-HALF_H, SCREEN_H - SPRITE_H + HALF_H)
      # no draw call — moving the heart above is all it takes
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

SpriteMover::GAME.write_if_main
