#!/usr/bin/env ruby
# frozen_string_literal: true

# Snake — the classic, built entirely with the VBlank DSL.
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
# The title and game-over screens work the same way: each is painted once as the game
# arrives at it, and after that only the blinking "PRESS START" is erased and drawn
# again. Nothing else on them changes, so nothing else is painted twice.
#
# --- One game, every screen size ---
# The board is laid out from the screen the game is built for (`screen_width`,
# `screen_height`), so it fills the Game Boy Advance's 240x160 and the Super
# Nintendo's 256x224 alike: 30x20 cells on one, 32x28 on the other.
#
# Run it to build examples/snake.gba and examples/snake.sfc:
#   ruby examples/snake.rb

require_relative "../lib/vblank"

# Everything lives under Snake so the file is safe to `require` from a test
# (requiring it just defines the module; only running it directly writes a ROM).
module Snake
  # --- Build-time constants (plain Ruby, resolved before any code is emitted) ---

  # The play area is a grid of square cells. The snake and the food snap to it, so
  # positions are counted in cells (0, 1, 2 …); a `grid` (built below) turns those
  # cell coordinates into pixels, so nothing here multiplies by CELL by hand.
  CELL = 8                     # an 8x8 cell (draw widths must be even, and 8 is)

  # The top two rows are a header for the score; a one-cell gray wall frames the
  # rest. The snake lives in the interior, between the walls.
  HEADER_ROWS = 2

  # Header score readout: a fixed "SCORE" label and a three-digit field one gap beyond
  # it. Where the field starts is asked of the font rather than counted, so rewording
  # the label moves the figures with it (see `score_num_x` in the build).
  SCORE_LABEL_X = 8
  SCORE_GAP     = 12           # between the label and the figures
  SCORE_Y       = 4
  SCORE_NUM_W   = 3 * 6        # three 6px digit columns — even, as a fill width must be

  # The title and game-over screens put a label and its number either side of the
  # middle — the word pushed up against it from the left, the figures from the right of
  # it — so a pair meets in the middle whatever the words are.
  STAT_GAP    = 6

  # How tall the blinking prompt's line is, which is what is erased when it blinks off.
  PROMPT_H = 8

  STEP = 6                     # frames between moves — the snake steps ~10x a second

  FOOD_TRIES = 8               # random cells to try when placing food off the snake

  # WHERE EVERYTHING GOES on a screen +width+ by +height+ pixels: worked out once, from
  # the screen the game is built for.
  Layout = Data.define(:width, :height) do
    def cols = width / CELL    # 30 cells across on the Advance
    def rows = height / CELL   # 20 cells down on the Advance

    def min_col = 1                   # just inside the left wall (column 0)
    def max_col = cols - 2            # just inside the right wall
    def min_row = HEADER_ROWS + 1     # just below the top wall
    def max_row = rows - 2            # just above the bottom wall

    # Pixel geometry of the wall frame (all fixed, so it draws with dma_fill_rect).
    def top_wall_y = HEADER_ROWS * CELL       # top wall sits just under the header
    def bottom_wall_y = (rows - 1) * CELL     # bottom wall on the last row
    def right_wall_x = (cols - 1) * CELL      # right wall on the last column
    def wall_h = height - top_wall_y          # how tall the side walls are

    def stat_label = (0...(width / 2))
    def stat_number = (((width / 2) + STAT_GAP)...width)

    # The interior holds at most this many cells, so a body list this long can never
    # overflow. It opens at four cells and grows one per apple, so a played game spends
    # its time far below that. The build also measures each scene with the body held at
    # its capacity, and would warn if a full board did not keep up. It does: the body is
    # walked once a step, not once a frame.
    def body_cap = (max_col - min_col + 1) * (max_row - min_row + 1)

    # The snake starts as a short horizontal run in the middle, heading right. The
    # body is ordered tail-first, so the last cell is the head.
    def start_row = (min_row + max_row) / 2
    def start_cells = [[5, start_row], [6, start_row], [7, start_row], [8, start_row]]
  end

  # The whole game, as a block the builder runs. Keeping it in one place means the
  # test drives the exact program that ships: the headless interpreter runs THIS to
  # check the game plays without crashing, and the console runs the ROM built from it.
  GAME = VBlank.game("SNAKE", consoles: %i[gba snes]) do
    screen :bitmap
    enable_sound
    here = Layout.new(width: screen_width, height: screen_height)

    # Where the score's figures start: one gap past the end of the word, whatever the
    # word is. The font is the only thing that knows how wide "SCORE" comes out.
    score_num_x = SCORE_LABEL_X + text_width("SCORE") + SCORE_GAP

    # Short blips: a bright one for eating, a low one for dying.
    define_sound :eat, frequency: 880, duty: :quarter, decay: :fast
    define_sound :die, frequency: 140, duty: :half, decay: :medium

    # --- The body: two parallel lists, one entry per cell (xs[i], ys[i]) ---
    xs = list :xs, capacity: here.body_cap
    ys = list :ys, capacity: here.body_cap

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
    painted  = var :painted, 0  # 1 once the title or game-over screen showing is painted

    # The board, in cell coordinates. set_cell / clear_cell take cell numbers and do
    # the pixel arithmetic (and the erase-to-background), so the snake code below
    # never writes `* CELL`. A cleared cell returns to :black, the board's backdrop.
    board = grid :board, cols: here.cols, rows: here.rows, cell: CELL, over: :black

    # --- Subroutines ---

    # Pick a random empty cell for the food (it doesn't paint — the caller decides
    # when, since a fresh round clears the screen right after). It tries a handful
    # of random cells and keeps the first that isn't under the snake; the attempts
    # are unrolled here at build time, so each is just one draw from the random
    # stream plus one scan of the body — no loop inside a loop at run time.
    func :spawn_food do
      set! :placed, 0
      FOOD_TRIES.times do
        (placed == 0).then do
          roll :food_x, here.min_col..here.max_col
          roll :food_y, here.min_row..here.max_row
          set! :placed, 1 # assume it's clear...
          repeat(xs.length) do |i|
            # ...unless a body cell is already sitting there.
            ((xs[i] == :food_x) & (ys[i] == :food_y)).then { set! :placed, 0 }
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
      dma_fill_rect score_num_x, SCORE_Y, SCORE_NUM_W, 7, :black
      draw_number score, score_num_x, SCORE_Y, :white, digits: 3
    end

    # Paint the whole board once, at the start of a round: header label, the gray
    # wall frame, the score, the food, and the opening snake (body green, head
    # white). After this, only the changed cells are touched each step.
    func :draw_board do
      clear_screen :black
      draw_text "SCORE", SCORE_LABEL_X, SCORE_Y, :gray
      dma_fill_rect 0, here.top_wall_y, here.width, CELL, :gray                  # top wall
      dma_fill_rect 0, here.bottom_wall_y, here.width, CELL, :gray               # bottom wall
      dma_fill_rect 0, here.top_wall_y, CELL, here.wall_h, :gray                 # left wall
      dma_fill_rect here.right_wall_x, here.top_wall_y, CELL, here.wall_h, :gray # right wall
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
      list :xs, capacity: here.body_cap
      list :ys, capacity: here.body_cap
      here.start_cells.each do |cx, cy|
        xs.push cx
        ys.push cy
      end
      set! :dx, 1
      set! :dy, 0
      set! :ndx, 1
      set! :ndy, 0
      set! :score, 0
      # Pick the food cell first, then paint the whole board once (which clears the
      # screen, so the food has to be placed before, not drawn before, the clear).
      call :spawn_food
      call :draw_board
      set! :state, 1
      painted.set! 0 # the game-over screen, when it comes, is painted afresh
    end

    # Advance the snake one cell: commit the buffered turn, work out the new head,
    # and either die, eat, or slide — repainting only the cells that change.
    func :step_snake do
      copy! :dx, :ndx
      copy! :dy, :ndy
      set! :hx, xs.last + dx
      set! :hy, ys.last + dy

      # Would the new head land on a cell the body already occupies?
      set! :self_hit, 0
      repeat(xs.length) do |i|
        ((xs[i] == :hx) & (ys[i] == :hy)).then { set! :self_hit, 1 }
      end

      # Game over if we hit a wall or ourselves. (Landing on the very last tail
      # cell counts too — the simplest "don't touch yourself at all" rule.)
      dead = (hx < here.min_col) | (hx > here.max_col) | (hy < here.min_row) | (hy > here.max_row) | (self_hit == 1)
      dead.then do
        set! :state, 2
        beep :die
        # Record a new best. Setting a save_var writes it through to save memory
        # automatically, so the high score is kept even after the power goes off.
        (score > high).then { high.set! score }
      end.else do
        # The current head is about to become a body segment — repaint it green.
        board.set_cell xs.last, ys.last, :green
        # Remember the tail cell before we might drop it, so we can erase it.
        set! :tail_x, xs.first
        set! :tail_y, ys.first
        # Grow a new head at the front of the body, and paint it white.
        xs.push :hx
        ys.push :hy
        board.set_cell hx, hy, :white
        # Eat (keep the tail, so we're one longer) or slide (drop and erase it).
        ((hx == food_x) & (hy == food_y)).then do
          score.add! 1
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

    # The blinking prompt at +y+: its own rectangle erased, then drawn again if it is on.
    # Run when a screen is painted, and each time the prompt blinks — never in between,
    # since nothing else there changes. (The words' width rounded up to even, as a fill
    # width must be, and centred as the words are.)
    prompt_w = (text_width("PRESS START") + 1) & ~1
    prompt = lambda do |y|
      dma_fill_rect (here.width - prompt_w) / 2, y, prompt_w, PROMPT_H, :black
      (blink == 1).then { draw_text "PRESS START", :center, y, :gray }
    end

    # Flash the prompt on and off twice a second, painting only its line.
    blink_prompt = lambda do |y|
      every(0.5, :seconds) do
        (blink == 1).then { blink.set! 0 }.else { blink.set! 1 }
        prompt.call(y)
      end
    end

    scene :title do
      # Painted once, as the game arrives here: nothing on it changes but the prompt.
      (painted == 0).then do
        clear_screen :black
        draw_text "SNAKE", :center, 56, :green
        draw_text "HIGH", :right, 78, :gray, within: here.stat_label
        draw_number :high_score, :left, 78, :white, digits: 3, within: here.stat_number
        prompt.call(96)
        painted.set! 1
      end
      blink_prompt.call(96)

      # Keep stirring the random stream while we wait, so the food layout is decided
      # by the player's reaction time — every game plays out a little differently.
      randomize
      pressed(:start).then { call :new_game }
    end

    scene :playing do
      # Steer every frame so turns feel responsive, but only remember the turn —
      # step_snake commits it. A turn is accepted only if it's perpendicular to the
      # current heading, so you can't spin 180° straight into your own neck.
      held(:up).then    { (dy == 0).then { set! :ndx, 0; set! :ndy, -1 } }
      held(:down).then  { (dy == 0).then { set! :ndx, 0; set! :ndy, 1 } }
      held(:left).then  { (dx == 0).then { set! :ndx, -1; set! :ndy, 0 } }
      held(:right).then { (dx == 0).then { set! :ndx, 1; set! :ndy, 0 } }

      # Move on the beat, not every frame. The board is already on screen from
      # draw_board; step_snake only repaints the handful of cells that change.
      every(STEP) { call :step_snake }
    end

    scene :game_over do
      # Painted once, as the game arrives here (new_game said it is not painted yet).
      (painted == 0).then do
        clear_screen :black
        draw_text "GAME OVER", :center, 52, :red
        draw_text "SCORE", :right, 76, :gray, within: here.stat_label
        draw_number score, :left, 76, :white, digits: 3, within: here.stat_number
        draw_text "HIGH", :right, 90, :gray, within: here.stat_label
        draw_number :high_score, :left, 90, :white, digits: 3, within: here.stat_number
        prompt.call(110)
        painted.set! 1
      end
      blink_prompt.call(110)

      pressed(:start).then { call :new_game }
    end

    # --- Main loop: pick the scene for the current state, every frame ---
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

Snake::GAME.write_if_main
