# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/lake"

# examples/lake.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, for longer than two whole waves take to roll down the water: every row of the water
# at its own place across, and three half see-through jellyfish drifting over it, two of them
# off the right edge and back in at the left.
class TestLakePicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  FRAMES = 140

  # The lake reads no buttons, so there is no run of them to record: it is left alone.
  def test_lake_matches_the_interpreter_through_two_waves
    program = Native.new.checked_program(Lake::GAME, err: nil)
    moments = reference_snapshots(program, frames: FRAMES, buttons: {})

    last = assert_native_matches_reference(program, frames: FRAMES)

    assert_operator last.variables[:phase], :>, Lake::WAVE_ROWS * 2, "the wave should have rolled all the way down twice"
    across = moments.map { |moment| moment.variables.values_at(:__obj2_x, :__obj3_x) }.transpose

    assert(across.all? { |places| places.each_cons(2).any? { |before, after| after < before } },
           "two of the jellyfish should have left at the right and come back in at the left")
  end
end
