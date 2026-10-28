# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/tiles").to_s

# examples/tiles.rb on a Super Nintendo: a room of tiles whose door opens and shuts and which is
# walked between three maps, held to the interpreter — every variable and every pixel — after
# every pass.
class TestTilesOnSNES < Minitest::Test
  # The door opened and shut, then right into the next room and the one after, and back.
  def test_the_rooms_and_the_door_match_the_interpreter
    presses = { 4 => [:a], 10 => [:b], 14 => [:a], 20 => [:right], 26 => [:right], 32 => [:left], 38 => [:right] }
    run = game_player.input_each_frame { |frame| presses.fetch(frame, []) }
    run.run(Tiles::GAME.program(console: game_console), frames: 44)

    assert_equal 2, run[:where], "in the third room"
  end
end
