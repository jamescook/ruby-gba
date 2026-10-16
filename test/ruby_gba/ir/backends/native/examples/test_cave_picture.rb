# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/cave").to_s

# examples/cave.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, while the hero walks the cave with the lantern on them, out of the cave mouth, through
# the circle closing and opening, across the meadow, and back in at its left edge through the
# circle again. The lantern is a lit span on every row and the rest darkened, worked out before
# each frame from where the hero stands, so a span a column out, or darkened by a step too few,
# shows on the first frame of the walk.
class TestCavePicture < Minitest::Test
  include NativeComparison

  # Right from the start along the mouth's row and out of it at frame 210 or so; the circle shuts
  # and opens on the meadow; down and up a little in daylight; then left to the meadow's edge,
  # which closes the circle again and opens it on the cave with the lantern lit.
  WALK = Ractor.make_shareable(
    NativeComparison.held_for([2..240, :right], [281..290, :down], [291..300, :up], [301..330, :left],
                              [380..400, :up])
  )

  def test_cave_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Cave::GAME, err: nil)

    assert_recorded_run_matches_reference program, frames: 420, buttons: WALK
  end
end
