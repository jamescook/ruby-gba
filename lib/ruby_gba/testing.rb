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
# `game_player` is the interpreter on the GBA lowering's run, the game built as C, checked
# against the interpreter on every frame, on the native lowering's, and the game built as
# JavaScript, checked the same way, on the JavaScript lowering's — the same calls every way, so a
# test is written once and plays on all three. Which run it is comes from one setting
# (Lowering::SETTING), which the rake tasks set (ruby_gba/testing/rake_tasks); a plain run is the
# GBA lowering's.
#
# A test that asks whether the CARTRIDGE draws what the interpreter draws includes Pictures as
# well (`include RubyGBA::Testing::Pictures`, for `assert_backends_agree`). That one plays the
# cartridge in the emulator, so it needs the ruby-gba-emulator gem in the game's test group.
#
# It is not part of `require "ruby_gba"`, because it loads minitest, which a game needs only for
# its tests: a game's Gemfile names minitest in its test group. The native lowering's run needs
# zig as well, as every native build does, and the JavaScript lowering's needs node.
require "minitest/autorun"
require_relative "../ruby_gba"
require_relative "testing/lowering"
require_relative "testing/checked_player"
require_relative "testing/pictures"

module RubyGBA
  module Testing
    # The lowering this run tests, read once when the suite loads.
    LOWERING = Lowering.from(ENV)

    def self.lowering = LOWERING
    def self.native? = LOWERING == :native
    def self.javascript? = LOWERING == :js

    # THE EMULATOR, IF THE GAME HAS IT, LOADED NOW rather than by the first test that wants it.
    # A suite may play its tests in Ractors, and loading it writes globals only the main Ractor
    # may touch (see Diagnostics::Emulator.load!). A game without it in its test group loses
    # only the tests that play the cartridge, which say so when they run.
    Diagnostics::Emulator.available?

    # Whether this run plays the game built for another machine (as C, or as JavaScript) and
    # checks it against the interpreter, rather than playing the interpreter alone. Such a run has
    # no cartridge to check.
    def self.checked? = Lowering::CHECKED.include?(LOWERING)

    # What plays a game in this run: the interpreter on the GBA lowering's run; on the native
    # lowering's the game built as C, driven through the same calls and checked against the
    # interpreter frame by frame (CheckedPlayer); and on the JavaScript lowering's the game built
    # as JavaScript, checked the same way (JSCheckedPlayer). +save+ is the save memory the game
    # starts with, as the interpreter takes it.
    def game_player(save: nil)
      player = Testing.player_class
      save ? player.new(save: save) : player.new
    end

    # The class game_player makes one of, on each lowering's run.
    PLAYERS = Ractor.make_shareable({ gba: IR::Backends::Reference, native: CheckedPlayer, js: JSCheckedPlayer })

    # The class game_player makes one of, for this run.
    def self.player_class = PLAYERS.fetch(LOWERING)

    # A test the native lowering cannot play yet skips itself on a native run, saying +why+ — and
    # a native run ends by counting its skips by reason, so these cannot pile up unseen. On the
    # GBA lowering's run it does nothing.
    def skip_on_native(why)
      skip "native cannot play this yet: #{why}" if Testing.native?
    end

    # The same, for the JavaScript lowering's run.
    def skip_on_js(why)
      skip "JavaScript cannot play this yet: #{why}" if Testing.javascript?
    end
  end
end

require_relative "testing/skips_by_reason" if RubyGBA::Testing.checked?
