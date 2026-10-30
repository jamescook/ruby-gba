# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require VBlank.root.join("examples/grid_cursor").to_s

# examples/grid_cursor.rb built for the desktop shows the interpreter's picture pixel for pixel,
# frame by frame, while the cursor is tapped round the board in all four directions. A button
# held for two frames is one press, so one cell.
class TestGridCursorPicture < Minitest::Test
  include NativeComparison

  # Left three times and right once, up twice, down held for two frames, and up again: two cells
  # left of where it began, and two up.
  TAPS = Ractor.make_shareable(
    { 3 => %i[left], 5 => %i[left], 7 => %i[left], 9 => %i[right], 11 => %i[up], 13 => %i[up],
      15 => %i[down], 16 => %i[down], 18 => %i[up] }
  )

  def test_grid_cursor_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(GridCursor::GAME, err: nil)

    last = assert_native_matches_reference(program, frames: 22, buttons: TAPS)

    # The game as C is the Advance's, whose board is 30 cells by 20: the middle is (15, 10).
    assert_equal [13, 8], last.variables.values_at(:cx, :cy)
  end
end
