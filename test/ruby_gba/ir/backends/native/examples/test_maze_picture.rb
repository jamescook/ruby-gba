# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/maze"

# examples/maze.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, while the hero is pushed at the maze's walls: right until a wall stops him, then
# down, left and up, each held long enough to run into one. Which cells stop him is read off the
# map, so a wall in the wrong place shows as the hero a cell out.
class TestMazePicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  PUSH = Ractor.make_shareable(
    NativeComparison.held_for([2..40, :right], [41..80, :down], [81..100, :left], [101..120, :up])
  )

  def test_maze_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Maze::GAME, err: nil)

    last = assert_native_matches_reference(program, frames: 124, buttons: PUSH)

    untouched = reference_snapshots(program, frames: 124, buttons: {}).last
    assert untouched.picture != last.picture, "the walk should have moved the hero in the run compared"
  end
end
