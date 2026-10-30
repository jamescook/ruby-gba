# frozen_string_literal: true

# Loaded into each test process tools/misplaced_tests.rb starts: notes every test that asked for
# the run's player (`game_player`), so a test that passes on a run without ever playing a game
# there is not taken for one that could move to test/all.
require "vblank/testing"

module VBlank
  module Testing
    # Marks the test asking.
    module NotePlayer
      def game_player(...)
        @played_a_game = true
        super
      end

      def after_teardown
        $stdout.puts "PLAYED #{self.class}##{name}" if @played_a_game && passed?
        super
      end
    end
  end
end

Minitest::Test.prepend(VBlank::Testing::NotePlayer)
