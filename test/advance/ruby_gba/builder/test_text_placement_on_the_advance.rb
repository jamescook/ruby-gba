# frozen_string_literal: true

require "test_helper"

# The test of test_text_placement.rb that puts a line against the right edge of the Advance's
# screen, 240 pixels across, so it plays on the Advance's runs alone. The game is built for
# the Advance, and on a Game Boy Color's screen, 160 across, that edge is off the picture.
class TestTextPlacementOnTheAdvance < Minitest::Test
  WHITE = Color.resolve(:white)
  Y = 40

  # "IM" in the demo font: 1 + a 1px gap + 5.
  IM_WIDE = 7
  SCREEN = RubyGBA::IR::Screen::WIDTH

  # A proportional demo font, both glyphs 5 tall, each lighting its leftmost column in
  # every row — so "where does this glyph start" is one pixel to look at.
  private def define_demo_font(builder)
    builder.instance_eval do
      font :vari do
        glyph "I", "#\n#\n#\n#\n#"
        glyph "M", "#...#\n##.##\n#.#.#\n#...#\n#...#"
      end
    end
  end

  private attr_reader :built

  # Run a bitmap program that declares the demo font, and hand back its screen.
  private def bitmap_screen(&block)
    b = Builder.new
    define_demo_font(b)
    b.instance_eval do
      screen :bitmap
      clear_screen :black
    end
    b.instance_eval(&block)
    b.finalize_program
    @built = b.program
    game_player.run(@built).screen
  end

  # Every lit pixel of +text+ is painted white with its top-left at (x, y).
  private def assert_text_at(screen, text, x, y, font: :default)
    lit = []
    built.fonts.get(font).each_pixel(text) { |dx, dy| lit << [dx, dy] }
    refute_empty lit, "the font should light some pixels for #{text.inspect}"
    lit.each do |dx, dy|
      assert_equal WHITE, screen.pixel(x + dx, y + dy),
                   "#{text.inspect} pixel (#{dx},#{dy}) should be at (#{x + dx},#{y + dy})"
    end
  end

  def test_right_puts_the_last_pixel_against_the_right_edge
    s = bitmap_screen { draw_text "IM", :right, Y, :white, font: :vari }

    assert_text_at s, "IM", SCREEN - IM_WIDE, Y, font: :vari
    assert_equal WHITE, s.pixel(SCREEN - 1, Y), "the M's right stroke is the last column"
  end
end
