# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# A font is a named collection of glyphs plus metrics; the Fonts registry hands out
# fonts by name and a draw picks one. These cover the default 5x7 font's glyph data
# and layout, and the registry / a second font.
class TestFont < Minitest::Test
  include GembaSupport

  Fonts = RubyGBA::Fonts
  Font = RubyGBA::Font
  F = RubyGBA::Fonts.default # the built-in 5x7 uppercase font

  # ---- glyph data (the default font) ----

  def test_glyph_returns_7_rows
    glyph = F.glyph("A")
    refute_nil glyph
    assert_equal 7, glyph.length
  end

  def test_glyph_folds_to_uppercase
    assert_equal F.glyph("A"), F.glyph("a") # the default font is uppercase-only
  end

  def test_glyph_unknown_returns_nil
    assert_nil F.glyph("\x01")
  end

  def test_all_letters_and_digits_present
    (("A".."Z").to_a + ("0".."9").to_a).each { |ch| refute_nil F.glyph(ch), "missing glyph for #{ch}" }
  end

  # ---- each_pixel / metrics ----

  def test_each_pixel_stays_within_the_glyph_box
    pixels = []
    F.each_pixel("A") { |x, y| pixels << [x, y] }
    refute_empty pixels
    pixels.each do |x, y|
      assert_includes 0...F.width, x
      assert_includes 0...F.height, y
    end
  end

  def test_each_pixel_advances_by_the_cell_width
    pixels = []
    F.each_pixel("AB") { |x, _y| pixels << x }
    assert (pixels.max >= F.cell_w), "B's pixels should be offset by one cell width"
  end

  def test_space_draws_nothing
    pixels = []
    F.each_pixel(" ") { |x, y| pixels << [x, y] }
    assert_empty pixels
  end

  def test_text_width
    assert_equal 5, F.text_width("A")   # one glyph, no trailing gap
    assert_equal 11, F.text_width("AB") # 5 + 1 gap + 5
    assert_equal 0, F.text_width("")
  end

  # ---- the registry ----

  def test_default_and_tiny_are_registered
    assert_includes Fonts.names, :default
    assert_includes Fonts.names, :tiny
    assert_same F, Fonts.get(:default)
  end

  def test_unknown_font_is_a_friendly_error
    err = assert_raises(ArgumentError) { Fonts.get(:nope) }
    assert_match(/nope/, err.message)
    assert_match(/font/, err.message)
  end

  def test_a_registered_font_can_be_fetched
    mine = Font.new(glyphs: { "X" => [0b111, 0b010, 0b111] }, width: 3, height: 3)
    Fonts.register(:test_custom, mine)
    assert_same mine, Fonts.get(:test_custom)
  ensure
    Fonts.instance_variable_get(:@registry).delete(:test_custom)
  end

  # ---- the tiny font is genuinely smaller ----

  def test_tiny_font_has_different_metrics
    tiny = Fonts.get(:tiny)
    assert_equal 3, tiny.width
    assert_equal 5, tiny.height
    assert_operator tiny.text_width("42"), :<, F.text_width("42")     # narrower
    assert_operator tiny.text_pixels("8"), :<, F.text_pixels("8")     # fewer lit pixels
  end

  # ---- draw_text through the builder ----

  def build(validate: false, &block)
    RubyGBA.build("FONTEST", code: "BFNT", maker: "01", validate: validate, &block)
  end

  def test_draw_text_builds_and_emits_pixels
    rom = build do
      screen :bitmap
      draw_text "I", 0, 0, :white
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_draw_text_runs_in_mgba
    rom = build do
      screen :bitmap
      clear_screen :black
      draw_text "PONG", 96, 40, :white
      draw_text "PRESS START", 64, 100, :gray
      halt
    end
    assert_gemba_loads_rom(rom, frames: 5)
  end
end
