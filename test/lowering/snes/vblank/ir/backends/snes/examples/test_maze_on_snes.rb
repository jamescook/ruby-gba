# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/maze").to_s

# examples/maze.rb on a Super Nintendo: a brick room and a hero the walls stop, held to the
# interpreter — every variable and every pixel — after every pass.
class TestMazeOnSNES < Minitest::Test
  # Down the left corridor, then right into the first block of wall, which holds the hero back.
  def test_the_hero_walks_and_stops_at_walls_like_the_interpreter
    run = game_player.input_each_frame { |frame| frame < 30 ? [:down] : [:right] }
    run.run(Maze::GAME.program(console: game_console), frames: 60)

    guy = run.sprites(:guy).first
    refute_equal [8, 16], [guy.x, guy.y], "the hero moved"
  end
end
