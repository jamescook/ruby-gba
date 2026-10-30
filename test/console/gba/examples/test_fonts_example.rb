# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/fonts").to_s

# The fonts example: the same number drawn in :default and :tiny. Asserts both
# render, and that the tiny one is genuinely smaller (fewer pixels, shorter box).
class TestFontsExample < Minitest::Test
  GREEN = Color.resolve(:green)

  # Count green pixels in a horizontal band [y, y+h).
  private def green_in_band(screen, y, h)
    n = 0
    240.times { |x| (y...y + h).each { |yy| n += 1 if screen.pixel(x, yy) == GREEN } }
    n
  end

  def test_both_numbers_render_and_tiny_is_smaller
    screen = game_player.run(FontsDemo.program).screen
    default_px = green_in_band(screen, 18, 7) # the default number's 7-tall band
    tiny_px = green_in_band(screen, 54, 5)    # the tiny number's 5-tall band

    assert_operator default_px, :>, 0, "the default-font number should render"
    assert_operator tiny_px, :>, 0, "the tiny-font number should render"
    assert_operator tiny_px, :<, default_px, "the tiny number should plot fewer pixels"
    # the tiny glyphs are only 5 tall — nothing green spills into rows 59..60
    assert_equal 0, green_in_band(screen, 59, 3), "the tiny number should be 5px tall"
  end

  # What the GBA lowering emits for each font, and both numbers drawn on the Advance's cartridge
  # in the emulator, are in test/lowering/gba/examples/test_fonts_example_cartridge.rb.
end
