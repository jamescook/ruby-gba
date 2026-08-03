#!/usr/bin/env ruby
# frozen_string_literal: true

# Raycaster — a first-person 3D view of a tiny maze, drawn the way Wolfenstein 3D was.
#
# The trick is old and clever: the world is a flat grid of walls, but for each vertical
# strip of the screen you shoot a "ray" out from the player, find how far it travels
# before it hits a wall, and draw a wall column whose height is that distance turned
# inside out — near walls are tall, far walls are short. Do that across the screen and a
# flat grid looks like rooms you can walk through.
#
# What makes it fit the GBA — and what this example is really about — is `table`. The
# console can't do sine or division cheaply enough to run per ray, per frame. So the
# curves are precomputed in plain Ruby at build time and shipped as ROM tables the game
# just looks up:
#   - `sin` — the ray's direction from its angle (cosine is the same table, a quarter turn over).
#   - `heights` — the wall-column height for a hit distance (the "inside out" reciprocal).
#   - `world` — the maze itself, one byte per cell (1 = wall).
#
# Steer with LEFT / RIGHT to turn. Run it to build examples/raycaster.gba:
#   ruby examples/raycaster.rb
#
# A note on speed: this casts a ray per screen column and paints each wall column a row
# at a time, so it does a lot of work per frame and runs at only a few frames a second.
# Real GBA raycasters lean on tricks this framework does not expose yet — bit shifts in
# place of the divides, and a single variable-height column fill instead of a row loop.
# The point of the example is the `table` lookups that make the ray math possible at all.

require_relative "../lib/ruby_gba"

module Raycaster
  MAP_W = 8 # an 8x8 maze: a solid border ring with a few inner walls
  MAP = [
    1, 1, 1, 1, 1, 1, 1, 1,
    1, 0, 0, 0, 0, 0, 0, 1,
    1, 0, 1, 1, 0, 0, 0, 1,
    1, 0, 0, 0, 0, 1, 0, 1,
    1, 0, 0, 1, 0, 1, 0, 1,
    1, 0, 0, 1, 0, 0, 0, 1,
    1, 0, 0, 0, 0, 0, 0, 1,
    1, 1, 1, 1, 1, 1, 1, 1
  ].freeze

  NUM_COLS = 30 # screen strips: 30 columns x 8px = 240px wide
  COL_W = 8
  STEPS = 14    # how far a ray marches before it gives up
  HALF = NUM_COLS / 2
  CELL = 256    # fixed-point units per maze cell (a power of two, so cell = pos / 256)
  HORIZON = 80  # the eye line: wall columns are centered here

  # The direction tables. A full turn is 256 angle units; sine is scaled by CELL so the
  # math stays in whole numbers. Cosine is the same curve read a quarter turn (64) later.
  SIN = (0...256).map { |a| (Math.sin(a * 2 * Math::PI / 256) * CELL).round }

  # Wall-column height for a hit distance: a reciprocal, so a near wall (small distance)
  # is tall and a far one is short, clamped to a sensible band.
  MAX_H = 120
  HEIGHT = (0..STEPS).map { |d| [[(MAX_H * 3) / (d + 2), MAX_H].min, 8].max }

  GAME = RubyGBA.game("RAYCAST", code: "BRAY", maker: "01") do
    screen :bitmap, tear_free: true # double-buffered: the whole view is repainted each frame

    sin     = table :sin, SIN, width: :half        # signed (the curve dips negative)
    heights = table :heights, HEIGHT, width: :half
    world   = table :world, MAP, width: :byte

    view = var :view, 0                    # the way the player faces (0..255, wraps freely)
    px = var :px, (3 * CELL) + (CELL / 2)  # standing in the middle of cell (3, 3)
    py = var :py, (3 * CELL) + (CELL / 2)

    ang  = var :_ang, 0   # this column's ray angle
    dx   = var :_dx, 0    # the ray's step in x and y
    dy   = var :_dy, 0
    rx   = var :_rx, 0    # the ray's current position
    ry   = var :_ry, 0
    hit  = var :_hit, 0   # has this ray met a wall yet?
    dist = var :_dist, 0  # how many steps it took
    col_h = var :_col_h, 0
    top  = var :_top, 0

    game_loop do
      wait_vblank
      clear_screen :black
      held(:left).then  { view.sub 2 }
      held(:right).then { view.add 2 }

      repeat(NUM_COLS) do |col|
        # Fan the rays across the view: this column looks a little left or right of center.
        ang.set view
        ang.add col
        ang.sub HALF

        # Step vector for this ray. cos(ang) = sin[ang + 64]; a quarter of a cell per step.
        dx.set(sin[ang + 64] / 4)
        dy.set(sin[ang] / 4)

        rx.set px
        ry.set py
        hit.set 0
        dist.set STEPS # if nothing is hit in range, treat it as far away

        repeat(STEPS) do |step|
          (hit == 0).then do
            rx.add dx
            ry.add dy
            # The cell the ray is in now. The border ring is solid, so a ray leaving the
            # room meets the border wall first; the table read is bounds-safe regardless.
            (world[((ry / CELL) * MAP_W) + (rx / CELL)] == 1).then do
              hit.set 1
              dist.set step
            end
          end
        end

        # Turn the hit distance into a wall-column height, and draw the strip centered on
        # the horizon. draw_rect_at is fixed-size, so the variable height is a row loop.
        col_h.set heights[dist]
        top.set HORIZON
        top.sub(col_h / 2)
        repeat(col_h) do |row|
          draw_rect_at((col * COL_W), top + row, COL_W, 1, :white)
        end
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Raycaster::GAME.write_if_main
