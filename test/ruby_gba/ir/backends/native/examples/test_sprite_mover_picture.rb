# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/sprite_mover"

# examples/sprite_mover.rb built for the desktop shows the interpreter's picture pixel for pixel,
# frame by frame, while its heart is walked left, down and right across a painted field with
# posts on it — in front of one post and behind another, which is the order its layers say.
class TestSpriteMoverPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  WALK = Ractor.make_shareable(
    NativeComparison.held_for([2..40, :left], [41..60, :down], [61..90, :right])
  )

  def test_sprite_mover_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(SpriteMover::GAME, err: nil)

    assert_recorded_run_matches_reference program, frames: 94, buttons: WALK
  end
end
