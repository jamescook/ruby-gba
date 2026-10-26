# frozen_string_literal: true

require "test_helper"

# Each 8×8 square of a painted Game Boy Color screen is drawn from one list of four colours, chosen
# when the cartridge is made (GBC::SquareColors). A program whose painting could put a fifth colour
# in a square is refused then, naming the square, rather than showing a colour wrong as it runs; so
# is one that needs more than the console's eight lists, or whose colours cannot each keep one
# place in every list. The games that fit are played in test/vblank/builder/test_painted_squares.rb.
class TestGBCPaintedSquares < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  def test_five_colours_painted_into_one_square_are_refused_naming_the_square_and_the_lines
    error = assert_raises(GBC::LoweringError) do
      GBC.new.build(color_program do
        screen :bitmap
        game_loop do
          clear_screen :black
          %i[red green blue white].each_with_index { |color, i| fill_rect 8 + (i * 2), 16, 2, 4, color }
        end
      end)
    end

    assert_match(/square of the screen from \(8, 16\)/, error.message)
    assert_match(/5 colours/, error.message)
    assert_match(/These lines paint there: .*test_gbc_painted_squares\.rb:\d+/, error.message)
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

  # A scene that does not clear the screen keeps what the scene before it painted, so a square
  # holds both scenes' colours: here five.
  def test_a_scene_keeping_the_last_picture_counts_its_colours_too
    error = assert_raises(GBC::LoweringError) do
      GBC.new.build(color_program do
        screen :bitmap
        state = var :state, 0
        scene :warm do
          clear_screen :black
          %i[red orange yellow].each_with_index { |color, i| fill_rect 8 + (i * 2), 16, 2, 8, color }
        end
        scene(:cool) { pixel 15, 23, :green }
        game_loop do
          pressed(:a).then { state.set! 1 }
          case_var(:state) do
            when_val 0, :warm
            when_val 1, :cool
          end
        end
      end)
    end

    assert_match(/in the scene :cool/, error.message)
    assert_match(/does not clear the screen/, error.message)
  end

  # Nine squares, each painted in three colours no other square has: nine lists, one more than the
  # console has.
  def test_more_lists_than_the_console_has_are_refused
    error = assert_raises(GBC::LoweringError) do
      GBC.new.build(color_program do
        screen :bitmap
        game_loop do
          clear_screen :black
          9.times do |square|
            3.times { |i| fill_rect (square * 8) + (i * 2), 0, 2, 8, rgb(square + 1, i + 1, 31 - i) }
          end
        end
      end)
    end

    assert_match(/9 different sets of colours/, error.message)
  end

  # Four colours, every three of them sharing a square with black: each needs a place none of the
  # other three has, and black has the first, so four places are not enough.
  def test_colours_that_cannot_each_keep_one_place_are_refused
    error = assert_raises(GBC::LoweringError) do
      GBC.new.build(color_program do
        screen :bitmap
        game_loop do
          clear_screen :black
          %i[red green blue yellow].combination(3).each_with_index do |colors, square|
            colors.each_with_index { |color, i| fill_rect (square * 8) + (i * 2), 0, 2, 8, color }
          end
        end
      end)
    end

    assert_match(/one place in every set of colours/, error.message)
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
