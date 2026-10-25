# frozen_string_literal: true

require "test_helper"

# THE DATE AND TIME, READ BY THE GAME. `clock` hands back the clock a cartridge carries, and its
# readings are numbers like any variable's. A test says what time the clock starts at, the way it
# says which buttons are held. What a chip that keeps the date reads with nothing set is the
# Advance's alone (test/advance/ruby_gba/builder/test_clock_on_the_advance.rb); the Color's chip
# keeps none, and its game reads a date once it sets one (test/ruby_gba/dsl/test_clock_set.rb).
class TestClock < Minitest::Test
  # A game that keeps 1 in :present and :set while the clock says so, and its hour.
  private def asking_program
    b = Builder.new
    b.instance_eval do
      now = clock
      present = var :present, 0
      set = var :set, 0
      hour = var :hour, -1
      game_loop do
        now.present?.then { present.set! 1 }
        now.set?.then { set.set! 1 }
        hour.set! now.hour
      end
    end
    b.finalize_program
    b.program
  end

  private def answers(player) = { present: player[:present], set: player[:set], hour: player[:hour] }

  # A run never given a time is a cartridge with no clock chip: the game is told so, and every
  # reading is 0 rather than a time that looks right.
  def test_with_no_clock_the_game_is_told_so_and_reads_zeros
    assert_equal({ present: 0, set: 0, hour: 0 }, answers(game_player.run(asking_program, frames: 2)))
  end

  # A clock whose battery ran out is there and was never set: the game is told that instead.
  def test_a_clock_never_set_is_there_and_reads_zeros
    assert_equal({ present: 1, set: 0, hour: 0 },
                 answers(game_player.clock_at(Time.new(2000, 1, 1, 5), set: false).run(asking_program, frames: 2)))
  end
end
