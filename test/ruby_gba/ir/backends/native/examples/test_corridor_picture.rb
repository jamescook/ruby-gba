# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/corridor").to_s

# examples/corridor.rb built for the desktop shows the interpreter's picture pixel for pixel,
# frame by frame, on a tear-free screen, while the player turns and walks down the corridor: its
# walls are rectangles as tall as the distance says, taller than the screen up close, drawn
# inside the part of the screen above its bar and cut off there.
class TestCorridorPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  # A turn to the left for seven frames, forward for twenty-two (a step is only taken into an
  # empty cell, so a wall may end the walk early), then a turn back to the right for eight.
  WALK = Ractor.make_shareable(
    NativeComparison.held_for([2..8, :left], [9..30, :up], [31..38, :right])
  )

  def test_corridor_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Corridor.default, err: nil)

    assert_recorded_run_matches_reference program, frames: 42, buttons: WALK
  end
end
