# frozen_string_literal: true

require "test_helper"
require "differential"

# A fade held to part of the screen: `fade :black, 75, inside: [x, y, w, h]` darkens that
# rectangle and leaves the rest as drawn, and `outside:` the other way round — the view of a
# first-person game faded with its status bar left alone, a pause menu's box kept bright over
# a dimmed game.
#
# The console does it with its first window: a rectangle switched on for the whole game, and
# the display's darkening switched on in one region and off in the other. So the things to
# assert are the two halves — which pixels darken and which stay as drawn — and that the
# console and the game built as C draw the same picture, pixel for pixel.
class TestFadeHeldToArea < Minitest::Test
  include Differential

  WHITE = Color.resolve(:white)

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A room drawn all in white on a tiled screen, with +said+ run before the loop.
  private def white_room(&said)
    program do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      instance_exec(&said)
      game_loop {}
    end
  end

  private def shown(program, frames: 2) = game_player.run(program, frames: frames).screen

  # What the whole screen comes to under the same fade with no rectangle, so the expected
  # colour is the fade's own and not worked out again here.
  private def whole_screen_faded(amount)
    shown(white_room { fade :black, amount }).pixel(0, 0)
  end

  # A bitmap screen has no layers to place a fade under, so a rectangle is the only way to keep
  # part of its picture out of one: the view of a first-person game and its status bar.
  private def painted(&said)
    program do
      screen :bitmap
      clear_screen :white
      fill_rect 0, 128, 240, 32, :blue
      instance_exec(&said)
      game_loop {}
    end
  end

  # The view of a first-person game fading out with its status bar left alone, and coming back:
  # `fade_out` and `fade_in` say the rectangle once, the way they say `under:`.
  private def fading_view
    program do
      screen :bitmap
      clear_screen :white
      fill_rect 0, 128, 240, 32, :blue
      step = var :step, 0
      game_loop do
        step.add! 1
        (step == 2).then { fade_out frames: 6, inside: [0, 0, 240, 128] }
        (step == 12).then { fade_in }
      end
    end
  end

  def test_a_screen_fade_to_a_color_cannot_be_held_to_a_rectangle
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        fade_out inside: [0, 0, 240, 128]
        flash_screen :red
      end
    end
    assert_match(/only a fade to :black or :white/, error.message)
  end

  def test_a_screen_fade_held_to_two_rectangles_is_refused
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        fade_out inside: [0, 0, 240, 128]
        flash_screen outside: [0, 0, 240, 128]
      end
    end
    assert_match(/one screen fade/, error.message)
  end

  # The words a game writes wrongly, refused where the fade is written.
  private def held(**words)
    Builder.new.instance_eval do
      screen :tiled
      fade :black, 50, **words
    end
  end

  def test_a_rectangle_that_is_not_four_whole_numbers_is_refused
    error = assert_raises(ArgumentError) { held(inside: [0, 0, 240]) }
    assert_match(/four whole numbers/, error.message)
    assert_raises(ArgumentError) { held(outside: [0, 0, 240, 80.5]) }
    assert_raises(ArgumentError) { held(inside: :top) }
  end

  def test_inside_and_outside_together_is_refused
    error = assert_raises(ArgumentError) { held(inside: [0, 0, 10, 10], outside: [0, 0, 10, 10]) }
    assert_match(/not both/, error.message)
  end

  def test_a_rectangle_and_under_together_is_refused
    error = assert_raises(ArgumentError) { held(inside: [0, 0, 10, 10], under: :ui) }
    assert_match(/`under:` or a rectangle/, error.message)
  end

  # A screen fade given a wrong rectangle is refused at the line that gave it, not where the
  # routine that walks the fade is built.
  def test_a_screen_fade_with_a_wrong_rectangle_is_refused_where_it_is_written
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        fade_out inside: [0, 0, 240]
      end
    end
    assert_match(/four whole numbers/, error.message)
  end

end
