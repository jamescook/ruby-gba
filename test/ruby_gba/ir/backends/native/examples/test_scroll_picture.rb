# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/scroll"

# examples/scroll.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, while the window is panned over the world: left and up from where it starts, which
# takes it below nought and round to the world's far side each way, then right and down back
# through the start and on.
class TestScrollPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  PAN = Ractor.make_shareable(
    NativeComparison.held_for([2..30, :left], [31..60, :up], [61..130, :right], [131..200, :down])
  )

  def test_scroll_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Scroll::GAME, err: nil)

    last = assert_recorded_run_matches_reference(program, frames: 210, buttons: PAN)

    assert_equal [82, 80], last.variables.values_at(:__bg_world_sx, :__bg_world_sy),
                 "the window should end right of and below where it started, having been left of and above it"
  end
end
