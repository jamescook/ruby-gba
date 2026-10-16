# frozen_string_literal: true

# A game's own test, as a game in a repository of its own writes it: one require for the
# library's test helper, and nothing from ruby-gba's own test folder.
require "ruby_gba/testing"
require_relative "one_pixel_off"

# Run by test/ruby_gba/testing/test_game_suite.rb, which reads what these leave behind.
class WalkerTest < Minitest::Test
  include RubyGBA::Testing

  def test_holding_right_walks_the_walker
    game = RubyGBA.game "WALKER" do
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
    File.write(File.join(folder, "#{RubyGBA::Testing.lowering}-#{Process.pid}"), "") if folder

    assert_includes RubyGBA::Testing::Lowering::NAMES, RubyGBA::Testing.lowering
  end
end
