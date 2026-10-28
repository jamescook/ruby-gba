# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/sheet").to_s

# examples/sheet.rb on a Super Nintendo: a room and an animated hero both cut from picture
# files, held to the interpreter — every variable and every pixel — after every pass.
class TestSheetOnSNES < Minitest::Test
  # Walked long enough for the walk cycle to come round, and into the right-hand wall.
  def test_the_hero_walks_animated_like_the_interpreter
    run = game_player.input_each_frame { |frame| frame < 50 ? [:right] : [:down] }
    run.run(Sheet::GAME.program(console: game_console), frames: 80)

    hero = run.sprites(:hero).first
    refute_equal [16, 16], [hero.x, hero.y], "the hero moved"
  end
end
