# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

class TestFont < Minitest::Test
  include GembaSupport
  F = RubyGBA::Font

  # ========================================================================
  # Font data
  # ========================================================================

  def test_glyph_returns_7_rows
    glyph = F.glyph("A")
    refute_nil glyph
    assert_equal 7, glyph.length
  end

  def test_glyph_case_insensitive
    assert_equal F.glyph("A"), F.glyph("a")
  end

  def test_glyph_unknown_returns_nil
    assert_nil F.glyph("\x01")
  end

  def test_glyph_space_is_blank
    glyph = F.glyph(" ")
    assert glyph.all?(&:zero?), "space glyph should be all zeros"
  end

  def test_all_letters_present
    ("A".."Z").each do |ch|
      refute_nil F.glyph(ch), "missing glyph for #{ch}"
    end
  end

  def test_all_digits_present
    ("0".."9").each do |ch|
      refute_nil F.glyph(ch), "missing glyph for #{ch}"
    end
  end

  # ========================================================================
  # each_pixel
  # ========================================================================

  def test_each_pixel_yields_coordinates
    pixels = []
    F.each_pixel("A") { |x, y| pixels << [x, y] }

    refute_empty pixels
    # All within 5x7 bounds
    pixels.each do |x, y|
      assert_operator x, :>=, 0
      assert_operator x, :<, F::GLYPH_W
      assert_operator y, :>=, 0
      assert_operator y, :<, F::GLYPH_H
    end
  end

  def test_each_pixel_multi_char_offsets
    pixels = []
    F.each_pixel("AB") { |x, y| pixels << [x, y] }

    # B's pixels should start at x=6 (CELL_W)
    b_pixels = pixels.select { |x, _| x >= F::CELL_W }
    refute_empty b_pixels, "B should have pixels offset by CELL_W"
  end

  def test_each_pixel_space_yields_nothing
    pixels = []
    F.each_pixel(" ") { |x, y| pixels << [x, y] }
    assert_empty pixels
  end

  # ========================================================================
  # text_width
  # ========================================================================

  def test_text_width_single_char
    assert_equal 5, F.text_width("A")  # 5px, no trailing gap
  end

  def test_text_width_multi_char
    # "AB" = 5 + 1(gap) + 5 = 11
    assert_equal 11, F.text_width("AB")
  end

  def test_text_width_empty
    assert_equal 0, F.text_width("")
  end

  # ========================================================================
  # draw_text in builder
  # ========================================================================

  def build(validate: false, &block)
    RubyGBA.build("FONTEST", code: "BFNT", maker: "01", validate: validate, &block)
  end

  def test_draw_text_builds
    rom = build do
      screen :bitmap
      draw_text "PONG", 96, 40, :white
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_draw_text_emits_pixels
    # "I" has pixels — the ROM should have more code than just display+halt
    rom = build do
      screen :bitmap
      draw_text "I", 0, 0, :white
      halt
    end

    # Count non-zero instructions in code region
    code_start = RubyGBA::ROM::ENTRY_OFFSET
    inst_count = 0
    offset = code_start
    while offset + 4 <= rom.buffer.bytesize
      word = rom.buffer[offset, 4].unpack1("V")
      break if word == 0
      inst_count += 1
      offset += 4
    end

    # display = ~5 insts, draw_text "I" should add many more, halt = 1
    assert_operator inst_count, :>, 10, "draw_text should emit pixel-writing instructions"
  end

  def test_draw_text_clips_at_screen_edge
    # Text near right edge should not crash
    rom = build do
      screen :bitmap
      draw_text "HELLO", 230, 0, :white
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
