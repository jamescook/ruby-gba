# frozen_string_literal: true

# A game's own test, as a game in a repository of its own writes it: one require for the
# library's test helper, and nothing from VBlank's own test folder.
require "vblank/testing"
require_relative "one_pixel_off"

# Run by test/all/vblank/testing/test_game_suite.rb, which reads what these leave behind.
class WalkerTest < Minitest::Test
  include VBlank::Testing

  def test_holding_right_walks_the_walker
    game = VBlank.game "WALKER", consoles: %i[gba] do
      x = var :x, 0
      game_loop do
        held(:right).then { x.add! 1 }
        pixel 10, 10, :red
      end
    end

    assert_equal 6, game_player.hold(:right).run(game.program, frames: 6)[:x]
  end

  # Which lowering played this test, left as a file for the test outside to read.
  def test_says_which_lowering_played_it
    folder = ENV.fetch("GAME_SUITE_PLAYED", nil)
    File.write(File.join(folder, "#{VBlank::Testing.lowering}-#{Process.pid}"), "") if folder

    assert_includes VBlank::Testing::Lowering::NAMES, VBlank::Testing.lowering
  end
end
