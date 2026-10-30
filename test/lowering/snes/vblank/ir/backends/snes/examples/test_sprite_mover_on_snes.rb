# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/sprite_mover").to_s

# examples/sprite_mover.rb on a Super Nintendo: a heart steered over a painted field, passing in
# front of one post and behind the other because of the layers they are in, held to the
# interpreter — every variable and every pixel — after every pass, so every frame the heart
# crosses a post is checked.
class TestSpriteMoverOnSNES < Minitest::Test
  START = SpriteMover.layout(256, 224)

  # Over the left post and on to the left edge, then back right, over the right post.
  def test_the_heart_crosses_both_posts_like_the_interpreter
    run = game_player.input_each_frame { |frame| frame < 90 ? [:left] : [:right] }
    run.run(SpriteMover::GAME.program(console: game_console), frames: 260)

    assert_operator run[:__spr1_x], :>, START[:right_post][0], "the heart went past the right post"
  end
end
