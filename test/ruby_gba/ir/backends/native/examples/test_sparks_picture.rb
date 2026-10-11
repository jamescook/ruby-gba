# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/sparks"

# examples/sparks.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, for long enough that every slot of its pool of sparks has been used and the oldest
# are being given up for new ones. Each spark rolls its own random numbers, so one walked out of
# order shows as a spark somewhere else.
class TestSparksPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  def test_sparks_matches_the_interpreter_once_the_pool_is_full
    program = Native.new.checked_program(Sparks::GAME, err: nil)

    last = assert_native_matches_reference(program, frames: Sparks::SLOTS * 4)

    assert_includes last.picture, Color.resolve(:yellow), "sparks should be in the last picture compared"
  end
end
