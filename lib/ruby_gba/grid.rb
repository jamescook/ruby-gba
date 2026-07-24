# frozen_string_literal: true

module RubyGBA
  # A board of equal-sized cells you paint one at a time — a game field measured in
  # cells, not pixels. `grid :board, cols:, rows:, cell:, over:` hands one back; from
  # then on the game talks in cell coordinates (0, 1, 2 …) and never multiplies by
  # the cell size. That "* cell" and the erase-to-background trick — the fiddly
  # arithmetic a tile game like Snake otherwise hand-rolls — live here instead.
  #
  #   board = grid :board, cols: 30, rows: 20, cell: 8, over: :black
  #   board.set_cell   head_x, head_y, :white   # paint one cell (cell coords)
  #   board.set_cell   old_x,  old_y,  :green    # the old head becomes a body cell
  #   board.clear_cell tail_x, tail_y            # a vacated cell goes back to `over`
  #
  # Painting a single cell (rather than clearing and redrawing the whole board every
  # frame) is what keeps the picture from tearing once the board fills up: only a
  # handful of cells change each step, and a handful always fits in the brief safe
  # window the display gives you to draw in.
  #
  # `over:` is the background color a cell returns to — a grid is a flat field, so
  # `clear_cell` simply fills the cell with it. (A moving object over *scenery*
  # wants the sprite helper instead, which remembers and restores the pixels it
  # covers; a grid's cells never overlap, so a plain fill is all it needs.)
  class Grid
    Build = IR::Build

    # @param builder [Builder] the build these cell paints record into
    # @param name [Symbol] the board's name (for messages)
    # @param cols [Integer] columns across
    # @param rows [Integer] rows down
    # @param cell [Integer] a cell's size in pixels (even, so the fast fill is legal)
    # @param over [Symbol, String, Integer] the background color a cleared cell shows
    def initialize(builder, name:, cols:, rows:, cell:, over:)
      @builder = builder
      @name = name
      @cols = whole_positive!(cols, :cols)
      @rows = whole_positive!(rows, :rows)
      @cell = even_cell!(cell)
      @over = over
    end

    attr_reader :name, :cols, :rows, :cell

    # Paint one cell in a color. Coordinates are in cells; a coordinate may be a
    # constant or a run-time variable/expression (a moving piece).
    def set_cell(col, row, color)
      paint(col, row, color)
    end

    # Return one cell to the background — fill it with the grid's `over` color.
    def clear_cell(col, row)
      paint(col, row, @over)
    end

    private

    # Fill the one cell at (col, row) with a color, in cell coordinates. It lowers
    # to a run-time-positioned rectangle the size of a cell — the same primitive a
    # hand-written `draw_rect_at col * cell, row * cell, cell, cell` would build, so
    # a grid inherits its clipping, cost, and guardrails for free.
    def paint(col, row, color)
      in_range!(col, :col, @cols)
      in_range!(row, :row, @rows)
      @builder.draw_rect_at(pixel(col), pixel(row), @cell, @cell, color)
    end

    # A cell coordinate as a pixel position. A constant folds to a plain number; a
    # run-time coordinate becomes `coord * cell`, multiplied on the console.
    def pixel(coord)
      return coord * @cell if coord.is_a?(Integer)

      Build.binop(:*, Value.node_for(coord), Build.int(@cell))
    end

    # Only a literal coordinate can be range-checked as the program is written; a
    # run-time coordinate is trusted (and clips at the screen edge if it strays,
    # like any other draw). Catching the common typo — a constant off the board —
    # here turns a silent bad write into a plain-language error.
    def in_range!(coord, axis, count)
      return unless coord.is_a?(Integer)
      return if (0...count).cover?(coord)

      raise ArgumentError,
            "#{axis} #{coord} is off the #{@name.inspect} grid — valid #{axis}s are 0..#{count - 1}"
    end

    def whole_positive!(value, field)
      return value if value.is_a?(Integer) && value.positive?

      raise ArgumentError, "grid :#{@name} needs a positive #{field}, got #{value.inspect}"
    end

    # A cell must be an even number of pixels: the fast rectangle fill writes two
    # pixels at a time, so an odd width can't be filled that way.
    def even_cell!(cell)
      unless cell.is_a?(Integer) && cell.positive?
        raise ArgumentError, "grid :#{@name} needs a positive cell size, got #{cell.inspect}"
      end
      return cell if cell.even?

      raise ArgumentError, "grid :#{@name} cell size must be even (got #{cell}) so a cell can fast-fill"
    end
  end
end
