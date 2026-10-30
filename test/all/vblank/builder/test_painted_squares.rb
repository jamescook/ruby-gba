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

  # A scene that does not clear the screen keeps the picture the scene before it left, and paints
  # over it: here a green pixel into the square the first scene painted red and orange. Green, blue
  # and cyan side by side elsewhere give the second scene a list of colours of its own, which a
  # square of nothing but black and green would share if the first scene's red and orange were
  # forgotten there.
  private def kept_picture_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      state = var :state, 0
      scene :first do
        clear_screen :black
        fill_rect 8, 16, 2, 8, :red
        fill_rect 10, 16, 2, 8, :orange
      end
      scene :second do
        pixel 15, 23, :green
        %i[green blue cyan].each_with_index { |color, i| fill_rect 40 + (i * 2), 40, 2, 8, color }
      end
      game_loop do
        pressed(:a).then { state.set! 1 }
        case_var :state do
          when_val 0, :first
          when_val 1, :second
        end
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_scene_paints_over_the_picture_the_scene_before_it_left
    screen = game_player.input_each_frame { |frame| frame == 3 ? [:a] : [] }.run(kept_picture_program, frames: 8).screen

    assert_equal Color.resolve(:red), screen.pixel(9, 20), "the first scene's red is still there"
    assert_equal Color.resolve(:orange), screen.pixel(11, 20), "and its orange"
    assert_equal Color.resolve(:green), screen.pixel(15, 23), "with the second scene's green beside them"
  end

  # A scene run inside another, on the same pass: the inner one clears the screen and paints green
  # into a square, with a list of its own along the top row, which the build comes to first, and
  # the outer one, once it is back, paints red and orange beside the green.
  private def nested_scenes_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      inner = var :inner, 0
      scene :inner do
        clear_screen :black
        pixel 15, 23, :green
        %i[green blue cyan].each_with_index { |color, i| fill_rect 40 + (i * 2), 0, 2, 8, color }
      end
      scene :outer do
        case_var(:inner) { when_val 0, :inner }
        fill_rect 8, 16, 2, 8, :red
        fill_rect 10, 16, 2, 8, :orange
      end
      game_loop { case_var(:state) { when_val 0, :outer } }
      inner.set! 0
    end
    b.finalize_program
    b.program
  end

  def test_a_scene_inside_another_paints_beside_what_that_one_painted
    screen = game_player.run(nested_scenes_program, frames: 4).screen

    assert_equal Color.resolve(:red), screen.pixel(9, 20), "the outer scene's red"
    assert_equal Color.resolve(:orange), screen.pixel(11, 20), "and its orange"
    assert_equal Color.resolve(:green), screen.pixel(15, 23), "with the inner scene's green beside them"
  end

  # A paddle at a row written in the program reaches only that row of squares, so the three
  # colours side by side above it leave room for nothing else and still fit.
  private def paddle_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      paddle = var :paddle, 40
      game_loop do
        clear_screen :black
        %i[red green blue].each_with_index { |color, i| fill_rect 8 + (i * 2), 16, 2, 4, color }
        draw_rect_at paddle, 130, 24, 4, :white
        paddle.add! 1
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_colour_at_a_row_written_in_the_program_reaches_only_that_row
    screen = game_player.run(paddle_program, frames: 3).screen

    assert_equal Color.resolve(:green), screen.pixel(10, 17), "the green above"
    assert_equal Color.resolve(:white), screen.pixel(50, 131), "the paddle below"
  end

  # A ball, placed as the game runs, crosses a row of three colours: wherever it is, its square
  # holds black, white and one of the three.
  private def ball_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      ball = var :ball, 0
      game_loop do
        clear_screen :black
        %i[red green blue].each_with_index { |color, i| fill_rect i * 8, 40, 8, 8, color }
        draw_rect_at ball, 42, 4, 4, :white
        ball.add! 3
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_colour_placed_as_the_game_runs_shows_in_every_square_it_reaches
    screen = game_player.run(ball_program, frames: 4).screen

    assert_includes [Color.resolve(:white)], screen.pixel(10, 43), "the ball over the green"
    assert_equal Color.resolve(:blue), screen.pixel(20, 43), "the blue it has not reached"
  end

  def test_colours_in_squares_of_their_own_show_where_they_were_painted
    screen = game_player.run(stripes_program, frames: 2).screen

    STRIPES.each_with_index do |color, i|
      assert_equal Color.resolve(color), screen.pixel((i * 16) + 3, 4), "the #{color} stripe"
    end
    assert_equal Color.resolve(:black), screen.pixel(100, 4), "black past the last stripe"
  end
end
