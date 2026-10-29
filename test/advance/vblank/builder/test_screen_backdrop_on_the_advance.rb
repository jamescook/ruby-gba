# frozen_string_literal: true

require "test_helper"
require "screen_backdrop_games"

# A SCENE SAYS ITS OWN BACKDROP, as every screen setting a scene says is that scene's: a sky-blue
# title, then a board that says none and so shows the game's. The Advance keeps one backdrop colour
# and is told the scene's as it takes over; the Color keeps it in every colour list, and refuses a
# scene of its own (test/vblank/ir/backends/gbc/test_gbc_backdrop.rb).
class TestScreenBackdropOnTheAdvance < Minitest::Test
  include VBlank::Testing::Pictures

  private def sky_title = ScreenBackdropGames.title_and_board(title_screen: { backdrop: ScreenBackdropGames::SKY })

  def test_a_scene_says_its_own_backdrop
    assert_equal ScreenBackdropGames::SKY, game_player.run(sky_title, frames: 3).screen.pixel(100, 100), "the title's"
    assert_equal 0, game_player.run(sky_title, frames: 12).screen.pixel(100, 100), "the board says none"
  end

  def test_the_console_shows_each_scenes_backdrop_as_the_interpreter_does
    assert_backends_agree(sky_title, frames: [3, 12], name: "BACKDROPS")
  end
end
