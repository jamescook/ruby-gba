#!/usr/bin/env ruby
# frozen_string_literal: true

# Snake — the classic, built entirely with the ruby-gba DSL.
#
# Rules:
#   - The d-pad steers; the snake moves one cell on a steady beat.
#   - Eat the red food to grow and score a point.
#   - Run into a wall or into your own body and it's game over.
#   - Press START on the title (or after a game over) to play.
#
# It shows off the pieces that make a real game: a `list` for the growing body
# (two parallel lists, xs and ys, one cell per segment), `seed`/`rand` for where
# the food appears, `every` for the movement beat, `draw_number` for the live
# score, and scenes wired together with a state variable.
#
# --- Why the play field is drawn incrementally, not redrawn every frame ---
# The console draws to a single screen buffer that the TV is reading at the same
# time, and there's only a brief safe window each frame (the "vblank") to change
# it in. Redrawing the whole board every frame — clearing it, repainting the
# walls, then every body cell — does too much work to finish inside that window
# once the snake gets long, so the TV would show a half-finished picture (a torn,
# flickering image with the head missing). So this game paints the board once when
# a round starts, then each step only touches the few cells that actually change:
# it repaints the old head as a body cell, draws the new head, and erases the tail
# the snake just left. A handful of cells always fits in the safe window, so the
# picture stays clean no matter how long the snake grows.
#
# Run it to build examples/snake.gba:
#   ruby examples/snake.rb

require_relative "../lib/ruby_gba"

