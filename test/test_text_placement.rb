# frozen_string_literal: true

require "test_helper"

# SAYING WHERE TEXT GOES WITHOUT COUNTING PIXELS FIRST.
#
# A centred title cannot be a number somebody worked out. A proportional font has no
# per-character width to multiply by, so every such number is wrong by its own amount
# — and it goes stale the moment the label is reworded. The fix is that the left edge
# can be named (:left, :center, :right) and the font is asked how wide the line really
# comes out.
#
# So these assert PIXELS, and they use a font where a wrong measurement shows: "I" is
# one pixel across and "M" is five, so a fixed-grid guess lands in a visibly different
# place from a proportional one.
class TestTextPlacement < Minitest::Test
  Fonts = RubyGBA::Fonts

  WHITE = Color.resolve(:white)
  Y = 40

  # "IM" in the demo font: 1 + a 1px gap + 5. A fixed grid of the font's widest glyph
  # would call it 11 instead, which is what every assertion below can tell apart.
  IM_WIDE = 7
  SCREEN = RubyGBA::IR::Screen::WIDTH

  # A proportional demo font, both glyphs 5 tall, each lighting its leftmost column in
  # every row — so "where does this glyph start" is one pixel to look at.
  def define_demo_font(builder)
    builder.instance_eval do
      font :vari do
        glyph "I", "#\n#\n#\n#\n#"
        glyph "M", "#...#\n##.##\n#.#.#\n#...#\n#...#"
      end
    end
  end

  # Fonts register into a process-global registry; drop any this file defined.
  def teardown
    reg = Fonts.instance_variable_get(:@registry)
    (reg.keys - %i[default tiny]).each { |k| reg.delete(k) }
  end

  # Run a bitmap program with the demo font registered, and hand back its screen.
  def bitmap_screen(&block)
    b = Builder.new
    define_demo_font(b)
    b.instance_eval do
      screen :bitmap
      clear_screen :black
    end
    b.instance_eval(&block)
    b.emit_pending_functions
    Reference.new.run(b.program).screen
  end

  # Every lit pixel of +text+ is painted white with its top-left at (x, y) — an exact
  # position, so a line one pixel out fails.
  def assert_text_at(screen, text, x, y, font: :default)
    lit = []
    Fonts.get(font).each_pixel(text) { |dx, dy| lit << [dx, dy] }
    refute_empty lit, "the font should light some pixels for #{text.inspect}"
    lit.each do |dx, dy|
      assert_equal WHITE, screen.pixel(x + dx, y + dy),
                   "#{text.inspect} pixel (#{dx},#{dy}) should be at (#{x + dx},#{y + dy})"
    end
  end

  # --- the three edges, measured from the font ---------------------------------

  def test_center_puts_the_line_in_the_middle_of_what_the_font_measures
    s = bitmap_screen { draw_text "IM", :center, Y, :white, font: :vari }
    left = (SCREEN - IM_WIDE) / 2

    assert_text_at s, "IM", left, Y, font: :vari
    assert_equal 0, s.pixel(left - 1, Y), "nothing sits left of where the line starts"
    assert_equal 0, s.pixel(left + IM_WIDE, Y), "nor right of where it ends"
  end

  def test_right_puts_the_last_pixel_against_the_right_edge
    s = bitmap_screen { draw_text "IM", :right, Y, :white, font: :vari }

    assert_text_at s, "IM", SCREEN - IM_WIDE, Y, font: :vari
    assert_equal WHITE, s.pixel(SCREEN - 1, Y), "the M's right stroke is the last column"
  end

  def test_left_is_the_left_edge
    s = bitmap_screen { draw_text "IM", :left, Y, :white, font: :vari }

    assert_text_at s, "IM", 0, Y, font: :vari
  end

  # A NUMBER STILL MEANS A NUMBER. Naming an edge is the addition, not a replacement.
  def test_a_column_you_give_is_still_where_it_goes
    s = bitmap_screen { draw_text "IM", 100, Y, :white, font: :vari }

    assert_text_at s, "IM", 100, Y, font: :vari
  end

  # --- what it is placed against ------------------------------------------------

  def test_within_places_it_in_the_columns_you_name
    s = bitmap_screen { draw_text "IM", :center, Y, :white, font: :vari, within: 0..119 }

    assert_text_at s, "IM", (120 - IM_WIDE) / 2, Y, font: :vari
  end

  # A span written either way means the same columns.
  def test_a_span_that_excludes_its_end_names_the_same_columns
    closed = bitmap_screen { draw_text "IM", :right, Y, :white, font: :vari, within: 0..119 }
    open = bitmap_screen { draw_text "IM", :right, Y, :white, font: :vari, within: 0...120 }

    assert_text_at closed, "IM", 120 - IM_WIDE, Y, font: :vari
    assert_text_at open, "IM", 120 - IM_WIDE, Y, font: :vari
  end

  # A HEADING OVER A PANEL centres on the panel, because that is plainly what was
  # meant — an `inside` block already says which part of the screen is being drawn.
  def test_an_inside_block_is_what_center_centres_on
    s = bitmap_screen do
      inside 120, 0, 120, 160 do
        draw_text "IM", :center, Y, :white, font: :vari
      end
    end

    assert_text_at s, "IM", 120 + ((120 - IM_WIDE) / 2), Y, font: :vari
  end

  # --- the built-in font, on the strings that started this ----------------------

  # The jukebox's hand-rolled helper assumed eight pixels a character where the font
  # advances six, so every line of its menu sat left of centre by a different amount.
  def test_a_real_label_lands_where_the_font_says_and_not_where_a_guess_did
    s = bitmap_screen { draw_text "JUKEBOX", :center, Y, :white }
    left = (SCREEN - (7 * 6) + 1) / 2 # 7 characters, 6 apart, no trailing gap

    assert_equal 99, left
    assert_text_at s, "JUKEBOX", left, Y
    refute_equal WHITE, s.pixel(92, Y), "92 is where the old length-times-four guess put it"
  end

  # --- a tiled screen measures the grid its glyphs are laid on ------------------

  # On a tiled screen there are no pixels to plot into: each character is its own
  # little sprite on a fixed grid, one cell apart, so a HUD's columns line up. That is
  # a DIFFERENT width from the same string drawn proportionally, and centring has to
  # use the one the screen will really draw — 11 across here, not 7.
  def test_a_tiled_screen_centres_on_the_grid_not_on_the_proportional_width
    b = Builder.new
    define_demo_font(b)
    b.instance_eval do
      screen :tiled
      draw_text "IM", :center, Y, :white, font: :vari
      game_loop { halt }
    end
    b.emit_pending_functions
    s = Reference.new.run(b.program, max_steps: 500).screen

    cell = Fonts.get(:vari).cell_w
    left = (SCREEN - ((2 * cell) - 1)) / 2
    assert_equal 114, left, "the grid is 11 across, where the proportional line is 7"
    assert_text_at s, "I", left, Y, font: :vari
    assert_text_at s, "M", left + cell, Y, font: :vari
  end

  # --- a number places its FIELD -------------------------------------------------

  # A score that counts up must not jitter sideways as it gains a digit, so what is
  # placed is the field the digits are right-aligned in, not the digits themselves.
  def test_a_number_places_its_field_so_the_ones_column_stays_put
    one_digit = bitmap_screen do
      var :score, 5
      draw_number :score, :center, Y, :white, digits: 3
    end
    two_digits = bitmap_screen do
      var :score, 42
      draw_number :score, :center, Y, :white, digits: 3
    end

    cell = Fonts.get(:default).cell_w
    left = (SCREEN - ((3 * cell) - 1)) / 2
    assert_text_at one_digit, "5", left + (2 * cell), Y
    assert_text_at two_digits, "2", left + (2 * cell), Y
    assert_text_at two_digits, "4", left + cell, Y
  end

  # --- measuring, which is useful on its own ------------------------------------

  def test_text_width_is_what_the_screen_will_really_draw
    measured = []
    b = Builder.new
    define_demo_font(b)
    b.instance_eval do
      screen :bitmap
      measured << text_width("IM", font: :vari)
      measured << text_width("", font: :vari)
      measured << text_height(font: :vari)
    end

    assert_equal [IM_WIDE, 0, 5], measured
  end

  def test_text_width_on_a_tiled_screen_reports_the_grid
    measured = nil
    b = Builder.new
    define_demo_font(b)
    b.instance_eval do
      screen :tiled
      measured = text_width("IM", font: :vari)
    end

    assert_equal 11, measured, "one cell per character, no trailing gap"
  end

  # A box drawn round a label is the reason measuring is worth having on its own.
  def test_a_box_can_be_sized_from_the_words_it_holds
    s = bitmap_screen do
      draw_rect_at 8, Y - 2, text_width("IM", font: :vari) + 4, text_height(font: :vari) + 4, :blue
      draw_text "IM", 10, Y, :white, font: :vari
    end
    blue = Color.resolve(:blue)

    assert_equal blue, s.pixel(8 + IM_WIDE + 3, Y), "the box reaches past the last glyph"
    assert_equal 0, s.pixel(8 + IM_WIDE + 4, Y), "and stops there"
  end

  # --- friendly errors -----------------------------------------------------------

  def test_a_name_the_verb_does_not_know_says_which_names_it_does
    err = assert_raises(ArgumentError) do
      bitmap_screen { draw_text "IM", :middle, Y, :white, font: :vari }
    end

    assert_match(/:center/, err.message)
  end

  def test_a_column_and_a_span_together_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      bitmap_screen { draw_text "IM", 100, Y, :white, font: :vari, within: 0..119 }
    end

    assert_match(/within/, err.message)
  end

  def test_a_span_that_is_not_columns_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      bitmap_screen { draw_text "IM", :center, Y, :white, font: :vari, within: 8 }
    end

    assert_match(/span of columns/, err.message)
  end

  def test_a_number_field_reports_the_same_way
    err = assert_raises(ArgumentError) do
      bitmap_screen { draw_number 5, :middle, Y, :white }
    end

    assert_match(/draw_number/, err.message)
  end

  def test_measuring_something_that_is_not_words_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval { text_width(42) }
    end

    assert_match(/String/, err.message)
  end

  # --- and it lands centred on the real thing ------------------------------------

  def test_centred_text_is_centred_on_hardware
    b = Builder.new
    define_demo_font(b)
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      draw_text "IM", :center, Y, :white, font: :vari
      halt
    end
    b.emit_pending_functions
    rom = ROM.assemble(GBA.new.lower(b.program), title: "CENTER", code: "BCTR", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 2)
    left = (SCREEN - IM_WIDE) / 2

    assert v.white?(left, Y), "the I sits where the font says the line starts"
    assert v.black?(left - 1, Y), "and not one pixel further left"
    assert v.white?(left + 6, Y), "the M's right stroke ends the line"
    assert v.black?(left + IM_WIDE, Y), "with nothing past it"
  end
end
