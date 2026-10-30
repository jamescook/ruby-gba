# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/sparks").to_s

# examples/sparks.rb on a Super Nintendo: a pool of sparks spawned at random across the whole
# 256-pixel width, falling and given back off the bottom, held to the interpreter — every
# variable, every pool field and every pixel — after every pass.
class TestSparksOnSNES < Minitest::Test
  # Long enough for the first sparks to fall off the 224-row screen and their slots to be reused.
  def test_the_sparks_fall_and_recycle_like_the_interpreter
    run = game_player.run(Sparks::GAME.program(console: game_console), frames: 120)

    refute_empty run.pool(:spark, :y), "sparks are falling"
  end
end
