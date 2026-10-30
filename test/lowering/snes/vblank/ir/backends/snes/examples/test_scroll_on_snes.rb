# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/scroll").to_s

# examples/scroll.rb on a Super Nintendo: a 64x64-tile world, bigger than one of the console's
# maps, panned under the screen and held to the interpreter — every pixel — after every pass.
class TestScrollOnSNES < Minitest::Test
  # Panned right and down far enough to cross the edge of the first 32x32 map in each direction,
  # then back left past the world's left edge, where it wraps round.
  def test_the_world_pans_like_the_interpreter
    run = game_player.input_each_frame do |frame|
      if frame < 70 then %i[right down]
      elsif frame < 100 then [:down]
      else [:left]
      end
    end
    run.run(Scroll::GAME.program(console: game_console), frames: 260)

    pass "the checked run stops at the first pass whose picture differs; reaching the end is the check"
  end
end
