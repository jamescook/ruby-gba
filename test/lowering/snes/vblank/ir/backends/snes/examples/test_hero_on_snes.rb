# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/hero").to_s

# examples/hero.rb on a Super Nintendo: the file screen, a new walk, the signpost's words typed
# into a box the sprites show, a walk north under the mist the console shows half see-through,
# a save and back to the file screen — held to the interpreter after every pass, within a step of
# each colour where the two mix differently (SNES::HeadlessRun::NearPicture).
class TestHeroOnSNES < Minitest::Test
  # A picks FILE 1 and then NEW GAME (the cursor opens there for an empty file); the walk starts
  # beside the sign, so A opens it; up walks into the mist; START saves and SELECT goes back. The
  # buttons are by the console's frames, a few apart: a pass of hero takes two of them on a Super
  # Nintendo, and its first more.
  PRESSES = { 30 => [:a], 40 => [:a], 50 => [:a], 200 => [:start], 230 => [:select] }.freeze

  def test_a_walk_reads_the_sign_saves_and_comes_back_like_the_interpreter
    run = game_player.input_each_frame { |frame| PRESSES.fetch(frame) { frame.between?(120, 190) ? [:up] : [] } }
    run.run(Hero::GAME.program(console: game_console), frames: 130)

    assert_operator run[:steps], :>, 5, "the walk took steps north"
    assert_operator run[:mist], :>, 0, "walking north thickened the mist the game keeps"
    assert_equal 1, run[:reading], "the sign's box is open"
  end
end
