# frozen_string_literal: true

require "test_helper"

# Each 8×8 square of a painted Game Boy Color screen is drawn from one list of four colours, chosen
# when the cartridge is made (GBC::SquareColors). A program whose painting could put a fifth colour
# in a square is refused then, naming the square, rather than showing a colour wrong as it runs.
class TestGBCPaintedSquares < Minitest::Test
  GBC = RubyGBA::IR::Backends::GBC

  def test_five_colours_painted_into_one_square_are_refused_naming_the_square
    error = assert_raises(GBC::LoweringError) do
      GBC.new.build(color_program do
        screen :bitmap
        game_loop do
          clear_screen :black
          %i[red green blue white].each_with_index { |color, i| fill_rect 8 + (i * 2), 16, 2, 4, color }
        end
      end)
    end

    assert_match(/square of the screen from \(8, 16\) to \(15, 23\)/, error.message)
    assert_match(/5 colours: :black, :red, :green, :blue, :white/, error.message)
  end

  # Where the ball is, the build cannot know, so its colour can be in any square: three colours
  # side by side in one square leave no room for it.
  def test_a_colour_painted_where_the_game_works_out_counts_in_every_square
    error = assert_raises(GBC::LoweringError) do
      GBC.new.build(color_program do
        screen :bitmap
        ball = var :ball, 40
        game_loop do
          clear_screen :black
          %i[red green blue].each_with_index { |color, i| fill_rect 8 + (i * 2), 16, 2, 4, color }
          draw_rect_at ball, ball, 4, 4, :white
        end
      end)
    end

    assert_match(/from \(8, 16\)/, error.message)
    assert_match(/:white/, error.message)
  end

  # ...but a drawing whose place along one edge is written in the program reaches only that band:
  # a paddle at a row of its own leaves the squares above it alone.
  def test_a_colour_at_a_row_written_in_the_program_counts_only_in_that_row
    program = color_program do
      screen :bitmap
      paddle = var :paddle, 40
      game_loop do
        clear_screen :black
        %i[red green blue].each_with_index { |color, i| fill_rect 8 + (i * 2), 16, 2, 4, color }
        draw_rect_at paddle, 130, 24, 4, :white
      end
    end

    assert GBC.new.build(program)
  end

  # Five colours in squares of their own fit: each square needs two.
  def test_five_colours_in_squares_of_their_own_are_made
    program = color_program do
      screen :bitmap
      game_loop do
        clear_screen :black
        %i[red green blue white yellow].each_with_index { |color, i| fill_rect i * 16, 0, 16, 8, color }
      end
    end

    assert GBC.new.build(program)
  end

  private

  def color_program(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    program = builder.program
    program.console = :gbc
    program
  end
end
