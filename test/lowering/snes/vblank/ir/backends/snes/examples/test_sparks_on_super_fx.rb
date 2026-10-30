# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/sparks").to_s

# examples/sparks.rb on a Super Nintendo cartridge with a Super FX 2: the pool of falling sparks, its
# screen painted in the chip's RAM, held to the interpreter — every variable, every pool field and
# every pixel — after every pass.
class TestSparksOnSuperFX < Minitest::Test
  def test_the_sparks_fall_like_the_interpreter
    run = game_player.run(Sparks::GAME.program(console: :snes, variant: :superfx), frames: 60)

    refute_empty run.pool(:spark, :y), "sparks are falling"
  end
end
