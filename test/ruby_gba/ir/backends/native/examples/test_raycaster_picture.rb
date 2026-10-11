# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/raycaster"

# examples/raycaster.rb built for the desktop shows the interpreter's picture pixel for pixel,
# frame by frame, on a tear-free screen, while the player turns left, walks forward and turns
# right: every ray's distance is worked out in fractions and every wall is a rectangle as tall as
# that distance says, so arithmetic a hair out moves a wall's edge.
class TestRaycasterPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  WALK = Ractor.make_shareable(
    NativeComparison.held_for([2..10, :left], [11..30, :up], [31..40, :right])
  )

  def test_raycaster_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Raycaster::GAME, err: nil)

    assert_recorded_run_matches_reference program, frames: 44, buttons: WALK
  end
end
