#!/usr/bin/env ruby
# frozen_string_literal: true

# Corridor — a first-person crawl with a status bar, and the example that runs CLOSE TO THE
# LINE on purpose.
#
# Every other example here is comfortable: the heaviest of them uses under half the frame, so
# `rom.explain` has never had to call a game that is genuinely near the edge. This one is. It
# casts twice as many rays as examples/raycaster.rb, draws them into a letterboxed view with a
# status bar underneath, and spends most of a frame doing it. Build it and read the report —
# the budget line is the point of the example.
#
# WHAT A FRAME IS SPENT ON, and it is not what people guess. Nearly all of it is the ray
# casting: sixty rays, each marching until it meets a wall, each one a handful of table reads
# and a divide. The DRAWING is cheap by comparison — the sky and the floor are one transfer
# each, and a wall column is one fill however tall it is. If you want the frame back, cast
# fewer rays (NUM_COLS below); everything else is rounding. Cast MORE and it stops fitting:
# eighty rays does not hold a frame, and `rom.explain` says so before you run it.
#
# `inside` IS WHY THE STATUS BAR IS FREE. The view is drawn inside a 240x128 window, so the
# thirty-two rows under it are never touched by the sky, the floor or a wall column — those
# pixels are not drawn and then covered, they are not drawn. Without it a near wall paints the
# full height of the screen and the bar goes on top, and you pay for every pixel underneath.
#
# Walk with UP / DOWN, turn with LEFT / RIGHT. Gold is scattered through the maze; step on a
# cell to take it, and the bar counts what you have. Build it:
#   ruby examples/corridor.rb

require_relative "../lib/ruby_gba"

