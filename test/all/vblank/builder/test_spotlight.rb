# frozen_string_literal: true

require "test_helper"

# A light the game moves: the picture as drawn inside a circle, and darkened everywhere
# outside it.
#
# The console does it with its first window — a rectangle whose left and right edge are
# given a new value on every row of the screen, so it comes out round — and its darkening
# effect switched on outside the window only. So the things to assert are the two halves
# of that: inside the circle nothing changes, outside it every pixel is darkened by the
# amount the light says; and then that the console draws the same picture pixel for pixel,
# which is what holds the circle's edge to one rule on both backends.
#
# What a light draws asks for the console's window and darkening, which a Game Boy Color's
# hardware does not have, so those tests are in test/console/gba/; this file keeps what a light
# refuses.
class TestSpotlight < Minitest::Test
  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A room drawn all in white, with a light at (120, 80) and +said+ run before the loop.
  private def lit_room(radius: 40, dark: 75, &said)
    program do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      light = spotlight at: [120, 80], radius: radius, dark: dark
      instance_exec(light, &said) if said
      game_loop {}
    end
  end

  # --- what a light refuses ---

  def test_a_second_light_is_refused
    error = assert_raises(ArgumentError) do
      lit_room { spotlight at: [10, 10], radius: 5 }
    end

    assert_match(/twice/, error.message)
    assert_match(/light\.radius/, error.message)
  end

  def test_a_light_on_a_bitmap_screen_is_refused
    error = assert_raises(ArgumentError) do
      program do
        screen :bitmap
        spotlight at: [120, 80], radius: 40
      end
    end

    assert_match(/screen :tiled/, error.message)
  end

  # The turning-background screen has the window too, but it is never switched on there,
  # so a light would darken the whole screen: refused, like a bitmap screen.
  def test_a_light_on_a_rotozoom_screen_is_refused
    error = assert_raises(ArgumentError) do
      program do
        screen :rotozoom
        spotlight at: [120, 80], radius: 40
      end
    end

    assert_match(/screen :tiled/, error.message)
  end

  def test_a_light_declared_with_no_radius_says_so
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        spotlight at: [120, 80]
      end
    end

    assert_match(/needs `radius:`/, error.message)
  end

  def test_where_a_light_starts_is_a_number
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        x = var :x, 3
        spotlight at: [x, 80], radius: 40
      end
    end

    assert_match(/move_to/, error.message)
    assert_match(/0 to 100/, assert_raises(ArgumentError) { lit_room(dark: 120) }.message)
    assert_match(/0 or more/, assert_raises(ArgumentError) { lit_room(radius: -1) }.message)
  end
end
