# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/buffered_bounce").to_s

# examples/buffered_bounce.rb on a Super Nintendo: three balls on a tear-free screen, cleared and
# repainted every pass, bouncing off the bigger screen's walls, held to the interpreter — every
# variable and every pixel — after every pass.
class TestBufferedBounceOnSNES < Minitest::Test
  # Long enough for the second ball, which starts heading up, to reach the top wall and turn round.
  def test_the_balls_bounce_like_the_interpreter
    run = game_player.run(BufferedBounce::GAME.program(console: game_console), frames: 120)

    assert_equal 2, run[:bdy], "the second ball has bounced off the top wall and is heading down"
  end
end
