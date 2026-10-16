# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/pixels").to_s

# examples/pixels.rb built for the desktop shows the interpreter's picture pixel for pixel: a
# flag, three dots and the four corner markers, drawn once by a program with no game loop that
# then stops.
class TestPixelsPicture < Minitest::Test
  include NativeComparison

  def test_pixels_matches_the_interpreter
    program = Native.new.checked_program(Pixels, err: nil)

    last = assert_native_matches_reference(program)

    %i[white red yellow cyan magenta].each do |name|
      assert_includes last.picture, Color.resolve(name), "#{name} should be in the picture compared"
    end
  end
end
