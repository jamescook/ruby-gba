# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/grid_cursor"

# examples/grid_cursor.rb built for the desktop shows the interpreter's picture pixel for pixel,
# frame by frame, while the cursor is tapped round the board: left twice, up, down held for two
# frames (one press, so one cell), and up twice more. It ends two cells left of where it began
# and two up.
class TestGridCursorPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  TAPS = Ractor.make_shareable(
    { 3 => %i[left], 5 => %i[left], 8 => %i[up], 11 => %i[down], 12 => %i[down], 15 => %i[up], 17 => %i[up] }
  )

  def test_grid_cursor_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(GridCursor::GAME, err: nil)

    last = assert_native_matches_reference(program, frames: 20, buttons: TAPS)

    untouched = reference_snapshots(program, frames: 20, buttons: {}).last
    assert untouched.picture != last.picture, "the taps should have moved the cursor in the run compared"
  end
end
