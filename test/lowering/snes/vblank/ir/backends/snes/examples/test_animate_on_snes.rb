# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/animate").to_s

# examples/animate.rb on a Super Nintendo: a spinning coin, a sprite painted onto the picture
# with what it covers put back as it moves, started in the middle of the bigger screen and
# kept to its edges, held to the interpreter — every variable and every pixel — after every pass.
class TestAnimateOnSNES < Minitest::Test
  # Walked up and left from the middle of the screen, spinning all the way.
  def test_the_coin_spins_and_walks_like_the_interpreter
    run = game_player.input_each_frame { |frame| frame < 70 ? %i[left up] : [] }
    run.run(Animate::GAME.program(console: game_console), frames: 80)

    gold = (0...224).select { |y| (0...256).any? { |x| run.screen.pixel(x, y) == Color.resolve(:yellow) } }
    assert_operator gold.max, :<, 104, "the coin has walked up from the middle, where it started"
  end
end
