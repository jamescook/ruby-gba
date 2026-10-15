# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/meadow").to_s

# examples/meadow.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, through a walk out of the cabin and back: down through the door into the meadow,
# whose map is bigger than any grid the console has, on down the path, right and back left with
# the view following, and up through the door into the cabin again.
class TestMeadowPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  # He is out of the door going into frame 34 and back inside going into frame 192.
  WALK = Ractor.make_shareable(
    NativeComparison.held_for([2..60, :down], [61..110, :right], [111..160, :left], [161..235, :up])
  )

  def test_meadow_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Meadow::GAME, err: nil)
    rooms = reference_snapshots(program, frames: 240, buttons: WALK).map { |moment| moment.variables[:room] }

    last = assert_recorded_run_matches_reference(program, frames: 240, buttons: WALK)

    assert_equal [0, 1, 0], rooms.chunk_while { |a, b| a == b }.map(&:first), "out into the meadow and back in"
    assert_equal 0, last.variables[:view_y], "the view should be the cabin's again"
  end
end
