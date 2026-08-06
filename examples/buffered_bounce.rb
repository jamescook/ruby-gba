#!/usr/bin/env ruby
# frozen_string_literal: true

# A tear-free demo. Three balls bounce around, and the WHOLE screen is cleared and
# repainted every single frame — the "redraw everything" pattern that tears a
# direct-color game once it draws enough. Here it's flawless, because
# `tear_free: true` draws each frame to a hidden screen and shows it all at once,
# so a half-drawn frame is never visible.
#
# Want to see the difference? Remove `tear_free: true` and rebuild: the identical
# code goes back to the direct-color screen and can tear on real hardware. That's
# the whole point — the drawing code doesn't change, only the one flag does.
#
# Everything here is plain rectangles and named colors: no palette, no pages, no
# hardware to think about. The framework manages the two hidden screens and builds
# the color table silently.
#
# Usage:   ruby examples/buffered_bounce.rb
# Output:  examples/buffered_bounce.gba

require_relative "../lib/ruby_gba"

module BufferedBounce
  SCREEN_W = 240
  SCREEN_H = 160
  BALL = 8
  SPEED = 2

  GAME = RubyGBA.game("BOUNCE", code: "BBNC", maker: "01") do
    screen :bitmap, tear_free: true # the tear-proof screen — try flipping this to false

    # Each ball is a position (x, y) and a velocity (dx, dy).
    balls = [
      { x: var(:ax, 20),  y: var(:ay, 20),  dx: var(:adx, SPEED),  dy: var(:ady, SPEED),  color: :yellow },
      { x: var(:bx, 120), y: var(:by, 40),  dx: var(:bdx, SPEED),  dy: var(:bdy, -SPEED), color: :cyan },
      { x: var(:cx, 200), y: var(:cy, 100), dx: var(:cdx, -SPEED), dy: var(:cdy, SPEED),  color: :magenta },
    ]

    game_loop do
      clear_screen :blue                                   # wipe the whole screen...
      balls.each do |b|                                    # ...then repaint every ball
        draw_rect_at b[:x], b[:y], BALL, BALL, b[:color]
      end

      balls.each do |b|
        b[:x].add b[:dx]
        b[:y].add b[:dy]
        # Bounce: at a wall, point the velocity back toward the middle.
        (b[:x] <= 0).then              { b[:dx].set SPEED }
        (b[:x] >= SCREEN_W - BALL).then { b[:dx].set(-SPEED) }
        (b[:y] <= 0).then              { b[:dy].set SPEED }
        (b[:y] >= SCREEN_H - BALL).then { b[:dy].set(-SPEED) }
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

BufferedBounce::GAME.write_if_main
