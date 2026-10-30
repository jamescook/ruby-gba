# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/grid_cursor").to_s

# Where the cursor starts, shared with the Advance cartridge's own tests of the example
# (test/lowering/gba/examples/test_grid_cursor_example_cartridge.rb).
module GridCursorPlaces
  include VBlank::Console::Hardware

  CELL = GridCursor::CELL
  # The cursor starts in the middle cell; these are its top-left pixels.
  START_COL = SCREEN_WIDTH / CELL / 2
  START_ROW = SCREEN_HEIGHT / CELL / 2
  START_PX = START_COL * CELL
  START_PY = START_ROW * CELL
end

# The grid-cursor example: a single lit cell steered around a board with the d-pad,
# leaving no trail. It's the worked demonstration of `grid` — the game moves in
# cell coordinates, and each tap erases the old cell and paints the new one. These
# assert BEHAVIOR (the cursor lights the right cell and leaves nothing behind) on
# every run that plays the Advance's games; the cartridge it builds, rendering and steering in
# the emulator, is in test/lowering/gba/examples/test_grid_cursor_example_cartridge.rb.
class TestGridCursorExample < Minitest::Test
  include GridCursorPlaces

  private def assert_cell_is(screen, col, row, color)
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
    screen = game_player.run(GridCursor.program, max_steps: 200).screen
    assert_cell_is screen, START_COL, START_ROW, :cyan
  end

  def test_a_tap_moves_the_cursor_one_cell_and_leaves_no_trail
    # Tap :left once (a single down-edge on frame 3), then let it settle.
    screen = game_player
                 .input_each_frame { |f| f == 3 ? [:left] : [] }
                 .run(GridCursor.program, max_steps: 3000).screen

    assert_cell_is screen, START_COL - 1, START_ROW, :cyan   # arrived one cell left
    assert_cell_is screen, START_COL, START_ROW, :black      # left cell behind, no trail
  end

  def test_the_cursor_stays_on_the_board_at_the_edge
    # Hold :left is one tap (pressed fires on the edge only), so a single press can
    # never walk it off the board — and neither can many, thanks to the clamp.
    i = game_player
            .input_each_frame { |f| f.even? ? [:left] : [] } # a tap every other frame
            .run(GridCursor.program, max_steps: 20_000)
    assert_operator i[:cx], :>=, 0, "cursor walked off the left edge"
  end
end
