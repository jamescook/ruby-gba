# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/font_styles").to_s

# examples/font_styles.rb built for the desktop shows the interpreter's picture pixel for pixel:
# the same words in fonts the example draws for itself, so every lit pixel of every letter is
# compared.
class TestFontStylesPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  def test_font_styles_matches_the_interpreter
    program = Native.new.checked_program(FontStyles::GAME, err: nil)

    last = assert_native_matches_reference(program)

    assert_operator last.picture.uniq.length, :>, 1, "the picture compared should have text on it"
  end
end
