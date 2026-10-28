# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/parallax").to_s

# examples/parallax.rb on a Super Nintendo: the sky and the ground in two layers, the ground in
# front with see-through cells over the sky, each scrolling at its own speed, held to the
# interpreter — every pixel — after every pass.
class TestParallaxOnSNES < Minitest::Test
  # Right long enough for the near layer to come round its 256 pixels, then back left.
  def test_the_layers_scroll_like_the_interpreter
    run = game_player.input_each_frame { |frame| frame < 140 ? [:right] : [:left] }
    run.run(Parallax::GAME.program(console: game_console), frames: 180)

    pass "the checked run stops at the first pass whose picture differs; reaching the end is the check"
  end
end
