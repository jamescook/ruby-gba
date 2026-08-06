# frozen_string_literal: true

require "test_helper"

require_relative "../examples/font_styles"

# The font-styles example: the same word in three fonts, two defined inline with
# `font :name do glyph … end`. Asserts each renders in its own colour, that the two
# custom fonts really are different (distinct glyph pixels), and that it renders on
# gemba.
class TestFontStylesExample < Minitest::Test

  # The lit pixels of the word band drawn at (8, y), height h — relative coords.
  def word_pixels(screen, y, h, color)
    want = Color.resolve(color)
    pixels = []
    60.times { |dx| h.times { |dy| pixels << [dx, dy] if screen.pixel(8 + dx, y + dy) == want } }
    pixels
  end

  def screen
    @screen ||= Reference.new.run(FontStyles.program).screen
  end

  def test_each_font_renders_in_its_own_colour
    refute_empty word_pixels(screen, 12, 7, :white), "default HELLO should render"
    refute_empty word_pixels(screen, 40, 5, :green), "lowercase hello should render"
    refute_empty word_pixels(screen, 64, 5, :cyan), "script hello should render"
  end

  def test_the_two_custom_fonts_are_distinct
    lower = word_pixels(screen, 40, 5, :green)
    script = word_pixels(screen, 64, 5, :cyan)
    refute_empty lower
    refute_empty script
    refute_equal lower.to_set, script.to_set, "the lowercase and script fonts should draw different glyphs"
  end

  def test_the_custom_fonts_are_shorter_than_the_default
    # :lower / :script are 5 tall; nothing green spills below their band.
    assert_empty word_pixels(screen, 45, 3, :green), "the lowercase font should be 5px tall"
  end

  def test_it_renders_on_hardware
    rom = ROM.assemble(GBA.new.lower(FontStyles.program), title: "FONTSTY", code: "BFSY", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 3)
    assert (8..60).any? { |x| (12..18).any? { |y| v.white?(x, y) } }, "default HELLO missing on hardware"
    assert (8..60).any? { |x| (40..44).any? { |y| v.green?(x, y) } }, "lowercase hello missing on hardware"
    assert (8..60).any? { |x| (64..68).any? { |y| v.pixel_is?(x, y, :cyan) } }, "script hello missing on hardware"
  end
end
