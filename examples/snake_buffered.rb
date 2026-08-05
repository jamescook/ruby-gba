#!/usr/bin/env ruby
# frozen_string_literal: true

# Snake, drawn the simple way — because the screen is double-buffered.
#
# This is the same game as examples/snake.rb, with one deliberate difference in how
# it draws. The other Snake is careful: it paints the board once and then, every
# step, touches only the few cells that change (new head, old head, vacated tail).
# It has to be, because on a single-buffered screen redrawing the whole board every
# frame does too much work to finish in the brief safe window, and the picture
# tears once the snake gets long.
#
# Here we don't bother. Every frame just clears the screen and repaints everything —
# walls, food, the entire snake body, the score — the obvious way you'd want to
# write it. It stays perfectly clean no matter how long the snake grows, because
# `screen :bitmap, tear_free: true` draws to a hidden screen and shows it all at
# once, so a half-finished frame is never visible. The only cost of doing more work
# is a lower frame rate, never a torn image.
#
# That's the whole point: remove that one flag and this identical code goes back to
# tearing in direct-color Mode 3. Double buffering is what lets you write the naive
# version.
#
# The rules are unchanged: d-pad steers, eat the red food to grow and score, hit a
# wall or yourself and it's game over, START to play.
#
# Run it to build examples/snake_buffered.gba:
#   ruby examples/snake_buffered.rb

require_relative "../lib/ruby_gba"

