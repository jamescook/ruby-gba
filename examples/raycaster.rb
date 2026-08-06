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
# Walk with UP / DOWN, turn with LEFT / RIGHT. You cannot walk through walls. Build it:
#   ruby examples/raycaster.rb
#
# Two things make this example what it is.
#
# `table` — the console can't do sine or division cheaply enough to run per ray, per
# frame. So the curves are precomputed in plain Ruby at build time and shipped as ROM
# tables the game just looks up:
#   - `sin` — the ray's direction from its angle (cosine is the same table, a quarter turn over).
#   - `heights` — the wall-column height for a hit distance (the "inside out" reciprocal).
#   - `world` — the maze itself, one byte per cell (1 = wall).
#
# `times_fraction` — a walking player stands *between* cells, so every position, step and
# distance here is a number with a fraction (see FIXED, below). Adding those works as it
# is. Multiplying two of them does not, and that is what times_fraction is for: read the
# comment at the fisheye correction, which is the multiply that needs it.
#
# A note on speed: this casts a ray per screen column, and each column is one fill as
# tall as the ray says — draw_rect_at takes a height the game works out. It runs at 30
# frames a second. What is left is the ray march itself: two divisions per step to find
# which cell the ray is in, sixty times a column.

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

  # A variable holds whole numbers only, so a player standing three and a half cells
  # along the corridor keeps that as 3.5 multiplied up by a fixed amount. FIXED is that
  # amount: one whole maze cell. Everything positional below is in these units.
  FIXED = 1 << 16 # a cell, in fixed-point units — 16 fraction bits
  def self.fixed(n) = (n * FIXED).round

  NUM_COLS = 30    # screen strips: 30 columns x 8px = 240px wide
  COL_W = 8
  STEP = FIXED / 4 # a ray advances a quarter of a cell at a time
  STEPS = 20       # ...20 times, so it sees five cells before it gives up
  HORIZON = 80     # the eye line: wall columns are centered here
  WALK = fixed(0.09) # how far a step of walking moves, in cells

  # The direction tables. A full turn is 512 angle units; sine is scaled by FIXED so the
  # math stays in whole numbers. Cosine is the same curve read a quarter turn (128) later.
  TURN = 512
  QUARTER = TURN / 4
  SIN = (0...TURN).map { |a| (Math.sin(a * 2 * Math::PI / TURN) * FIXED).round }

  # Wall-column height for a hit distance, in quarter-cell steps: a reciprocal, so a near
  # wall (small distance) is tall and a far one is short, clamped to a sensible band.
  MAX_H = 120
  HEIGHT = (0..STEPS).map { |d| [[(MAX_H * 3) / (d + 2), MAX_H].min, 8].max }

  # The palette. Sky and floor bracket the eye line, and the three wall shades are the
  # depth cue: a near wall catches the light, a far one falls into the gloom.
  SKY = RubyGBA::Color.rgb(5, 7, 12)
  FLOOR = RubyGBA::Color.rgb(11, 8, 5)
  NEAR = RubyGBA::Color.rgb(29, 27, 23)
  MID = RubyGBA::Color.rgb(20, 18, 15)
  FAR = RubyGBA::Color.rgb(11, 10, 9)
  WALL_SHADES = [NEAR, MID, FAR].freeze

  GAME = RubyGBA.game("RAYCAST", code: "BRAY", maker: "01") do
    screen :bitmap, tear_free: true # double-buffered: the whole view is repainted each frame

    sin     = table :sin, SIN, width: :word # signed, and a whole cell won't fit in a half
    heights = table :heights, HEIGHT, width: :half
    world   = table :world, MAP, width: :byte

    view = var :view, 0                      # the way the player faces (0..255, wraps freely)
    px = var :px, (3 * FIXED) + (FIXED / 2)  # standing in the middle of cell (3, 3)
    py = var :py, (3 * FIXED) + (FIXED / 2)

    step_x = var :_step_x, 0 # this frame's walking step
    step_y = var :_step_y, 0
    nx   = var :_nx, 0    # where a step would put the player
    ny   = var :_ny, 0
    ang  = var :_ang, 0   # this column's ray angle
    dx   = var :_dx, 0    # the ray's step in x and y
    dy   = var :_dy, 0
    rx   = var :_rx, 0    # the ray's current position
    ry   = var :_ry, 0
    hit  = var :_hit, 0   # has this ray met a wall yet?
    dist = var :_dist, 0  # how far it got
    seen = var :_seen, 0  # ...and how far that is once the fan is corrected for
    col_h = var :_col_h, 0
    top  = var :_top, 0

    game_loop do
      # The room: sky down to the eye line, boards below it. Two block fills, so the
      # backdrop costs the same however much of it a wall ends up covering.
      dma_fill_rect 0, 0, 240, HORIZON, SKY
      dma_fill_rect 0, HORIZON, 240, 160 - HORIZON, FLOOR

      held(:left).then  { view.sub 4 }
      held(:right).then { view.add 4 }

      # Walking. The step is WALK cells in the direction the player faces, which is
      # WALK times a cosine and a sine — the first of the multiplies that needs a
      # fraction on both sides.
      step_x.set(sin[view + QUARTER].times_fraction(WALK, fraction_bits: 16))
      step_y.set(sin[view].times_fraction(WALK, fraction_bits: 16))
      held(:down).then { step_x.flip }
      held(:down).then { step_y.flip }

      (held(:up) | held(:down)).then do
        # Try the step, and take it only if the cell it lands in is empty — otherwise
        # you walk through walls.
        nx.set px
        nx.add step_x
        ny.set py
        ny.add step_y
        (world[((ny / FIXED) * MAP_W) + (nx / FIXED)] == 0).then do
          px.set nx
          py.set ny
        end
      end

      repeat(NUM_COLS) do |col|
        # Fan the rays across the view: this column looks a little left or right of center.
        # Two angle units apart, centered on the ODD number in between, so the fan is
        # symmetric and no ray ever points exactly straight ahead. That last part matters.
        # A ray dead ahead reaches a wall in one fewer quarter-cell step than its angled
        # neighbours, and since a ray only ever stops on a whole step, no amount of
        # correcting afterwards can put that step back — it shows as one notched column in
        # the middle of the view, wherever you look. Offset, every ray is treated alike.
        ang.set view
        ang.add(col * 2)
        ang.sub(NUM_COLS - 1)

        # Step vector for this ray. cos(ang) = sin[ang + QUARTER]; a quarter cell per step.
        dx.set(sin[ang + QUARTER] / 4)
        dy.set(sin[ang] / 4)

        rx.set px
        ry.set py
        hit.set 0
        dist.set(STEPS * STEP) # if nothing is hit in range, treat it as far away

        repeat(STEPS) do |step|
          (hit == 0).then do
            rx.add dx
            ry.add dy
            # The cell the ray is in now. The border ring is solid, so a ray leaving the
            # room meets the border wall first; the table read is bounds-safe regardless.
            (world[((ry / FIXED) * MAP_W) + (rx / FIXED)] == 1).then do
              hit.set 1
              dist.set(step * STEP)
            end
          end
        end

        # Correct for the fan. A ray angled away from center travels further to reach the
        # same flat wall, so without this a straight wall bows outward at the edges of the
        # view — the "fisheye" look. Multiplying the distance by the cosine of the angle
        # off center takes that back out.
        #
        # THIS is the multiply that needs times_fraction. Both numbers hold a fraction, so
        # the product comes out multiplied up twice and has to come back down once — and
        # the doubled-up value has to exist on the way. Three cells times one is three, but
        # scaled up twice that is nearly 13 thousand million, six times past where a
        # variable wraps. Plain `*` wraps there and the wall lands at a nonsense height.
        seen.set(dist.times_fraction(sin[(col * 2) + (QUARTER - (NUM_COLS - 1))], fraction_bits: 16))

        # Round to the nearest step rather than letting the division truncate. A ray only
        # ever stops on a whole step, and the correction always shaves a little off, so
        # truncating would drop nearly every column a whole step further out than it
        # really is. Adding half a step first rounds instead.
        col_h.set heights[(seen + (STEP / 2)) / STEP]
        top.set HORIZON
        top.sub(col_h / 2)

        # Shade the column by how far away it is, which is what reads as depth: near walls
        # catch the light, far ones fall into the gloom. draw_rect_at takes a fixed color,
        # so each band is its own fill and exactly one of them runs. The HEIGHT is the
        # number the ray just worked out, which is the whole wall column in one fill.
        (dist < (6 * STEP)).then do
          draw_rect_at((col * COL_W), top, COL_W, col_h, NEAR)
        end.else do
          (dist < (12 * STEP)).then do
            draw_rect_at((col * COL_W), top, COL_W, col_h, MID)
          end.else do
            draw_rect_at((col * COL_W), top, COL_W, col_h, FAR)
          end
        end
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Raycaster::GAME.write_if_main
