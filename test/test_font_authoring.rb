# frozen_string_literal: true

require "test_helper"

# `font :name do glyph … end` defines a font from ASCII art, the sibling of `image`.
# These assert a custom font registers, renders its own glyphs (interpreter + gemba),
# and that malformed art is a friendly error.
class TestFontAuthoring < Minitest::Test

  Fonts = RubyGBA::Fonts

  # Fonts register into a process-global registry (the backends look them up there),
  # so drop any a test defined, leaving the built-ins.
  def teardown
    reg = Fonts.instance_variable_get(:@registry)
    (reg.keys - %i[default tiny]).each { |k| reg.delete(k) }
  end

  def interpret(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    Reference.new.run(b.program).screen
  end

  def test_a_font_defined_inline_renders_its_glyphs
    scr = interpret do
      screen :bitmap
      font :box do
        glyph "A", <<~ART
          ###
          #.#
          ###
        ART
      end
      draw_text "A", 10, 10, :white, font: :box
    end
    white = Color.resolve(:white)
    assert_equal white, scr.pixel(10, 10), "top-left of the box"
    assert_equal white, scr.pixel(12, 10), "top-right of the box"
    assert_equal white, scr.pixel(10, 11), "left side"
    assert_equal 0, scr.pixel(11, 11), "the hollow middle"
    assert_equal white, scr.pixel(11, 12), "bottom row"
  end

  def test_the_font_is_registered_under_its_name
    Builder.new.instance_eval do
      screen :bitmap
      font(:mine) { glyph "Z", "#\n#\n#" }
    end
    assert_includes Fonts.names, :mine
    assert_equal 1, Fonts.get(:mine).width
    assert_equal 3, Fonts.get(:mine).height
  end

  # Glyphs may differ in width (that's a proportional font) but must share one
  # height, since every character sits on the same baseline.
  def test_glyphs_of_different_widths_are_allowed
    Builder.new.instance_eval do
      font :prop do
        glyph "I", "#\n#\n#"       # 1 wide
        glyph "M", "###\n###\n###" # 3 wide
      end
    end
    assert_equal 1, Fonts.get(:prop).glyph_width("I")
    assert_equal 3, Fonts.get(:prop).glyph_width("M")
    assert_equal 3, Fonts.get(:prop).width # the widest glyph
  end

  def test_glyphs_of_different_heights_are_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        font :bad do
          glyph "A", "##\n##"     # 2 tall
          glyph "B", "##\n##\n##" # 3 tall
        end
      end
    end
    assert_match(/same height/, err.message)
  end

  def test_ragged_rows_are_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval { font(:bad) { glyph "A", "###\n#" } }
    end
    assert_match(/ragged/, err.message)
  end

  def test_a_font_with_no_glyphs_is_a_friendly_error
    err = assert_raises(ArgumentError) { Builder.new.instance_eval { font(:empty) {} } }
    assert_match(/no glyphs/, err.message)
  end

  def test_font_needs_a_block
    err = assert_raises(ArgumentError) { Builder.new.instance_eval { font(:nope) } }
    assert_match(/needs a block/, err.message)
  end

  def test_a_custom_font_renders_on_hardware
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      font :plus do
        glyph "A", <<~ART
          .#.
          ###
          .#.
        ART
      end
      draw_text "A", 40, 40, :red, font: :plus
      halt
    end
    builder.emit_pending_functions
    rom = ROM.assemble(GBA.new.lower(builder.program), title: "FONTDEF", code: "BFDF", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 2)
    assert v.red?(41, 40), "the plus's top arm"   # (.#.) middle column, row 0
    assert v.red?(40, 41), "the plus's left arm"   # (###) row 1
    assert v.black?(40, 40), "the plus's empty corner"
  end
end
