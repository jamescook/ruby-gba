# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/scoreboard").to_s

# The scoreboard example (examples/scoreboard.rb): a status bar along the bottom of the screen over
# a field that drifts under it, which slides out of the ball's way while the ball is low and lights
# a pip each second. Played on every lowering, on the console each run plays a game as.
class TestScoreboardExample < Minitest::Test
  GRAY = Color.resolve(:gray)
  GREEN = Color.resolve(:green)

  private def screen_height = VBlank::Console.described(game_console).screen_height

  # The picture after +frames+ passes with +keys+ held throughout.
  private def picture(frames, keys = [])
    player = game_player
    player.hold(*keys) unless keys.empty?
    player.run(Scoreboard::GAME.program(console: game_console), frames: frames).screen
  end

  # Where the bar's left edge cell is drawn, while the bar is at rest.
  private def bar_edge_row = screen_height - Scoreboard::BAR_HEIGHT + 4

  def test_the_bar_rests_along_the_bottom_and_lights_a_pip_each_second
    shown = picture(70)

    assert_equal GRAY, shown.pixel(2, bar_edge_row), "the bar's left edge"
    assert_equal GREEN, shown.pixel(10, bar_edge_row), "the first pip, lit after a second"
  end

  def test_the_bar_slides_out_of_the_way_while_the_ball_is_low
    shown = picture(70, [:down])

    refute_equal GRAY, shown.pixel(2, bar_edge_row), "the bar has gone down out of view"
  end
end
