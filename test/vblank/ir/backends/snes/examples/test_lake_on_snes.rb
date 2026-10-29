# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/lake").to_s

# examples/lake.rb on a Super Nintendo: the water bent row by row over the scene, and the
# jellyfish half see-through on the console's colour math, drifting on the same swell — held to
# the interpreter after every pass, within a step of each colour where the two mix differently
# (SNES::HeadlessRun::NearPicture).
class TestLakeOnSNES < Minitest::Test
  # Long enough for the slowest jellyfish to drift off the right edge and come back on the left.
  def test_the_lake_ripples_and_the_jellyfish_drift_like_the_interpreter
    game_player.run(Lake::GAME.program(console: game_console), frames: 260)

    pass "the checked run stops at the first pass whose picture differs; reaching the end is the check"
  end
end
