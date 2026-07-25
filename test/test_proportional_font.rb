# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Proportional fonts: a glyph carries its own width, so the pen advances by the
# character in front of it — a narrow "I" leaves the next glyph closer than a wide
# "M" would. The proof is positional: render "IM" and check that M lands right after
# the 1-pixel I (plus one gap), not on a fixed max-width grid. A fixed-grid font
# would push M five pixels further right; asserting M's left edge lands at x+2 is
# what distinguishes the two. Checked on the interpreter and on real hardware.
class TestProportionalFont < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Fonts = RubyGBA::Fonts
  Color = RubyGBA::Color

  X = 40 # where the text's top-left sits
  Y = 40

  # A tiny proportional demo font: a 1-pixel-wide "I" and a 5-pixel-wide "M", both 5
  # tall, both with their left column lit in every row (so "where does the glyph
  # start" is a single clear pixel test).
  def define_demo_font(builder)
    builder.instance_eval do
      font :vari do
        glyph "I", <<~ART
          #
          #
          #
          #
          #
        ART
        glyph "M", <<~ART
          #...#
          ##.##
          #.#.#
          #...#
          #...#
        ART
      end
    end
  end

  # Fonts register into a process-global registry; drop any this file defined so
  # they can't leak into other tests, leaving the built-ins.
  def teardown
    reg = Fonts.instance_variable_get(:@registry)
    (reg.keys - %i[default tiny]).each { |k| reg.delete(k) }
  end

  def demo_font
    define_demo_font(Builder.new)
    Fonts.get(:vari)
  end

  # ---- the metrics are per-glyph ----

  def test_each_glyph_carries_its_own_width
    font = demo_font
    assert_equal 1, font.glyph_width("I")
    assert_equal 5, font.glyph_width("M")
    assert_equal 5, font.width # the widest glyph
  end

  def test_text_width_sums_the_glyphs_it_contains
    # I(1) + gap(1) + M(5) = 7, tight — not two max-width cells (which would be 11).
    assert_equal 7, demo_font.text_width("IM")
    assert_equal 1, demo_font.text_width("I")
  end

  # ---- the pen advances by the narrow glyph, on both backends ----

  def interpret_screen(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    Ruby.new.run(b.program).screen
  end

  def test_the_interpreter_advances_by_the_glyphs_width
    scr = interpret_screen do
      screen :bitmap
      clear_screen :black
      font :vari do
        glyph "I", "#\n#\n#\n#\n#"
        glyph "M", "#...#\n##.##\n#.#.#\n#...#\n#...#"
      end
      draw_text "IM", X, Y, :white, font: :vari
    end
    white = Color.resolve(:white)

    assert_equal white, scr.pixel(X, Y),     "the I is drawn at the origin"
    assert_equal 0,     scr.pixel(X + 1, Y), "the 1px I leaves a gap at x+1"
    # The decisive pixel: M's left stroke sits at x+2 (I width + gap), not x+6.
    assert_equal white, scr.pixel(X + 2, Y), "M starts right after the narrow I (proportional)"
    assert_equal white, scr.pixel(X + 6, Y), "M's right stroke — it really is 5 wide"
    assert_equal 0,     scr.pixel(X + 7, Y), "nothing is drawn past M"
  end

  def test_the_hardware_advances_by_the_glyphs_width
    builder = Builder.new
    define_demo_font(builder)
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      draw_text "IM", X, Y, :white, font: :vari
      halt
    end
    builder.emit_pending_functions
    rom = ROM.assemble(GBA.new.lower(builder.program), title: "VARIFNT", code: "BVRF", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 2)

    assert v.white?(X, Y),          "the I is drawn at the origin"
    assert v.black?(X + 1, Y),      "the 1px I leaves a gap at x+1"
    assert v.white?(X + 2, Y),      "M starts right after the narrow I (proportional)"
    assert v.white?(X + 6, Y),      "M's right stroke — it really is 5 wide"
    assert v.black?(X + 7, Y),      "nothing is drawn past M"
  end

  # ---- the off-screen guardrail measures the proportional box ----

  # "IM" is 7px wide (1 + gap + 5). Placed at x = -8 its whole 7px box is left of
  # the screen, so the guardrail warns. A font that wrongly measured two max-width
  # cells (11px) would think the box still reached x = 3 — on-screen — and stay
  # silent. The warning is proof the box summed the glyphs' own widths.
  def test_the_off_screen_guardrail_measures_the_proportional_width
    define_demo_font(Builder.new) # register :vari
    prog = RubyGBA::IR::Build.program(RubyGBA::IR::Build.draw_text("IM", -8, 40, :white, font: :vari))
    off = RubyGBA::IR::Guardrails::Validator.new.run(prog, autofix: false)
                                            .findings.select { |f| f.check == :off_screen_draw }
    assert_equal 1, off.size, "the 7px-wide 'IM' at x=-8 is entirely off the left edge"
  end

  # ---- run-time digits pick the DIGIT width, not the font's widest glyph ----

  # A proportional font whose ten digits are a uniform 3px but whose widest glyph is
  # a 5px "W". The data-driven digit path (a run-time score) must measure the digits'
  # own 3px, not the font's 5px max — read the 3-bit glyph rows as 5 bits and every
  # digit renders shifted and garbled. Only hardware exercises that loop (the
  # interpreter always reads a glyph at its own width), so this is a gemba check:
  # the run-time digit must match the same digit drawn as fixed text.
  def register_hud_font
    wide_w = [0b10001, 0b10001, 0b10101, 0b11011, 0b10001] # 5 wide, 5 tall
    glyphs = RubyGBA::Font::TINY_GLYPHS.merge("W" => wide_w) # tiny's digits are 3 wide
    widths = glyphs.keys.to_h { |k| [k, k == "W" ? 5 : 3] }
    Fonts.register(:hud, RubyGBA::Font.new(glyphs: glyphs, widths: widths, height: 5))
  end

  def test_data_driven_digits_render_at_the_digit_width_on_hardware
    register_hud_font
    assert_equal 5, Fonts.get(:hud).width      # the widest glyph (W)
    assert_equal 3, Fonts.get(:hud).glyph_width("7") # but a digit is 3

    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      var :n, 7
      draw_number :n, 40, 20, :white, digits: 1, font: :hud # live -> data-driven loop
      draw_number 7,  40, 40, :white, digits: 1, font: :hud # fixed -> draw_text "7" unroll
    end
    builder.emit_pending_functions
    rom = ROM.assemble(GBA.new.lower(builder.program), title: "HUDNUM", code: "BHDN", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 4)

    (0...3).each do |dx|
      (0...5).each do |dy|
        assert_equal v.pixel_gba(40 + dx, 40 + dy), v.pixel_gba(40 + dx, 20 + dy),
                     "live vs fixed digit differ at (#{dx}, #{dy}) — wrong digit width in the loop?"
      end
    end
  end
end
