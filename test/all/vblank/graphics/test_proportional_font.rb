# frozen_string_literal: true

require "test_helper"

# The font these tests draw with, shared with the Advance cartridge's own tests of the same
# letters (test/lowering/gba/vblank/graphics/test_proportional_font_cartridge.rb).
module ProportionalFontGames
  include SharedConstants

  Fonts = VBlank::Graphics::Fonts

  X = 40 # where the text's top-left sits
  Y = 40

  # A tiny proportional demo font: a 1-pixel-wide "I" and a 5-pixel-wide "M", both 5
  # tall, both with their left column lit in every row (so "where does the glyph
  # start" is a single clear pixel test).
  private def define_demo_font(builder)
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

  # A font belongs to the program that declared it, so read it back off that program
  # rather than from anywhere shared.
  private def demo_font
    builder = Builder.new
    define_demo_font(builder)
    builder.program.fonts.get(:vari)
  end
end

# Proportional fonts: a glyph carries its own width, so the pen advances by the
# character in front of it — a narrow "I" leaves the next glyph closer than a wide
# "M" would. The proof is positional: render "IM" and check that M lands right after
# the 1-pixel I (plus one gap), not on a fixed max-width grid. A fixed-grid font
# would push M five pixels further right; asserting M's left edge lands at x+2 is
# what distinguishes the two. Checked here on every run, and on the Advance's cartridge in
# test/lowering/gba/vblank/graphics/test_proportional_font_cartridge.rb.
class TestProportionalFont < Minitest::Test
  include ProportionalFontGames

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

  private def interpret_screen(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    game_player.run(b.program).screen
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

  # ---- the off-screen guardrail measures the proportional box ----

  # "IM" is 7px wide (1 + gap + 5). Placed at x = -8 its whole 7px box is left of
  # the screen, so the guardrail warns. A font that wrongly measured two max-width
  # cells (11px) would think the box still reached x = 3 — on-screen — and stay
  # silent. The warning is proof the box summed the glyphs' own widths.
  def test_the_off_screen_guardrail_measures_the_proportional_width
    prog = VBlank::IR::Build.program(VBlank::IR::Build.font(:vari, demo_font),
                                      VBlank::IR::Build.draw_text("IM", -8, 40, :white, font: :vari))
    off = VBlank::IR::Guardrails::Validator.new.run(prog, autofix: false)
                                            .findings.select { |f| f.check == :off_screen_draw }
    assert_equal 1, off.size, "the 7px-wide 'IM' at x=-8 is entirely off the left edge"
  end
end
