# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/floating_digits"

# examples/floating_digits.rb built for the desktop shows the interpreter's picture pixel for
# pixel, frame by frame: ten digits, each a picture painted where its own two variables say it
# is, drifting across the screen and bouncing off its edges.
class TestFloatingDigitsPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  def test_floating_digits_matches_the_interpreter
    program = Native.new.checked_program(FloatingDigits::GAME, err: nil)

    assert_native_matches_reference program, frames: 60

    assert_operator different_pictures_in(program, frames: 60), :>, 40,
                    "the digits should be somewhere new on most frames compared"
  end
end
