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
# `table` — the console can't work out a sine cheaply enough to do it per ray, per frame.
# So the curve is precomputed in plain Ruby at build time and shipped as a ROM table the
# game just looks up:
#   - `sin` — the ray's direction from its angle (cosine is the same table, a quarter turn over).
#   - `world` — the maze itself, one byte per cell (1 = wall).
#
# Numbers with a fraction — a walking player stands *between* cells, so every position,
# step and distance here is one. Writing a Float is all it takes to declare one, and the
# arithmetic carries it: adding works as it is, and multiplying or dividing two of them
# is handled for you (both would otherwise come out wrong by a factor of thousands).
# The wall height is the interesting one — `WALL_SCALE / (seen + SOFTEN)` is the
# perspective divide, the single line that turns a distance into a picture.
#
# A note on speed: this casts a ray per screen column, and each column is one fill as
# tall as the ray says — draw_rect_at takes a height the game works out. It runs at 30
# frames a second, and most of that is the two full-screen fills for sky and floor.

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
  STEPS_PER_CELL = 4          # a ray advances a quarter of a cell at a time...
  STEP = 1.0 / STEPS_PER_CELL
  STEPS = 20                  # ...20 times, so it sees five cells before it gives up
  HORIZON = 80                # the eye line: wall columns are centered here
  WALK = 0.09                 # how far a step of walking moves, in cells

  # The direction tables. A full turn is 512 angle units. Cosine is the same curve read
  # a quarter turn (128) later.
  TURN = 512
  QUARTER = TURN / 4
  SIN = (0...TURN).map { |a| Math.sin(a * 2 * Math::PI / TURN) }

  # How tall a wall one cell away stands on screen. Everything closer is taller and
  # everything further is shorter, in proportion — that is the perspective divide below.
  # The band keeps a wall you are nose-to-nose with from filling the world, and one at
  # the far end of the corridor from vanishing.
  WALL_SCALE = 90
  SOFTEN = 0.5
  MAX_H = 120
  MIN_H = 8

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

    # A table written with Floats holds numbers with a fraction, and every read from it
    # hands one back — so nothing below has to mention a scale.
    sin     = table :sin, SIN
    world   = table :world, MAP, width: :byte

    view = var :view, 0    # the way the player faces (0..511, wraps freely)
    px = var :px, 3.5      # standing in the middle of cell (3, 3)
    py = var :py, 3.5

    step_x = var :_step_x, 0.0 # this frame's walking step
    step_y = var :_step_y, 0.0
    nx   = var :_nx, 0.0  # where a step would put the player
    ny   = var :_ny, 0.0
    ang  = var :_ang, 0   # this column's ray angle
    dx   = var :_dx, 0.0  # the ray's step in x and y
    dy   = var :_dy, 0.0
    rx   = var :_rx, 0.0  # the ray's current position
    ry   = var :_ry, 0.0
    hit  = var :_hit, 0   # has this ray met a wall yet?
    dist = var :_dist, 0.0 # how far it got, in cells
    seen = var :_seen, 0.0 # ...and how far that is once the fan is corrected for
    col_h = var :_col_h, 0
    top  = var :_top, 0

    game_loop do
      # The room: sky down to the eye line, boards below it. Two block fills, so the
      # backdrop costs the same however much of it a wall ends up covering.
      #
      # Painting only the sky and floor each column actually leaves uncovered — three
      # fills a column instead of two for the whole screen — touches a third fewer
      # pixels and is SLOWER. Measured: 20 frames a second against 30. Setting up a
      # transfer costs about what a short one moves, so ninety small fills lose to two
      # big ones.
      dma_fill_rect 0, 0, 240, HORIZON, SKY
      dma_fill_rect 0, HORIZON, 240, 160 - HORIZON, FLOOR

      held(:left).then  { view.sub 4 }
      held(:right).then { view.add 4 }

      # Walking. The step is WALK cells in the direction the player faces — a cosine and
      # a sine, each times the walking speed.
      step_x.set(sin[view + QUARTER] * WALK)
      step_y.set(sin[view] * WALK)
      held(:down).then { step_x.flip }
      held(:down).then { step_y.flip }

      (held(:up) | held(:down)).then do
        # Try the step, and take it only if the cell it lands in is empty — otherwise
        # you walk through walls. `.to_i` is which cell a position is in.
        nx.set px
        nx.add step_x
        ny.set py
        ny.add step_y
        (world[(ny.to_i * MAP_W) + nx.to_i] == 0).then do
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
        dx.set(sin[ang + QUARTER] * STEP)
        dy.set(sin[ang] * STEP)

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
            (world[(ry.to_i * MAP_W) + rx.to_i] == 1).then do
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
        # Both of these hold a fraction, and a distance times a cosine is the multiply
        # that would overflow if it were done the plain way — five cells times one is
        # five, but scaled up twice that is past where a variable wraps. Nothing here
        # says so, because nothing here has to: the framework knows both sides hold a
        # fraction and works the product out at full width.
        seen.set(dist * sin[(col * 2) + (QUARTER - (NUM_COLS - 1))])

        # The perspective divide, which is the whole trick of a view like this: a wall
        # twice as far away covers half as much of the screen, so its height on screen is
        # one over its distance. SOFTEN keeps a wall you are nose-to-nose with from being
        # infinitely tall, and the band keeps the answer on screen at both ends.
        col_h.set((WALL_SCALE / (seen + SOFTEN)).to_i)
        col_h.clamp MIN_H, MAX_H
        top.set HORIZON
        top.sub(col_h / 2)
        # Shade the wall by how far away it is, which is what reads as depth: near walls
        # catch the light, far ones fall into the gloom. draw_rect_at takes a fixed color,
        # so each band is its own fill and exactly one of them runs. The HEIGHT is the
        # number the ray just worked out, which is the whole wall column in one fill.
        (dist < 1.5).then do
          draw_rect_at((col * COL_W), top, COL_W, col_h, NEAR)
        end.else do
          (dist < 3.0).then do
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
