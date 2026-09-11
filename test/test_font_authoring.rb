# frozen_string_literal: true

require "test_helper"

# `font :name do glyph … end` defines a font from ASCII art, the sibling of `image`.
# These assert a custom font registers, renders its own glyphs (interpreter + the emulator),
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
    assert_match(/needs glyphs/, err.message)
  end

  # The other door: a font that already exists as pictures. Nobody retypes an
  # alphabet as hashes and dots, so glyphs can be handed over as rows of pixels —
  # what a sheet slices into, and what a game's own packed art decodes to.
  def test_a_font_can_be_given_as_glyph_pictures
    scr = interpret do
      screen :bitmap
      font :box, glyphs: { "A" => [[9, 9, 9], [9, 0, 9], [9, 9, 9]] }
      draw_text "A", 10, 10, :white, font: :box
    end
    white = Color.resolve(:white)
    assert_equal white, scr.pixel(10, 10), "top-left of the box"
    assert_equal white, scr.pixel(12, 12), "bottom-right of the box"
    assert_equal 0, scr.pixel(11, 11), "the hollow middle"
  end

  # A pixel is lit when it is not the blank one, whatever value it holds — a font is
  # one colour, so which ink a picture used never matters.
  def test_a_picture_says_which_value_is_blank
    Builder.new.instance_eval do
      font :inked, glyphs: { "I" => [[7, 3], [3, 7]] }, blank: 3
    end
    assert_equal [0b10, 0b01], Fonts.get(:inked).glyph("I")
  end

  def test_pictured_glyphs_keep_their_own_widths
    Builder.new.instance_eval do
      font :prop, glyphs: { "I" => [[1], [1]], "M" => [[1, 1, 1], [1, 0, 1]] }
    end
    assert_equal 1, Fonts.get(:prop).glyph_width("I")
    assert_equal 3, Fonts.get(:prop).glyph_width("M")
  end

  def test_pictured_glyphs_of_different_heights_are_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval { font :bad, glyphs: { "A" => [[1]], "B" => [[1], [1]] } }
    end
    assert_match(/same height/, err.message)
  end

  def test_a_font_cannot_be_given_both_ways
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval { font(:both, glyphs: { "A" => [[1]] }) { glyph "A", "#" } }
    end
    assert_match(/not both/, err.message)
  end

  # The other screen kind: a tiled screen has no framebuffer, so the console draws
  # each character as a little sprite glyph. An imported font is picked there the
  # same way, with the same font: argument.
  def test_a_pictured_font_renders_on_a_tiled_screen
    b = Builder.new
    b.instance_eval do
      screen :tiled
      font :corner, glyphs: { "A" => [[1, 0], [0, 0]] }
      draw_text "A", 100, 20, :white, font: :corner
      game_loop do
        wait_vblank
        halt
      end
    end
    b.emit_pending_functions
    s = Reference.new.run(b.program, max_steps: 500).screen
    assert_equal Color.resolve(:white), s.pixel(100, 20), "the one lit corner of the glyph"
  end

  # A tiled screen draws a glyph as one 8x8 sprite, so an imported alphabet can be
  # too big for it — usually because of one or two wide characters, which is what the
  # error names.
  def test_a_glyph_too_wide_for_a_tiled_screen_names_the_character
    err = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :tiled
        font :wide, glyphs: { "I" => [[1]], "W" => [Array.new(12, 1)] }
        draw_text "W", 10, 10, :white, font: :wide
      end
    end
    assert_match(/"W"/, err.message)
    assert_match(/12/, err.message)
  end

  # A pictured font renders the same as a typed-in one, on the console as well.
  def test_a_pictured_font_renders_on_hardware
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      font :plus, glyphs: { "A" => [[0, 1, 0], [1, 1, 1], [0, 1, 0]] }
      draw_text "A", 40, 40, :red, font: :plus
      halt
    end
    builder.emit_pending_functions
    rom = ROM.assemble(GBA.new.lower(builder.program), title: "FONTPIC", code: "BFPC", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 2)
    assert v.red?(41, 40), "the plus's top arm"
    assert v.red?(40, 41), "the plus's left arm"
    assert v.black?(40, 40), "the plus's empty corner"
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
    v = assert_emulator_loads_rom(rom, frames: 2)
    assert v.red?(41, 40), "the plus's top arm"   # (.#.) middle column, row 0
    assert v.red?(40, 41), "the plus's left arm"   # (###) row 1
    assert v.black?(40, 40), "the plus's empty corner"
  end
end
