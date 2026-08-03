#!/usr/bin/env ruby
# frozen_string_literal: true

# Grid cursor — a single lit cell you steer around a board with the d-pad, leaving
# no trail behind it.
#
# It shows what `grid` is for. The screen is carved into a board of equal cells,
# and the game talks in *cell* coordinates (column 0, 1, 2 …) — never pixels. Each
# tap moves the cursor one cell: it erases the cell it's leaving with `clear_cell`
# and paints the cell it arrives at with `set_cell`, so only two cells ever change.
# There's no "* cell size" arithmetic and no whole-screen redraw — the same
# incremental, tear-safe move a tile game like Snake makes, but spelled out plainly.
#
# Run it to build examples/grid_cursor.gba:
#   ruby examples/grid_cursor.rb

require_relative "../lib/ruby_gba"

module GridCursor
  CELL = 8              # an 8x8 cell (even, so a cell can fast-fill)
  COLS = 240 / CELL     # 30 cells across the screen
  ROWS = 160 / CELL     # 20 cells down

  # The game as a block the builder runs, so a test can drive the exact program
  # that ships — the headless interpreter runs THIS, the console runs the ROM.
  GAME = RubyGBA.game("GRIDCURS", code: "BGRC", maker: "01") do
    screen :bitmap
    clear_screen :black

    # The board: a field of black cells. `over: :black` is the color a cell returns
    # to when it's cleared, so the cursor leaves no trail.
    board = grid :board, cols: COLS, rows: ROWS, cell: CELL, over: :black

    # The cursor's cell, starting in the middle. It's just two variables counted in
    # cells; the board turns them into pixels.
    cx = var :cx, COLS / 2
    cy = var :cy, ROWS / 2
    board.set_cell cx, cy, :cyan

    game_loop do
      wait_vblank

      # Move one cell per tap. Each step is the incremental dance: rub out the cell
      # we're on, step the coordinate, keep it on the board, then light the cell we
      # land on. Two cells change and the picture never tears.
      step = proc do |axis, delta, last|
        board.clear_cell cx, cy
        axis.add delta
        axis.clamp 0, last
        board.set_cell cx, cy, :cyan
      end

      pressed(:left).then  { step.call(cx, -1, COLS - 1) }
      pressed(:right).then { step.call(cx,  1, COLS - 1) }
      pressed(:up).then    { step.call(cy, -1, ROWS - 1) }
      pressed(:down).then  { step.call(cy,  1, ROWS - 1) }
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

GridCursor::GAME.write_if_main
