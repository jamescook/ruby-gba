# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/tiles").to_s

# examples/tiles.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, through a walk round its three rooms: the door in the hall opened, on to the cavern
# and the meadow, a step further that there is no room for, and back to the hall, where the door
# is shut again because the room came back as declared. There the door is shut once more, which
# changes nothing, and then opened.
class TestTilesPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  # Each button is a tap, since the example reads the press and not the hold.
  WALK = Ractor.make_shareable(
    NativeComparison.held_for([3..4, :a], [8..9, :right], [14..15, :right], [20..21, :right],
                              [26..27, :left], [32..33, :left], [38..39, :b], [44..45, :a])
  )

  # The door's cell, in pixels: column 10, row 9 of the map.
  DOOR = (9 * 8 * WIDTH) + (10 * 8)

  def test_tiles_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Tiles::GAME, err: nil)
    moments = reference_snapshots(program, frames: 50, buttons: WALK)
    door = moments.map { |moment| moment.picture[DOOR] }

    last = assert_recorded_run_matches_reference(program, frames: 50, buttons: WALK)

    assert_equal 0, last.variables[:where], "the walk should end back in the hall"
    assert_equal door[5], door.last, "with the door open, as it was after the first press"
    refute_equal door[5], door[36], "having been shut when the hall came back"
  end
end
