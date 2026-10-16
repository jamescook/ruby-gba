# frozen_string_literal: true

# A GAME'S OWN TESTS, PLAYED ON EITHER LOWERING. The one require a game's test suite needs:
#
#   require "ruby_gba/testing"
#
#   class WalkerTest < Minitest::Test
#     include RubyGBA::Testing
#
#     def test_holding_right_walks
#       assert_equal 6, game_player.hold(:right).run(game.program, frames: 6)[:x]
#     end
#   end
#
# `game_player` is the interpreter on the GBA lowering's run, and the game built as C, checked
# against the interpreter on every frame, on the native lowering's — the same calls either way,
# so a test is written once and plays on both. Which run it is comes from one setting
# (Lowering::SETTING), which the rake tasks set (ruby_gba/testing/rake_tasks); a plain run is the
# GBA lowering's.
#
# It is not part of `require "ruby_gba"`, because it loads minitest, which a game needs only for
# its tests: a game's Gemfile names minitest in its test group. The native lowering's run needs
# zig as well, as every native build does.
require "minitest/autorun"
require_relative "../ruby_gba"
require_relative "testing/lowering"
require_relative "testing/checked_player"

module RubyGBA
  module Testing
    # The lowering this run tests, read once when the suite loads.
    LOWERING = Lowering.from(ENV)

    def self.lowering = LOWERING
    def self.native? = LOWERING == :native

    # What plays a game in this run: the interpreter on the GBA lowering's run, and on the native
    # lowering's the game built as C, driven through the same calls and checked against the
    # interpreter frame by frame (CheckedPlayer). +save+ is the save memory the game starts with,
    # as the interpreter takes it.
    def game_player(save: nil)
      player = Testing.native? ? CheckedPlayer : IR::Backends::Reference
      save ? player.new(save: save) : player.new
    end

    # A test the native lowering cannot play yet skips itself on a native run, saying +why+ — and
    # a native run ends by counting its skips by reason, so these cannot pile up unseen. On the
    # GBA lowering's run it does nothing.
    def skip_on_native(why)
      skip "native cannot play this yet: #{why}" if Testing.native?
    end
  end
end

require_relative "testing/skips_by_reason" if RubyGBA::Testing.native?
