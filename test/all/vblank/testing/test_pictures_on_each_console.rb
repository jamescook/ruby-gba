# frozen_string_literal: true

require "test_helper"

# The picture check plays the cartridge of the console the program is built for: a program
# built for the Game Boy Color is played as a Color cartridge, on the Color's smaller screen,
# and its picture held to the interpreter's pixel for pixel, the same as an Advance program's.
#
# The check plays a cartridge beside the interpreter only on the interpreter's run (every other
# run compares its own lowered game instead), so the tests that play one are in
# test/interpreter/vblank/testing/test_pictures_on_each_console_interpreter.rb.
class TestPicturesOnEachConsole < Minitest::Test
  include VBlank::Testing::Pictures

  COLOR = VBlank::Console::COLOR

  # A Color picture that differs says where on the Color's screen, in a map of the whole of it.
  def test_a_difference_on_the_colors_screen_is_mapped_over_that_screen
    width = COLOR.screen_width
    oracle = Array.new(width * COLOR.screen_height, 0)
    console = oracle.dup
    console[((COLOR.screen_height - 1) * width) + width - 1] = Color.resolve(:red)

    report = mismatch_message(mismatched_pixels(oracle, console), 4, 6, picture: oracle)

    assert_match(/1 of 23040 pixels differ/, report)
    map = report.lines.grep(/^ {4}[.#]+$/)
    assert_equal [40, 18], [map.first.strip.length, map.size]
    assert map.last.strip.end_with?("#"), "the last row's last cell"
  end
end
