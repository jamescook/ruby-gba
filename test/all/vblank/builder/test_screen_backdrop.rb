# frozen_string_literal: true

require "test_helper"
require "screen_backdrop_games"

# THE COLOUR A SCREEN SHOWS WHEREVER NOTHING IS DRAWN — the backdrop: the cells a background leaves
# empty, the see-through pixels of its tiles, a scene with no background, and the frames before a
# screen's background is up. Black unless the game says another. A scene that says one of its own
# is in test/console/gba/: the Color keeps one for the game.
class TestScreenBackdrop < Minitest::Test
  include VBlank::Testing::Pictures

  RED = VBlank::Graphics::Color.rgb(31, 0, 0)
  WHITE = VBlank::Graphics::Color.rgb(31, 31, 31)

  # A tiled game whose screen says +backdrop+ (nil for nothing), showing the corner tile from frame
  # +up_at+ on.
  private def corner_game(backdrop:, up_at: 0)
    b = Builder.new
    b.instance_eval do
      backdrop ? screen(:tiled, backdrop: backdrop) : screen(:tiled)
      ScreenBackdropGames.declare_corner_tile(self)
      state = var :state, -1
      tick = var :tick, 0
      scene(:corner) { background :field, tiles: :corner_set, map: ["c"] }
      game_loop do
        (tick == up_at).then { state.set! 0 }
        tick.add! 1
        case_var(:state) { when_val 0, :corner }
      end
    end
    b.finalize_program
    b.program
  end

  def test_nothing_drawn_is_black_unless_the_game_says
    screen = game_player.run(corner_game(backdrop: nil), frames: 4).screen

    assert_equal 0, screen.pixel(100, 100), "an empty cell"
    assert_equal 0, screen.pixel(1, 1), "a see-through pixel"
    assert_equal RED, screen.pixel(6, 1)
  end

  def test_a_screen_says_the_colour_nothing_drawn_shows
    screen = game_player.run(corner_game(backdrop: :white), frames: 4).screen

    assert_equal WHITE, screen.pixel(100, 100), "an empty cell"
    assert_equal WHITE, screen.pixel(1, 1), "a see-through pixel"
    assert_equal RED, screen.pixel(6, 1), "a drawn pixel is as drawn"
  end

  # BEFORE ANY BACKGROUND IS UP, the whole screen is nothing drawn.
  def test_the_frames_before_a_background_is_up_show_the_backdrop
    screen = game_player.run(corner_game(backdrop: :white, up_at: 6), frames: 3).screen

    assert_equal WHITE, screen.pixel(6, 1)
    assert_equal WHITE, screen.pixel(100, 100)
  end

  # A SCENE'S OWN `screen` OF THE GAME'S KIND changes nothing about the display, so its scene shows
  # as it would without it.
  def test_a_scenes_own_screen_of_the_games_kind_shows_its_scene
    assert_backends_agree(ScreenBackdropGames.title_and_board(title_screen: {}), frames: [3, 12], name: "SAMEKIND")
  end

  # ...AND ONE THAT SAYS THE GAME'S OWN BACKDROP AGAIN shows it, on the Color too.
  def test_a_scene_saying_the_games_backdrop_again_shows_it
    screen = game_player.run(ScreenBackdropGames.title_and_board(title_screen: { backdrop: :black }), frames: 3).screen

    assert_equal 0, screen.pixel(100, 100)
  end

  # A GAME WITH NO BACKGROUND AT ALL shows nothing but its backdrop.
  def test_a_game_with_no_background_shows_its_backdrop
    b = Builder.new
    b.instance_eval do
      screen :tiled, backdrop: :white
      tick = var :tick, 0
      game_loop { tick.add! 1 }
    end
    b.finalize_program

    assert_equal WHITE, game_player.run(b.program, frames: 3).screen.pixel(100, 100)
    assert_backends_agree(b.program, frames: 3, name: "NOBG")
  end

  # THE CONSOLE SHOWS IT TOO, pixel for pixel: before the background is up, and after.
  def test_the_console_shows_the_backdrop_as_the_interpreter_does
    assert_backends_agree(corner_game(backdrop: :white, up_at: 3), frames: [2, 6], name: "BACKDROP")
  end

  # A PAINTED SCREEN DRAWS EVERY PIXEL, so there is nowhere a backdrop shows.
  def test_a_painted_screen_cannot_say_a_backdrop
    b = Builder.new
    error = assert_raises(ArgumentError) { b.instance_eval { screen :bitmap, backdrop: :white } }

    assert_match(/clear_screen/, error.message)
  end
end
