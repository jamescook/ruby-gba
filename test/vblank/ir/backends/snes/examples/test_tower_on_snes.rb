# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/tower").to_s

# examples/tower.rb on a Super Nintendo: three floors, each a scene with its own background by one
# name, put up as the scene takes over, and the roof's gate opened by showing its second map, held
# to the interpreter — every variable and every pixel — after every pass.
class TestTowerOnSNES < Minitest::Test
  # Up both flights of stairs to the roof, and A opens the gate.
  def test_the_floors_change_like_the_interpreter
    path = ([:right] * 75) + ([:up] * 60)
    run = game_player.input_each_frame { |frame| frame < path.length ? [path[frame]] : [:a] }
    run.run(Tower::GAME.program(console: game_console), frames: 300)

    assert_operator run[:level], :>=, 1, "up the first stairs"
  end
end
