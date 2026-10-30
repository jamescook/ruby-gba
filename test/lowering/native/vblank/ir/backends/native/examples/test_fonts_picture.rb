# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require VBlank.root.join("examples/fonts").to_s

# examples/fonts.rb built for the desktop shows the interpreter's picture pixel for pixel: words
# and a number in the two built-in fonts, drawn once by a program that then stops, so every lit
# pixel of every letter is compared.
class TestFontsPicture < Minitest::Test
  include NativeComparison

  def test_fonts_matches_the_interpreter
    program = Native.new.checked_program(FontsDemo::GAME, err: nil)

    last = assert_native_matches_reference(program)

    assert_operator last.picture.uniq.length, :>, 1, "the picture compared should have text on it"
  end
end
