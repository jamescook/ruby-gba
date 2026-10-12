# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/buffered_bounce"

# examples/buffered_bounce.rb built for the desktop shows the interpreter's picture pixel for
# pixel, frame by frame, on a tear-free screen: two pictures shown in turn, each repainted whole,
# with its three balls somewhere new on every one.
class TestBufferedBouncePicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  def test_buffered_bounce_matches_the_interpreter
    program = Native.new.checked_program(BufferedBounce::GAME, err: nil)

    assert_native_matches_reference program, frames: 60

    assert_operator different_pictures_in(program, frames: 60), :>, 40,
                    "the balls should be somewhere new on most frames compared"
  end
end
