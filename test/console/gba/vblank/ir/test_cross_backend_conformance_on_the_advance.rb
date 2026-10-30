# frozen_string_literal: true

require "test_helper"

require "conformance_fixture"

# The test of test/all/vblank/ir/test_cross_backend_conformance.rb that plays the kitchen-sink
# fixture on the lowering under test. The fixture touches every kind the IR has, a song that plays
# a recording among them, and a Game Boy Color cannot play a recording, so this plays on the
# Advance's runs alone.
class TestCrossBackendConformanceOnTheAdvance < Minitest::Test
  # The lowering this run is for plays the fixture too: on a native run the game built as C, on a
  # JavaScript run the game built as JavaScript, each checked against the interpreter on every
  # frame. The fixture's console-only kinds sit in a routine nothing calls, so a lowering that
  # cannot write them still has nothing to refuse.
  def test_the_lowering_under_test_plays_the_whole_fixture
    game_player.run(ConformanceFixture.program, max_steps: 10_000)
  end
end
