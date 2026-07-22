# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# draw_number: draw a score/counter, live or fixed, right-aligned with no leading
# zeros. It renders each digit through the same font as draw_text, so the test of
# correctness is "the digits it draws are the glyphs draw_text would draw" — the
# runtime digit machinery must land the same pixels as the trusted text path, in
# the interpreter and on real hardware.
class TestDrawNumber < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  W = Builder::Text::GLYPH_WIDTH # 6px per digit column

  def interpret_screen(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    Ruby.new.run(builder.program).screen
  end

  def tree(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  # Assert two horizontal bands of pixels are identical — the way to say "these
  # rendered the same glyphs" without pinning exact font pixels.
  def assert_bands_match(screen, x:, w:, y1:, y2:, h: 7)
    h.times do |dy|
      w.times do |dx|
        a = screen.pixel(x + dx, y1 + dy)
        b = screen.pixel(x + dx, y2 + dy)
        assert_equal a, b, "pixel (#{x + dx}, #{y1 + dy}) != (#{x + dx}, #{y2 + dy})"
      end
    end
  end

  def assert_region_is(screen, x, y, w, h, color)
    want = Color.resolve(color)
    h.times do |dy|
      w.times { |dx| assert_equal want, screen.pixel(x + dx, y + dy), "(#{x + dx},#{y + dy}) not #{color}" }
    end
  end

  # ---- the digits it draws are the glyphs draw_text would draw ----

  def test_a_live_number_renders_its_digits
    # score 42 in a 4-wide field is right-aligned, so it starts one column in
    # (thousands blank), i.e. at x + 2*W. draw_text "42" placed there is the oracle.
    screen = interpret_screen do
      display :bitmap
      clear_screen :black
      var :score, 42
      draw_number :score, 40, 20, :white, digits: 4
      draw_text "42", 40 + 2 * W, 40, :white
    end
    assert_bands_match(screen, x: 40 + 2 * W, w: 2 * W, y1: 20, y2: 40)
  end

  def test_a_middle_zero_is_kept
    # 102 must show its middle zero (only *leading* zeros are dropped).
    screen = interpret_screen do
      display :bitmap
      clear_screen :black
      var :score, 102
      draw_number :score, 40, 20, :white, digits: 4
      draw_text "102", 40 + 1 * W, 40, :white
    end
    assert_bands_match(screen, x: 40 + 1 * W, w: 3 * W, y1: 20, y2: 40)
  end

  def test_an_expression_is_evaluated
    screen = interpret_screen do
      display :bitmap
      clear_screen :black
      score = var :score, 41
      draw_number score + 1, 40, 20, :white, digits: 4
      draw_text "42", 40 + 2 * W, 40, :white
    end
    assert_bands_match(screen, x: 40 + 2 * W, w: 2 * W, y1: 20, y2: 40)
  end

  # ---- natural, not zero-padded ----

  def test_leading_columns_are_blank_not_zero
    screen = interpret_screen do
      display :bitmap
      clear_screen :black
      var :score, 5
      draw_number :score, 40, 20, :white, digits: 4
      draw_text "5", 40 + 3 * W, 40, :white # the ones column
    end
    # the three leading columns show background, not "000"
    assert_region_is(screen, 40, 20, 3 * W, 7, :black)
    # and the ones column is a real "5"
    assert_bands_match(screen, x: 40 + 3 * W, w: W, y1: 20, y2: 40)
  end

  def test_zero_shows_a_zero
    screen = interpret_screen do
      display :bitmap
      clear_screen :black
      var :score, 0
      draw_number :score, 40, 20, :white, digits: 4
      draw_text "0", 40 + 3 * W, 40, :white
    end
    assert_region_is(screen, 40, 20, 3 * W, 7, :black) # no leading zeros
    assert_bands_match(screen, x: 40 + 3 * W, w: W, y1: 20, y2: 40)
  end

  # ---- guardrails ----

  def test_draw_text_rejects_a_number
    err = assert_raises(ArgumentError) { tree { draw_text 42, 0, 0, :white } }
    assert_match(/draw_number/, err.message)
  end

  def test_draw_number_rejects_a_non_number
    err = assert_raises(ArgumentError) { tree { draw_number "42", 0, 0, :white } }
    assert_match(/draw_number draws a number/, err.message)
  end

  def test_draw_number_rejects_a_bad_digit_count
    err = assert_raises(ArgumentError) { tree { draw_number :score, 0, 0, :white, digits: 0 } }
    assert_match(/positive number of digits/, err.message)
  end

  # ---- the runtime digits land on real hardware ----

  def hw_program
    tree do
      display :bitmap
      clear_screen :black
      var :score, 42
      draw_number :score, 40, 20, :white, digits: 4 # live path
      draw_number 42, 40, 40, :white, digits: 4     # the same number, folded to glyphs
    end
  end

  def test_live_number_matches_the_literal_on_hardware
    rom = ROM.assemble(GBA.new.lower(hw_program), title: "DRAWNUM", code: "BDNM", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 4)

    # The live digit extraction must land the same pixels as the folded literal.
    (0...(4 * W)).each do |dx|
      (0...7).each do |dy|
        assert_equal v.pixel_gba(40 + dx, 20 + dy), v.pixel_gba(40 + dx, 40 + dy),
                     "hardware: live vs literal differ at column offset #{dx}, row #{dy}"
      end
    end
  end
end