module BufferedSnake
  # --- Build-time constants (plain Ruby, resolved before any code is emitted) ---
  SCREEN_W = 240
  SCREEN_H = 160

  CELL = 8                     # an 8x8 cell — cells land on even columns, which the
  COLS = SCREEN_W / CELL       # buffered screen needs (it writes two pixels at once)
  ROWS = SCREEN_H / CELL

  HEADER_ROWS = 2
  MIN_COL = 1
  MAX_COL = COLS - 2
  MIN_ROW = HEADER_ROWS + 1
  MAX_ROW = ROWS - 2

  TOP_WALL_Y    = HEADER_ROWS * CELL
  BOTTOM_WALL_Y = (ROWS - 1) * CELL
  RIGHT_WALL_X  = (COLS - 1) * CELL
  WALL_H        = SCREEN_H - TOP_WALL_Y

  SCORE_LABEL_X = 8
  SCORE_NUM_X   = 50
  SCORE_Y       = 4
  SCORE_NUM_W   = 3 * 6

  BODY_CAP = (MAX_COL - MIN_COL + 1) * (MAX_ROW - MIN_ROW + 1)

  STEP = 6                     # frames between moves
  START_ROW   = (MIN_ROW + MAX_ROW) / 2
  START_CELLS = [[5, START_ROW], [6, START_ROW], [7, START_ROW], [8, START_ROW]].freeze
  FOOD_TRIES = 8

  GAME = RubyGBA.game("SNAKEBUF", code: "BSNB", maker: "01") do
    screen :bitmap, tear_free: true # <-- the whole difference. Remove it and it tears.
    enable_sound

    define_sound :eat, frequency: 880, duty: :quarter, decay: :fast
    define_sound :die, frequency: 140, duty: :half, decay: :medium

    # The body: two parallel lists, one entry per cell (xs[i], ys[i]).
    xs = list :xs, capacity: BODY_CAP
    ys = list :ys, capacity: BODY_CAP

    var :state, 0               # 0 = title, 1 = playing, 2 = game over
    blink    = var :blink, 1
    dx       = var :dx, 1
    dy       = var :dy, 0
    var :ndx, 1
    var :ndy, 0
    hx       = var :hx, 0
    hy       = var :hy, 0
    food_x   = var :food_x, 0
    food_y   = var :food_y, 0
    score    = var :score, 0
    self_hit = var :self_hit, 0
    placed   = var :placed, 0

    # Pick a random empty cell for the food (placement only; drawing happens in the
    # every-frame repaint). Tries a handful of random cells, keeping the first that
    # isn't under the snake.
    func :spawn_food do
      set :placed, 0
      FOOD_TRIES.times do
        (placed == 0).then do
          roll :food_x, MIN_COL..MAX_COL
          roll :food_y, MIN_ROW..MAX_ROW
          set :placed, 1
          repeat(xs.length) do |i|
            ((xs[i] == :food_x) & (ys[i] == :food_y)).then { set :placed, 0 }
          end
        end
      end
    end

    # Repaint the ENTIRE board from scratch. This is the whole demo: on a single-
    # buffered screen this would tear once the body grew; here it can't, so we just
    # do it every frame instead of tracking what changed.
    func :draw_all do
      clear_screen :black
      draw_text "SCORE", SCORE_LABEL_X, SCORE_Y, :gray
      dma_fill_rect 0, TOP_WALL_Y, SCREEN_W, CELL, :gray            # top wall
      dma_fill_rect 0, BOTTOM_WALL_Y, SCREEN_W, CELL, :gray         # bottom wall
      dma_fill_rect 0, TOP_WALL_Y, CELL, WALL_H, :gray             # left wall
      dma_fill_rect RIGHT_WALL_X, TOP_WALL_Y, CELL, WALL_H, :gray  # right wall
      draw_number score, SCORE_NUM_X, SCORE_Y, :white, digits: 3
      draw_rect_at food_x * CELL, food_y * CELL, CELL, CELL, :red
      repeat(xs.length) do |i|
        draw_rect_at xs[i] * CELL, ys[i] * CELL, CELL, CELL, :green
      end
      draw_rect_at xs.last * CELL, ys.last * CELL, CELL, CELL, :white # head
    end

    # Start a fresh game: reset the body, face right, zero the score, place the food.
    # No board painting here — the playing scene repaints every frame anyway.
    func :new_game do
      list :xs, capacity: BODY_CAP
      list :ys, capacity: BODY_CAP
      START_CELLS.each do |cx, cy|
        xs.push cx
        ys.push cy
      end
      set :dx, 1
      set :dy, 0
      set :ndx, 1
      set :ndy, 0
      set :score, 0
      call :spawn_food
      set :state, 1
    end

    # Advance the snake one cell — pure game logic, no drawing (draw_all handles the
    # picture). Commit the buffered turn, work out the new head, then die, eat, or
    # slide.
    func :step_snake do
      copy :dx, :ndx
      copy :dy, :ndy
      set :hx, xs.last + dx
      set :hy, ys.last + dy

      set :self_hit, 0
      repeat(xs.length) do |i|
        ((xs[i] == :hx) & (ys[i] == :hy)).then { set :self_hit, 1 }
      end

      dead = (hx < MIN_COL) | (hx > MAX_COL) | (hy < MIN_ROW) | (hy > MAX_ROW) | (self_hit == 1)
      dead.then do
        set :state, 2
        beep :die
      end.else do
        xs.push :hx
        ys.push :hy
        ((hx == food_x) & (hy == food_y)).then do
          score.add 1
          beep :eat
          call :spawn_food
        end.else do
          xs.shift
          ys.shift
        end
      end
    end

    scene :title do
      clear_screen :black
      draw_text "SNAKE", 105, 56, :green
      every(0.5, :seconds) { (blink == 1).then { blink.set 0 }.else { blink.set 1 } }
      (blink == 1).then { draw_text "PRESS START", 87, 96, :gray }
      randomize
      pressed(:start).then { call :new_game }
    end

    scene :playing do
      held(:up).then    { (dy == 0).then { set :ndx, 0; set :ndy, -1 } }
      held(:down).then  { (dy == 0).then { set :ndx, 0; set :ndy, 1 } }
      held(:left).then  { (dx == 0).then { set :ndx, -1; set :ndy, 0 } }
      held(:right).then { (dx == 0).then { set :ndx, 1; set :ndy, 0 } }

      every(STEP) { call :step_snake }
      call :draw_all # repaint the whole board, every frame — safe because buffered
    end

    scene :game_over do
      clear_screen :black
      draw_text "GAME OVER", 93, 52, :red
      draw_text "SCORE", 84, 80, :gray
      draw_number score, 132, 80, :white, digits: 3
      every(0.5, :seconds) { (blink == 1).then { blink.set 0 }.else { blink.set 1 } }
      (blink == 1).then { draw_text "PRESS START", 87, 110, :gray }
      pressed(:start).then { call :new_game }
    end

    game_loop do
      case_var :state do
        when_val 0, :title
        when_val 1, :playing
        when_val 2, :game_over
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

BufferedSnake::GAME.write_if_main
