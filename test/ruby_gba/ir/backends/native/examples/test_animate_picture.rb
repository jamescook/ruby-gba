# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/animate"

# examples/animate.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, while its spinning coin — a sprite on a painted screen, which saves what is under it
# and puts it back — is walked right and then down. The frames of the spin change on the same
# frames in both.
class TestAnimatePicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  WALK = Ractor.make_shareable(NativeComparison.held_for([2..15, :right], [16..30, :down]))

  def test_animate_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Animate::GAME, err: nil)

    assert_recorded_run_matches_reference program, frames: 34, buttons: WALK
  end
end