# Everything lives under Snake so the file is safe to `require` from a test
# (requiring it just defines the module; only running it directly writes a ROM).
module Snake
  # --- Build-time constants (plain Ruby, resolved before any code is emitted) ---
  SCREEN_W = 240
  SCREEN_H = 160

  # The play area is a grid of square cells. The snake and the food snap to it, so
  # positions are counted in cells (0, 1, 2 …); a `grid` (built below) turns those
  # cell coordinates into pixels, so nothing here multiplies by CELL by hand.
  CELL = 8                     # an 8x8 cell (draw widths must be even, and 8 is)
  COLS = SCREEN_W / CELL       # 30 cells across
  ROWS = SCREEN_H / CELL       # 20 cells down

  # The top two rows are a header for the score; a one-cell gray wall frames the
  # rest. The snake lives in the interior, between the walls.
  HEADER_ROWS = 2
  MIN_COL = 1                  # just inside the left wall (column 0)
  MAX_COL = COLS - 2           # just inside the right wall (column 29)
  MIN_ROW = HEADER_ROWS + 1    # just below the top wall
  MAX_ROW = ROWS - 2           # just above the bottom wall

  # Pixel geometry of the wall frame (all fixed, so it draws with dma_fill_rect).
  TOP_WALL_Y    = HEADER_ROWS * CELL       # top wall sits just under the header
  BOTTOM_WALL_Y = (ROWS - 1) * CELL        # bottom wall on the last row
  RIGHT_WALL_X  = (COLS - 1) * CELL         # right wall on the last column
  WALL_H        = SCREEN_H - TOP_WALL_Y     # how tall the side walls are

  # Header score readout: a fixed "SCORE" label and a three-digit field beside it,
  # both even-aligned so the fills are legal (draw widths must be even).
  SCORE_LABEL_X = 8
  SCORE_NUM_X   = 50
  SCORE_Y       = 4
  SCORE_NUM_W   = 3 * 6        # three 6px digit columns

  # The interior holds at most this many cells, so the body can never outgrow its
  # list — a `list` rounds its capacity up to a power of two, comfortably above this.
  BODY_CAP = (MAX_COL - MIN_COL + 1) * (MAX_ROW - MIN_ROW + 1)

  STEP = 6                     # frames between moves — the snake steps ~10x a second

  # The snake starts as a short horizontal run in the middle, heading right. The
  # body is ordered tail-first, so the last cell is the head.
  START_ROW   = (MIN_ROW + MAX_ROW) / 2
  START_CELLS = [[5, START_ROW], [6, START_ROW], [7, START_ROW], [8, START_ROW]].freeze

  FOOD_TRIES = 8               # random cells to try when placing food off the snake

  # The whole game, as a block the builder runs. Keeping it in one place means the
  # test drives the exact program that ships: the headless interpreter runs THIS to
  # check the game plays without crashing, and the console runs the ROM built from it.
  GAME = proc do
    screen :bitmap
    enable_sound

    # Short blips: a bright one for eating, a low one for dying.
    define_sound :eat, frequency: 880, duty: :quarter, decay: :fast
    define_sound :die, frequency: 140, duty: :half, decay: :medium

    # --- The body: two parallel lists, one entry per cell (xs[i], ys[i]) ---
    xs = list :xs, capacity: BODY_CAP
    ys = list :ys, capacity: BODY_CAP

    # --- RAM variables (each `var` hands back a handle we compare and mutate) ---
    var :state, 0               # 0 = title, 1 = playing, 2 = game over (read via case_var)
    blink    = var :blink, 1    # flashes the "PRESS START" prompt on and off
    dx       = var :dx, 1       # current heading, in cells per step (one axis at a time)
    dy       = var :dy, 0
    var :ndx, 1                 # the turn we'll commit on the next step (set/copied by name)
    var :ndy, 0
    hx       = var :hx, 0       # where the head is about to move
    hy       = var :hy, 0
    tail_x   = var :tail_x, 0   # the cell the tail vacates on a slide (so we can erase it)
    tail_y   = var :tail_y, 0
    food_x   = var :food_x, 0
    food_y   = var :food_y, 0
    score    = var :score, 0
    # The best score ever reached, kept in the cartridge's save memory so it's still
    # there next time the game is switched on. `save_var` is used exactly like `var`;
    # the framework loads it at boot and saves it whenever it changes (see the death
    # handler in step_snake). Nothing here touches save hardware — just a variable.
    high     = save_var :high_score, 0
    self_hit = var :self_hit, 0 # set when the new head lands on the body
    placed   = var :placed, 0   # set once food has found an empty cell

    # The board, in cell coordinates. set_cell / clear_cell take cell numbers and do
    # the pixel arithmetic (and the erase-to-background), so the snake code below
    # never writes `* CELL`. A cleared cell returns to :black, the board's backdrop.
    board = grid :board, cols: COLS, rows: ROWS, cell: CELL, over: :black

    # --- Subroutines ---

    # Pick a random empty cell for the food (it doesn't paint — the caller decides
    # when, since a fresh round clears the screen right after). It tries a handful
    # of random cells and keeps the first that isn't under the snake; the attempts
    # are unrolled here at build time, so each is just one draw from the random
    # stream plus one scan of the body — no loop inside a loop at run time.
    func :spawn_food do
      set :placed, 0
      FOOD_TRIES.times do
        (placed == 0).then do
          roll :food_x, MIN_COL..MAX_COL
          roll :food_y, MIN_ROW..MAX_ROW
          set :placed, 1 # assume it's clear...
          repeat(xs.length) do |i|
            # ...unless a body cell is already sitting there.
            ((xs[i] == :food_x) & (ys[i] == :food_y)).then { set :placed, 0 }
          end
        end
      end
    end

    func :draw_food do
      board.set_cell food_x, food_y, :red
    end

    # Repaint the score field: erase the old digits, then draw the new number. Only
    # called when the score changes (a round start, an eat), so it's cheap.
    func :draw_score do
      dma_fill_rect SCORE_NUM_X, SCORE_Y, SCORE_NUM_W, 7, :black
      draw_number score, SCORE_NUM_X, SCORE_Y, :white, digits: 3
    end

    # Paint the whole board once, at the start of a round: header label, the gray
    # wall frame, the score, the food, and the opening snake (body green, head
    # white). After this, only the changed cells are touched each step.
    func :draw_board do
      clear_screen :black
      draw_text "SCORE", SCORE_LABEL_X, SCORE_Y, :gray
      dma_fill_rect 0, TOP_WALL_Y, SCREEN_W, CELL, :gray            # top wall
      dma_fill_rect 0, BOTTOM_WALL_Y, SCREEN_W, CELL, :gray         # bottom wall
      dma_fill_rect 0, TOP_WALL_Y, CELL, WALL_H, :gray             # left wall
      dma_fill_rect RIGHT_WALL_X, TOP_WALL_Y, CELL, WALL_H, :gray  # right wall
      call :draw_score
      call :draw_food
      repeat(xs.length) do |i|
        board.set_cell xs[i], ys[i], :green
      end
      board.set_cell xs.last, ys.last, :white
    end

    # Start a fresh game: reset the body to the opening snake, face right, zero the
    # score, place the first food, paint the board once, and switch to playing.
    func :new_game do
      # Re-declaring a list empties it — the clean way to start the body over.
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
      # Pick the food cell first, then paint the whole board once (which clears the
      # screen, so the food has to be placed before, not drawn before, the clear).
      call :spawn_food
      call :draw_board
      set :state, 1
    end

    # Advance the snake one cell: commit the buffered turn, work out the new head,
    # and either die, eat, or slide — repainting only the cells that change.
    func :step_snake do
      copy :dx, :ndx
      copy :dy, :ndy
      set :hx, xs.last + dx
      set :hy, ys.last + dy

      # Would the new head land on a cell the body already occupies?
      set :self_hit, 0
      repeat(xs.length) do |i|
        ((xs[i] == :hx) & (ys[i] == :hy)).then { set :self_hit, 1 }
      end

      # Game over if we hit a wall or ourselves. (Landing on the very last tail
      # cell counts too — the simplest "don't touch yourself at all" rule.)
      dead = (hx < MIN_COL) | (hx > MAX_COL) | (hy < MIN_ROW) | (hy > MAX_ROW) | (self_hit == 1)
      dead.then do
        set :state, 2
        beep :die
        # Record a new best. Setting a save_var writes it through to save memory
        # automatically, so the high score is kept even after the power goes off.
        (score > high).then { high.set score }
      end.else do
        # The current head is about to become a body segment — repaint it green.
        board.set_cell xs.last, ys.last, :green
        # Remember the tail cell before we might drop it, so we can erase it.
        set :tail_x, xs.first
        set :tail_y, ys.first
        # Grow a new head at the front of the body, and paint it white.
        xs.push :hx
        ys.push :hy
        board.set_cell hx, hy, :white
        # Eat (keep the tail, so we're one longer) or slide (drop and erase it).
        ((hx == food_x) & (hy == food_y)).then do
          score.add 1
          beep :eat
          call :spawn_food
          call :draw_food
          call :draw_score
        end.else do
          xs.shift
          ys.shift
          board.clear_cell tail_x, tail_y
        end
      end
    end

    # --- Scenes ---

    scene :title do
      clear_screen :black
      draw_text "SNAKE", 105, 56, :green
      draw_text "HIGH", 92, 78, :gray
      draw_number :high_score, 128, 78, :white, digits: 3

      # Flash the prompt on and off twice a second.
      every(0.5, :seconds) { (blink == 1).then { blink.set 0 }.else { blink.set 1 } }
      (blink == 1).then { draw_text "PRESS START", 87, 96, :gray }

      # Keep stirring the random stream while we wait, so the food layout is decided
      # by the player's reaction time — every game plays out a little differently.
      randomize
      pressed(:start).then { call :new_game }
    end

    scene :playing do
      # Steer every frame so turns feel responsive, but only remember the turn —
      # step_snake commits it. A turn is accepted only if it's perpendicular to the
      # current heading, so you can't spin 180° straight into your own neck.
      held(:up).then    { (dy == 0).then { set :ndx, 0; set :ndy, -1 } }
      held(:down).then  { (dy == 0).then { set :ndx, 0; set :ndy, 1 } }
      held(:left).then  { (dx == 0).then { set :ndx, -1; set :ndy, 0 } }
      held(:right).then { (dx == 0).then { set :ndx, 1; set :ndy, 0 } }

      # Move on the beat, not every frame. The board is already on screen from
      # draw_board; step_snake only repaints the handful of cells that change.
      every(STEP) { call :step_snake }
    end

    scene :game_over do
      clear_screen :black
      draw_text "GAME OVER", 93, 52, :red
      draw_text "SCORE", 84, 76, :gray
      draw_number score, 132, 76, :white, digits: 3
      draw_text "HIGH", 84, 90, :gray
      draw_number :high_score, 132, 90, :white, digits: 3

      every(0.5, :seconds) { (blink == 1).then { blink.set 0 }.else { blink.set 1 } }
      (blink == 1).then { draw_text "PRESS START", 87, 110, :gray }

      pressed(:start).then { call :new_game }
    end

    # --- Main loop: pick the scene for the current state, every frame ---
    game_loop do
      wait_vblank

      case_var :state do
        when_val 0, :title
        when_val 1, :playing
        when_val 2, :game_over
      end
    end
  end

  # Build and return the finished ROM. RubyGBA.build runs the guardrails and the
  # ROM-image checks as it goes, so simply calling this exercises them.
  def self.build_rom
    RubyGBA.build("SNAKE", code: "BSNK", maker: "01", &GAME)
  end

  # The IR program on its own — what the headless interpreter runs in tests.
  def self.program
    builder = RubyGBA::Builder.new
    builder.instance_eval(&GAME)
    builder.emit_pending_functions
    builder.program
  end
end

if __FILE__ == $PROGRAM_NAME
  rom = Snake.build_rom
  output = File.join(__dir__, "snake.gba")
  rom.write(output)
  puts "Built snake.gba (#{rom.size} bytes)"

  # Set EXPLAIN=1 to print the per-frame draw/sound-cost breakdown for the ROM —
  # where the frame's work goes, and whether it fits the budget the console has to
  # change the screen without tearing.
  rom.explain if ENV["EXPLAIN"]
end
