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
  GAME = proc do
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

  def self.build_rom
    RubyGBA.build("GRIDCURS", code: "BGRC", maker: "01", &GAME)
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
  rom = GridCursor.build_rom
  output = File.join(__dir__, "grid_cursor.gba")
  rom.write(output)
  puts "Built grid_cursor.gba (#{rom.size} bytes)"

  # Set EXPLAIN=1 to print the per-frame draw/sound-cost breakdown for the ROM —
  # where the frame's work goes, and whether it fits the budget the console has to
  # change the screen without tearing.
  rom.explain if ENV["EXPLAIN"]
end
