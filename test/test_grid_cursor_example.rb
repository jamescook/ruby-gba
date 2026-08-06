# frozen_string_literal: true

require "test_helper"

require_relative "../examples/grid_cursor"

# The grid-cursor example: a single lit cell steered around a board with the d-pad,
# leaving no trail. It's the worked demonstration of `grid` — the game moves in
# cell coordinates, and each tap erases the old cell and paints the new one. These
# assert BEHAVIOR (the cursor lights the right cell and leaves nothing behind) on
# the interpreter, plus a gemba check that it renders and steers on the console.
class TestGridCursorExample < Minitest::Test
  include RubyGBA::Constants

  CELL = GridCursor::CELL
  # The cursor starts in the middle cell; these are its top-left pixels.
  START_COL = GridCursor::COLS / 2
  START_ROW = GridCursor::ROWS / 2
  START_PX = START_COL * CELL
  START_PY = START_ROW * CELL

  def assert_cell_is(screen, col, row, color)
    want = Color.resolve(color)
    CELL.times do |dy|
      CELL.times do |dx|
        px = col * CELL + dx
        py = row * CELL + dy
        assert_equal want, screen.pixel(px, py), "cell (#{col},#{row}) pixel (#{px},#{py}) not #{color}"
      end
    end
  end

  def test_the_cursor_starts_lit_in_the_middle
    screen = Reference.new.run(GridCursor.program, max_steps: 200).screen
    assert_cell_is screen, START_COL, START_ROW, :cyan
  end

  def test_a_tap_moves_the_cursor_one_cell_and_leaves_no_trail
    # Tap :left once (a single down-edge on frame 3), then let it settle.
    screen = Reference.new
                 .input_each_frame { |f| f == 3 ? [:left] : [] }
                 .run(GridCursor.program, max_steps: 3000).screen

    assert_cell_is screen, START_COL - 1, START_ROW, :cyan   # arrived one cell left
    assert_cell_is screen, START_COL, START_ROW, :black      # left cell behind, no trail
  end

  def test_the_cursor_stays_on_the_board_at_the_edge
    # Hold :left is one tap (pressed fires on the edge only), so a single press can
    # never walk it off the board — and neither can many, thanks to the clamp.
    i = Reference.new
            .input_each_frame { |f| f.even? ? [:left] : [] } # a tap every other frame
            .run(GridCursor.program, max_steps: 20_000)
    assert_operator i[:cx], :>=, 0, "cursor walked off the left edge"
  end

  def test_it_builds_a_rom
    rom = GridCursor.build_rom
    assert rom.size.positive?
  end

  def test_it_renders_and_steers_on_hardware
    rom = ROM.assemble(GBA.new.lower(GridCursor.program), title: "GRIDCURS", code: "BGRC", maker: "01")
    # Hold left: one down-edge, so the cursor steps one cell left and lights it.
    v = assert_gemba_loads_rom(rom, frames: 6, keys: KEY_LEFT)
    left_px = START_PX - CELL
    assert v.pixel_is?(left_px + 2, START_PY + 2, :cyan),
           "cursor didn't light the cell left of center — got #{v.pixel_gba(left_px + 2, START_PY + 2).to_s(16)}"
    assert v.black?(START_PX + 2, START_PY + 2), "the start cell should be erased (no trail)"
  end
end