module Corridor
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

  # The cells holding gold, as map indices. Walk onto one to take it.
  GOLD = [17, 22, 41, 46, 51, 54].freeze

  NUM_COLS = 60 # sixty strips across the view, four pixels each: 240 wide
  COL_W = 4
  STEPS_PER_CELL = 10         # a ray advances a tenth of a cell at a time...
  STEP = 1.0 / STEPS_PER_CELL
  STEPS = 50                  # ...50 times, so it sees five cells before it gives up
  USUAL_STEPS = 23            # ...and meets a wall in about 23, measured. See `estimate:`.

  # The view is the top of the screen; the status bar has the rest.
  VIEW_H = 128
  BAR_H = 160 - VIEW_H
  HORIZON = VIEW_H / 2        # the eye line: wall columns are centered here
  WALK = 0.09                 # how far a step of walking moves, in cells

  # The direction tables. A full turn is 512 angle units. Cosine is the same curve read
  # a quarter turn (128) later.
  TURN = 512
  QUARTER = TURN / 4
  SIN = (0...TURN).map { |a| Math.sin(a * 2 * Math::PI / TURN) }

  # How tall a wall one cell away stands in the view. The band keeps a wall you are
  # nose-to-nose with from filling the world, and one at the far end from vanishing.
  WALL_SCALE = 72
  SOFTEN = 0.5
  MAX_H = VIEW_H - 8
  MIN_H = 6
  USUAL_H = 31 # about how tall a wall stands on a normal frame, measured. See `estimate:`.

  SKY = RubyGBA::Color.rgb(4, 6, 11)
  FLOOR = RubyGBA::Color.rgb(10, 7, 4)
  NEAR = RubyGBA::Color.rgb(29, 26, 20)
  MID = RubyGBA::Color.rgb(19, 17, 13)
  FAR = RubyGBA::Color.rgb(10, 9, 8)
  BAR = RubyGBA::Color.rgb(2, 2, 4)
  GOLD_C = RubyGBA::Color.rgb(31, 27, 6)
  WALL_SHADES = [NEAR, MID, FAR].freeze

  # The game, with the ray count left as a parameter. It is a parameter because it is the one
  # knob that decides whether this fits in a frame, and the example is about that: at the
  # sixty rays it ships with the console spends about four fifths of a frame, and at eighty it
  # does not fit at all. A test drives both sides to check the estimate agrees.
  def self.game(name: "CORRIDOR", code: "BCOR", cols: NUM_COLS, col_w: COL_W)
    RubyGBA.game(name, code: code, maker: "01") do
      screen :bitmap, tear_free: true # double-buffered: the whole view is repainted each frame
      enable_sound
      define_sound :chime, frequency: 1400, duty: :half, decay: :fast

      sin = table :sin, SIN
      world = table :world, MAP, width: :byte
      gold_at = table :gold_at, GOLD, width: :byte
      taken = list :taken, capacity: GOLD.length, width: :byte

      view = var :view, 0    # the way the player faces (0..511, wraps freely)
      px = var :px, 3.5      # standing in the middle of cell (3, 3)
      py = var :py, 3.5
      score = var :score, 0

      step_x = var :_step_x, 0.0 # this frame's walking step
      step_y = var :_step_y, 0.0
      nx = var :_nx, 0.0    # where a step would put the player
      ny = var :_ny, 0.0
      cell = var :_cell, 0  # the map index the player stands on
      ang = var :_ang, 0    # this column's ray angle
      dx = var :_dx, 0.0    # the ray's step in x and y
      dy = var :_dy, 0.0
      rx = var :_rx, 0.0    # the ray's current position
      ry = var :_ry, 0.0
      hit = var :_hit, 0    # has this ray met a wall yet?
      dist = var :_dist, 0.0 # how far it got, in cells
      seen = var :_seen, 0.0 # ...and how far that is once the fan is corrected for
      col_h = var :_col_h, 0
      top = var :_top, 0

      # One slot per piece of gold, 0 until it is taken. Filled once, at boot.
      GOLD.each_index { taken << 0 }

      game_loop do
        # The status bar first, so the view is painted over a clean strip either way.
        dma_fill_rect 0, VIEW_H, 240, BAR_H, BAR

        inside 0, 0, 240, VIEW_H do
          # The room: sky down to the eye line, boards below it. Two block fills, so the
          # backdrop costs the same however much of it a wall ends up covering.
          dma_fill_rect 0, 0, 240, HORIZON, SKY
          dma_fill_rect 0, HORIZON, 240, VIEW_H - HORIZON, FLOOR

          repeat(cols) do |col|
            # Fan the rays across the view: this column looks a little left or right of center,
            # centered on the odd number in between so no ray points exactly straight ahead.
            ang.set view
            ang.add(col * 2)
            ang.sub(cols - 1)

            # Step vector for this ray. cos(ang) = sin[ang + QUARTER]; a quarter cell per step.
            dx.set(sin[ang + QUARTER] * STEP)
            dy.set(sin[ang] * STEP)

            rx.set px
            ry.set py
            hit.set 0
            dist.set(STEPS * STEP) # if nothing is hit in range, treat it as far away

            # March until the ray meets a wall, and stop there. This loop is the frame.
            repeat(STEPS, stop_when: hit == 1, estimate: { usually: USUAL_STEPS }) do |step|
              rx.add dx
              ry.add dy
              (world[(ry.to_i * MAP_W) + rx.to_i] == 1).then do
                hit.set 1
                dist.set(step * STEP)
              end
            end

            # Correct for the fan, so a flat wall reads flat instead of bowing outward.
            seen.set(dist * sin[(col * 2) + (QUARTER - (cols - 1))])

            # The perspective divide: a wall twice as far covers half as much of the view.
            col_h.set((WALL_SCALE / (seen + SOFTEN)).to_i)
            col_h.clamp MIN_H, MAX_H
            top.set HORIZON
            top.sub(col_h / 2)

            # Shade by distance, which is what reads as depth. Exactly one band runs.
            (dist < 1.5).then do
              draw_rect_at((col * col_w), top, col_w, col_h, NEAR, estimate: { usually: USUAL_H })
            end.else do
              (dist < 3.0).then do
                draw_rect_at((col * col_w), top, col_w, col_h, MID, estimate: { usually: USUAL_H })
              end.else do
                draw_rect_at((col * col_w), top, col_w, col_h, FAR, estimate: { usually: USUAL_H })
              end
            end
          end
        end

        # Turning and walking, the same as any first-person game: the step is WALK cells in the
        # direction the player faces, and it is only taken if the cell it lands in is empty.
        held(:left).then  { view.sub 4 }
        held(:right).then { view.add 4 }

        step_x.set(sin[view + QUARTER] * WALK)
        step_y.set(sin[view] * WALK)
        held(:down).then { step_x.flip }
        held(:down).then { step_y.flip }

        (held(:up) | held(:down)).then do
          nx.set px
          nx.add step_x
          ny.set py
          ny.add step_y
          (world[(ny.to_i * MAP_W) + nx.to_i] == 0).then do
            px.set nx
            py.set ny
          end
        end

        # Gold: if the cell underfoot holds a piece nobody has taken, take it.
        cell.set((py.to_i * MAP_W) + px.to_i)
        repeat(GOLD.length) do |g|
          ((gold_at[g] == cell) & (taken[g] == 0)).then do
            taken[g] = 1
            score.add 1
            beep :chime
          end
        end

        # The bar: how much gold, out of how much there is.
        draw_text "GOLD", 8, VIEW_H + 10, :white, font: :tiny
        draw_number :score, 46, VIEW_H + 10, GOLD_C, digits: 2, font: :tiny
        draw_text "OF", 66, VIEW_H + 10, :gray, font: :tiny
        draw_number GOLD.length, 82, VIEW_H + 10, :white, digits: 2, font: :tiny
      end
    end
  end

  GAME = game

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Corridor::GAME.write_if_main
