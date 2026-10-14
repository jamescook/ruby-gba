# frozen_string_literal: true

require "test_helper"
require "differential"

# A light the game moves: the picture as drawn inside a circle, and darkened everywhere
# outside it.
#
# The console does it with its first window — a rectangle whose left and right edge are
# given a new value on every row of the screen, so it comes out round — and its darkening
# effect switched on outside the window only. So the things to assert are the two halves
# of that: inside the circle nothing changes, outside it every pixel is darkened by the
# amount the light says; and then that the console draws the same picture pixel for pixel,
# which is what holds the circle's edge to one rule on both backends.
class TestSpotlight < Minitest::Test
  runs_on :reference
  include Differential

  WIDTH = 240
  HEIGHT = 160

  WHITE = Color.resolve(:white)

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A room drawn all in white, with a light at (120, 80) and +said+ run before the loop.
  def lit_room(radius: 40, dark: 75, &said)
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

  def shown(program, frames: 2) = Reference.new.run(program, frames: frames).screen

  # White taken three quarters of the way to black the way the emulator's display does it,
  # at eight bits a channel: red comes to 64 of 255, which is 8, and green and blue lose
  # the fraction of their share where they sit in the number and come to 63, which is 7.
  # (Five bits throughout would be 8 in every channel.) See Framebuffer#darkened_by_display.
  THREE_QUARTERS_DARK = Color.rgb(8, 7, 7)

  def test_the_picture_is_as_drawn_inside_the_light_and_darkened_outside_it
    screen = shown(lit_room)

    assert_equal WHITE, screen.pixel(120, 80), "the middle of the light"
    assert_equal WHITE, screen.pixel(150, 80), "thirty pixels right of it, inside"
    assert_equal WHITE, screen.pixel(120, 105), "twenty-five below it, inside"
    assert_equal THREE_QUARTERS_DARK, screen.pixel(170, 80), "fifty right of it, outside"
    assert_equal THREE_QUARTERS_DARK, screen.pixel(5, 5), "a corner of the screen"
    assert_equal THREE_QUARTERS_DARK, screen.pixel(150, 110), "thirty right and thirty down is past forty"
  end

  def test_the_console_draws_the_same_light
    assert_backends_agree(lit_room, frames: 2)
  end

  # The light is where the handle says at the end of a frame: moved, grown and made darker
  # as the game runs, it is worked out again before the next one.
  def test_a_light_the_game_moves_is_drawn_where_it_went
    moving = lit_room(radius: 20) do |light|
      step = var :step, 0
      once_a_frame do
        step.add! 1
        light.move_to 40 + step * 10, 30 + step * 5
        light.radius.set! 20 + step * 4
        light.dark.set! 100
      end
    end
    screen = shown(moving, frames: 4)
    black = Color.rgb(0, 0, 0)

    assert_equal black, screen.pixel(120, 80), "where the light started is dark now"
    refute_equal black, screen.pixel(70, 45), "the middle of where it went after three frames"
    assert_backends_agree(moving, frames: 4)
  end

  # A light that reaches past the edges of the screen — and one whose middle is off it —
  # lights what it covers and no more, and comes out the same on both backends.
  def test_a_light_past_the_edges_of_the_screen
    [[-30, 80, 60], [230, 5, 50], [120, 300, 200], [10, 150, 400]].each do |x, y, radius|
      game = lit_room(radius: radius) { |light| light.move_to x, y }
      assert_backends_agree(game, frames: 2, name: "AT#{x}X#{y}")
    end
  end

  # A radius of nothing lights nothing, and a light of no darkness changes nothing.
  def test_a_light_of_no_size_or_no_darkness
    dark = shown(lit_room(radius: 0))

    assert_equal THREE_QUARTERS_DARK, dark.pixel(120, 80)
    assert_equal WHITE, shown(lit_room(dark: 0)).pixel(5, 5)
    assert_backends_agree(lit_room(radius: 0), frames: 2, name: "NOSIZE")
  end

  # A LIGHT BESIDE THREE BENDING LAYERS is one more thing fed a row at a time than the
  # console has engines to feed with, so every one of them is fed by the interrupt at the
  # end of each line instead — the same picture, the CPU carrying the numbers.
  def test_a_light_fed_by_the_line_interrupt_draws_the_same_picture
    crowded = program do
      screen :tiled
      layers :far, :middle, :near
      image(:stripe, "#" => :white, "." => :transparent) { (["#...#..."] * 8).join("\n") }
      tiles :set, "#" => :stripe
      %i[far middle near].each_with_index do |name, i|
        layer(name) { background(name, tiles: :set, map: ["#" * 32] * 32).scroll_each_row { |row| (row + i) % 3 } }
      end
      spotlight at: [120, 80], radius: 50, dark: 100
      game_loop {}
    end

    assert_match(/a spotlight/, RubyGBA::IR::Backends::GBA::BendForm.kept_interrupt_reason(crowded))
    assert_backends_agree(crowded, frames: 2)
  end

  # --- a light beside the other things that darken a picture ---

  # A FADE AND A LIGHT ARE BOTH IN FORCE. The display has one darkening, and the light holds
  # it, so a game with a light fades by walking its colours — the whole picture goes half
  # way to black, and outside the light it is then darkened again on top.
  def test_a_fade_darkens_the_whole_picture_and_the_light_still_shows
    faded = lit_room { fade :black, 50 }
    screen = shown(faded)

    inside = screen.pixel(120, 80)
    outside = screen.pixel(5, 5)

    refute_equal WHITE, inside, "the fade reaches inside the light"
    refute_equal Color.rgb(0, 0, 0), inside
    assert (outside & 31) < (inside & 31), "outside the light is darker than inside it"
    assert_backends_agree(faded, frames: 2)
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
