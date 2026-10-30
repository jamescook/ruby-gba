# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/raycaster").to_s

# examples/raycaster.rb on a Super Nintendo: a first-person view of a maze, a ray cast for each
# of the 32 strips of the wider screen and every strip a wall drawn as tall as its distance says,
# with fractions throughout, held to the interpreter — every variable and every pixel — after
# every pass.
class TestRaycasterOnSNES < Minitest::Test
  # Turned left, then walked forward into the wall, which stops the player.
  def test_the_view_turns_and_walks_like_the_interpreter
    run = game_player.input_each_frame { |frame| frame < 20 ? [:left] : [:up] }
    run.run(Raycaster::GAME.program(console: game_console), frames: 60)

    refute_equal 0, run[:view], "the view turned"
    middle = Raycaster.layout(256, 224)[:horizon]
    assert_includes Raycaster::WALL_SHADES, run.screen.pixel(128, middle), "a wall ahead, on the eye line"
  end
end
