# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/maze").to_s

# examples/maze.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, while the hero is pushed at the maze's walls: right, down, left and up, each held
# until a wall has stopped him and for some frames after. Which cells stop him is read off the
# map, so a wall in the wrong place shows as the hero a cell out.
class TestMazePicture < Minitest::Test
  include NativeComparison

  # He is stopped by the pillar to his right after eight frames, by the bottom wall sixty-four
  # frames into the second leg, by the left wall eight into the third, and by the top wall
  # sixty-eight into the last; each leg is held past that.
  PUSH = Ractor.make_shareable(
    NativeComparison.held_for([2..40, :right], [41..115, :down], [116..140, :left], [141..215, :up])
  )

  def test_maze_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Maze::GAME, err: nil)

    assert_recorded_run_matches_reference program, frames: 220, buttons: PUSH
  end
end
