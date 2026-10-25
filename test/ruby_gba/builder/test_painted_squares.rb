# frozen_string_literal: true

require "test_helper"

# A PAINTED SCREEN IN MANY COLOURS. The Advance keeps a colour for every pixel, so a game paints
# in as many as it likes. A Game Boy Color keeps every 8×8 square of its screen in one of eight
# lists of four colours, so a painted screen there can show many colours as long as no square
# needs more than four. These games paint in more than four, a few to a square, and every lowering
# shows them where the interpreter does.
class TestPaintedSquares < Minitest::Test
  # Five colours and black, each in squares of its own along the top row.
  STRIPES = %i[red green blue white yellow].freeze

  private def stripes_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      game_loop do
        clear_screen :black
        STRIPES.each_with_index { |color, i| fill_rect i * 16, 0, 16, 8, color }
      end
    end
    b.finalize_program
    b.program
  end

  # Two scenes, each painting three colours of its own side by side in the same square: six
  # colours there between them, and four at most in either scene.
  WARM = %i[red orange yellow].freeze
  COOL = %i[green blue cyan].freeze

  private def scenes_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      state = var :state, 0
      { warm: WARM, cool: COOL }.each do |name, colors|
        scene name do
          clear_screen :black
          colors.each_with_index { |color, i| fill_rect 8 + (i * 2), 16, 2, 8, color }
        end
      end
      game_loop do
        pressed(:a).then { state.set! 1 }
        case_var :state do
          when_val 0, :warm
          when_val 1, :cool
        end
      end
    end
    b.finalize_program
    b.program
  end

  def test_two_scenes_paint_different_colours_into_the_same_square
    warm = game_player.run(scenes_program, frames: 3).screen
    cool = game_player.input_each_frame { |frame| frame == 3 ? [:a] : [] }.run(scenes_program, frames: 8).screen

    WARM.each_with_index { |color, i| assert_equal Color.resolve(color), warm.pixel(9 + (i * 2), 20), "the warm scene's #{color}" }
    COOL.each_with_index { |color, i| assert_equal Color.resolve(color), cool.pixel(9 + (i * 2), 20), "the cool scene's #{color}" }
  end

  def test_colours_in_squares_of_their_own_show_where_they_were_painted
    screen = game_player.run(stripes_program, frames: 2).screen

    STRIPES.each_with_index do |color, i|
      assert_equal Color.resolve(color), screen.pixel((i * 16) + 3, 4), "the #{color} stripe"
    end
    assert_equal Color.resolve(:black), screen.pixel(100, 4), "black past the last stripe"
  end
end
