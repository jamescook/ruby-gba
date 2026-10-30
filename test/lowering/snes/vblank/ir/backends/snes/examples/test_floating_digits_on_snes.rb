# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/floating_digits").to_s

# examples/floating_digits.rb on a Super Nintendo: ten digit pictures drifting and bouncing off the
# bigger screen's walls, the screen cleared and every digit painted again each pass, held to the
# interpreter — every variable and every pixel — after every pass.
class TestFloatingDigitsOnSNES < Minitest::Test
  # Long enough for the digits whose first steps are up to reach the top wall and turn round.
  def test_the_digits_drift_and_bounce_like_the_interpreter
    run = game_player.run(FloatingDigits::GAME.program(console: game_console), frames: 120)

    bounced = (0...10).count { |d| run[:"dy#{d}"] != [1, 2, -1, -2, 1][(d + 2) % 5] }
    assert_operator bounced, :>, 0, "a digit has bounced off a wall"
  end
end
