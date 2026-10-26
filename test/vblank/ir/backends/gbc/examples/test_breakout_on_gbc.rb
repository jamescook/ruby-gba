# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/breakout").to_s

# examples/breakout.rb built for the Game Boy Color, held to the interpreter after every pass of a
# recorded run: the title, START, and the ball breaking bricks while the paddle moves. The wall is
# four rows in four colours on a painted screen, with the white ball and paddle over them, and each
# 8×8 square keeps to the four colours a Color square holds (GBC::SquareColors).
class TestBreakoutOnGBC < Minitest::Test
  def test_a_game_of_breakout_matches_the_interpreter
    run = game_player.input_each_frame { |frame| frame == 2 ? [:start] : (frame / 40).odd? ? [:left] : [:right] }
    run.run(Breakout::GAME.program(console: :gbc), frames: 240)

    assert_equal 1, run[:state], "the game should be under way"
    assert_operator run[:bricks_left], :<, Breakout::COLS * Breakout::ROWS, "and a brick broken"
  end
end
