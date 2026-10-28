# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/buffered_bounce").to_s

# examples/buffered_bounce.rb on a Super Nintendo cartridge with a Super FX 2: the screen cleared by
# the chip every pass and copied to video RAM a blank at a time with the screen on, held to the
# interpreter — every variable and every pixel — after every pass.
class TestBufferedBounceOnSuperFX < Minitest::Test
  # Long enough for the second ball, which starts heading up, to reach the top wall and turn round.
  def test_the_balls_bounce_like_the_interpreter
    run = game_player.run(BufferedBounce::GAME.program(console: :snes, variant: :superfx), frames: 120)

    assert_equal 2, run[:bdy], "the second ball has bounced off the top wall and is heading down"
  end
end
