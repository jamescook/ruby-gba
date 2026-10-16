# frozen_string_literal: true

require "game_test_helper"
require "walker"

# The walking group: a test of the game, played on whichever lowering the run is for.
class WalkerTest < Minitest::Test
  def test_holding_right_walks_the_walker
    note_lowering
    # The run's own copy of its test options reaches whatever this test starts, so it must not
    # hold an option for a test runner the game does not have.
    refute_includes ENV.fetch("TESTOPTS", "").split, "--ractor" if RubyGBA::Testing.native?

    assert_equal 6, game_player.hold(:right).run(Walker::GAME.program, frames: 6)[:x]
  end
end
