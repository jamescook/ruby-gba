# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/level").to_s

# examples/level.rb on a Super Nintendo: a room read from a map editor's file and a walking hero
# kept out of its walls, held to the interpreter — every variable and every pixel — after every
# pass.
class TestLevelOnSNES < Minitest::Test
  # Walked right along the top corridor, down, and then into the wall, which holds the hero back.
  def test_the_hero_walks_and_stops_at_walls_like_the_interpreter
    presses = ->(frame) { frame < 20 ? [:right] : (frame < 40 ? [:down] : [:left]) }
    run = game_player.input_each_frame { |frame| presses.call(frame) }
    run.run(Level::GAME.program(console: game_console), frames: 70)

    hero = run.sprites(:hero).first
    refute_equal [16, 16], [hero.x, hero.y], "the hero moved"
  end
end
