# frozen_string_literal: true

require "test_helper"
require "differential"

# THE TESTS OF vblank/builder/test_fade_held_to_area.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# A fade held to part of the screen: `fade :black, 75, inside: [x, y, w, h]` darkens that
# rectangle and leaves the rest as drawn, and `outside:` the other way round — the view of a
# first-person game faded with its status bar left alone, a pause menu's box kept bright over
# a dimmed game.
#
# The console does it with its first window: a rectangle switched on for the whole game, and
# the display's darkening switched on in one region and off in the other. So the things to
# assert are the two halves — which pixels darken and which stay as drawn — and that the
# console and the game built as C draw the same picture, pixel for pixel.
class TestFadeHeldToAreaOnTheAdvance < Minitest::Test
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

  def test_a_fade_held_inside_a_rectangle_darkens_only_that_rectangle
    screen = shown(white_room { fade :black, 75, inside: [0, 0, 240, 120] })
    dark = whole_screen_faded(75)

    refute_equal WHITE, dark, "the fade darkens at all"
    assert_equal dark, screen.pixel(0, 0), "the top left corner is inside"
    assert_equal dark, screen.pixel(239, 119), "the last pixel inside"
    assert_equal WHITE, screen.pixel(0, 120), "the first row below it is as drawn"
    assert_equal WHITE, screen.pixel(239, 159), "the bottom right corner is as drawn"
  end

  def test_a_fade_held_outside_a_rectangle_leaves_only_that_rectangle_as_drawn
    screen = shown(white_room { fade :black, 50, outside: [60, 40, 120, 80] })
    dark = whole_screen_faded(50)

    assert_equal WHITE, screen.pixel(60, 40), "the rectangle's top left corner"
    assert_equal WHITE, screen.pixel(179, 119), "the rectangle's last pixel"
    assert_equal dark, screen.pixel(59, 40), "just left of it"
    assert_equal dark, screen.pixel(180, 119), "just right of it"
    assert_equal dark, screen.pixel(60, 120), "just below it"
  end

  def test_the_console_draws_a_fade_held_inside_a_rectangle_the_same
    assert_backends_agree(white_room { fade :black, 75, inside: [0, 0, 240, 120] }, frames: 2)
  end

  def test_the_console_draws_a_fade_held_outside_a_rectangle_the_same
    assert_backends_agree(white_room { fade :black, 50, outside: [60, 40, 120, 80] }, frames: 2)
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

  def test_the_console_holds_a_fade_to_part_of_a_bitmap_screen_the_same
    assert_backends_agree(painted { fade :black, 100, inside: [0, 0, 240, 128] }, frames: 2)
  end

  def test_the_console_holds_a_fade_toward_white_to_part_of_a_bitmap_screen_the_same
    assert_backends_agree(painted { fade :white, 50, outside: [0, 0, 240, 128] }, frames: 2)
  end

  def test_the_console_holds_a_fade_to_part_of_a_tear_free_screen_the_same
    game = program do
      screen :bitmap, tear_free: true
      game_loop do
        clear_screen :white
        fill_rect 0, 128, 240, 32, :blue
        fade :black, 60, outside: [0, 128, 240, 32]
      end
    end
    assert_backends_agree(game, frames: 3)
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

  def test_fade_out_held_to_the_view_leaves_the_status_bar_as_drawn
    screen = shown(fading_view, frames: 10)

    assert_equal Color.resolve(:black), screen.pixel(120, 60), "the view is faded out"
    assert_equal Color.resolve(:blue), screen.pixel(120, 140), "the status bar is as drawn"
    assert_equal WHITE, shown(fading_view, frames: 24).pixel(120, 60), "and fade_in brings the view back"
  end

  def test_the_console_fades_the_view_out_and_back_the_same
    [5, 10, 16].each { |frames| assert_backends_agree(fading_view, frames: frames) }
  end

  # A tint after a held fade reaches the whole screen: the tint and the fade are one effect, so
  # the last one said is the one in force, and it says where it reaches too.
  def test_a_tint_after_a_held_fade_reaches_the_whole_screen
    game = painted do
      fade :black, 100, inside: [0, 0, 240, 128]
      tint :red, 50
    end
    screen = shown(game)

    assert_equal screen.pixel(120, 60), shown(painted { tint :red, 50 }).pixel(120, 60), "tinted, not black"
    refute_equal Color.resolve(:blue), screen.pixel(120, 140), "the status bar is tinted too"
    assert_backends_agree(game, frames: 2)
  end

  # The words a game writes wrongly, refused where the fade is written.
  private def held(**words)
    Builder.new.instance_eval do
      screen :tiled
      fade :black, 50, **words
    end
  end

  # Edges: the top edge of an `outside:` rectangle, a rectangle partly off the screen, and one
  # with no width, which holds nothing, so `inside:` fades nothing and `outside:` everything.
  def test_the_edges_of_a_rectangle_land_where_the_console_puts_them
    assert_backends_agree(white_room { fade :black, 60, outside: [10, 30, 100, 50] }, frames: 2)
    assert_backends_agree(white_room { fade :black, 60, inside: [-20, 140, 300, 40] }, frames: 2)
  end

  def test_a_rectangle_with_no_width_holds_nothing
    dark = whole_screen_faded(60)

    assert_equal WHITE, shown(white_room { fade :black, 60, inside: [50, 50, 0, 40] }).pixel(50, 50)
    assert_equal dark, shown(white_room { fade :black, 60, outside: [50, 50, 0, 40] }).pixel(50, 50)
    assert_backends_agree(white_room { fade :black, 60, outside: [50, 50, 0, 40] }, frames: 2)
  end

  # A screen that turns its background, where the picture is the console's third layer as on a
  # bitmap screen.
  def test_the_console_holds_a_fade_to_part_of_a_turning_screen_the_same
    game = program do
      screen :rotozoom
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background(:room, tiles: :set, map: ["#" * 32] * 32).rotate(10)
      fade :black, 75, inside: [0, 0, 240, 100]
      game_loop {}
    end
    assert_backends_agree(game, frames: 2)
  end

  # A fade_out of the default half second is longer than the display's seventeen levels, so it
  # hands `fade` an amount with a fraction. Held to a rectangle it stays the display's own fade,
  # in its sixteenths, on every backend.
  def test_a_long_fade_out_held_to_a_rectangle_keeps_the_display_steps
    game = program do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      fade_out outside: [0, 120, 240, 40]
      game_loop {}
    end
    [8, 16, 24, 40].each { |frames| assert_backends_agree(game, frames: frames) }
  end

  # The window stays on across a change of scene and of the kind of screen: a bitmap title
  # handing over to a tiled game, each fading part of itself, and a tint said on the tiled
  # screen kept onto the bitmap one, which reaches the whole of it.
  def test_a_held_fade_crosses_a_change_of_screen
    game = program do
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      mode = var :mode, 0
      step = var :step, 0
      scene(:title) do
        screen :bitmap
        clear_screen :white
        fill_rect 0, 128, 240, 32, :blue
        (step < 3).then { fade :black, 50, inside: [0, 0, 240, 128] }
      end
      scene(:play) do
        screen :tiled
        background :room, tiles: :set, map: ["#" * 32] * 32
        (step < 7).then { fade :black, 75, outside: [60, 40, 120, 80] }
        (step == 7).then { tint :red, 40 }
      end
      game_loop do
        step.add! 1
        (step == 4).then { mode.set! 1 }
        (step == 10).then { mode.set! 0 }
        case_var(:mode) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    [2, 6, 9, 14].each { |frames| assert_backends_agree(game, frames: frames, console_frames: frames + 2) }
  end

  # A fade the game moves: walked down over frames, then lifted to the whole screen, then held
  # again. Each fade says where it reaches, so the last one said is the one in force.
  def test_each_fade_says_where_it_reaches
    game = program do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      step = var :step, 0
      game_loop do
        step.add! 1
        (step < 3).then { fade :black, step * 30, inside: [0, 0, 120, 160] }
        (step == 3).then { fade :black, 40 }
        (step > 3).then { fade :black, 80, outside: [0, 0, 120, 160] }
      end
    end
    [2, 4, 6].each { |frames| assert_backends_agree(game, frames: frames) }
  end
end
