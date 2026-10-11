# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/floating_digits"

# examples/floating_digits.rb built for the desktop shows the interpreter's picture pixel for
# pixel, frame by frame: ten digits, each a picture painted where a list says it is, drifting and
# wrapping round the screen.
class TestFloatingDigitsPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  def test_floating_digits_matches_the_interpreter
    program = Native.new.checked_program(FloatingDigits::GAME, err: nil)

    assert_native_matches_reference program, frames: 60

    pictures = reference_snapshots(program, frames: 60, buttons: {}).map(&:picture)
    assert_operator pictures.uniq.length, :>, 40, "the digits should be somewhere new on most frames compared"
  end
end
