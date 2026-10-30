# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/scoreboard").to_s

# examples/scoreboard.rb on a Super Nintendo: the status bar over the drifting field, slid out of
# the ball's way while the ball is low and back once it has gone, a pip lit each second, held to
# the interpreter — every variable and every pixel — after every pass.
class TestScoreboardOnSNES < Minitest::Test
  # Down long enough for the bar to slide all the way out of view, then up past where it rests, so
  # it slides back; two hundred passes light three pips.
  def test_the_bar_slides_and_lights_like_the_interpreter
    run = game_player.input_each_frame do |frame|
      if frame.between?(10, 70) then [:down]
      elsif frame.between?(90, 140) then [:up]
      else []
      end
    end
    run.run(Scoreboard::GAME.program(console: game_console), frames: 200)

    assert_equal 3, run[:lit]
  end
end
