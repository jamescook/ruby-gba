# frozen_string_literal: true

require "test_helper"

# SETTING THE CLOCK, on a chip that keeps the date. The Advance's does, so a game that sets the
# clock reads the chip's own date until it does; the Color's keeps none, and a game there reads no
# date until then (test/ruby_gba/dsl/test_clock_set.rb has the rest).
class TestClockSetOnTheAdvance < Minitest::Test
  # The chip's own time: a Thursday evening, on the second.
  CHIP = Time.new(2026, 10, 22, 21, 7, 5)
  TIME = RubyGBA::IR::Clock::TIME

  # Until the game sets it, a game that sets the clock reads the chip's own time, as one that
  # never does.
  def test_before_the_game_sets_it_the_chips_own_time_is_read
    b = Builder.new
    b.instance_eval do
      now = clock
      readings = TIME.to_h { |name| [name, var(name, -1)] }
      set = var :set, -1
      game_loop do
        pressed(:a).then { now.set!(year: 2030, month: 6, day: 15, hour: 12, minute: 0, second: 0) }
        readings.each { |name, reading| reading.set! now.public_send(name) }
        set.set! 0
        now.set?.then { set.set! 1 }
      end
    end
    b.finalize_program
    player = game_player.clock_at(CHIP).run(b.program, frames: 3)

    assert_equal({ hour: 21, minute: 7, second: 5, year: 2026, month: 10, day: 22, weekday: 4, set: 1 },
                 (TIME + [:set]).to_h { |name| [name, player[name]] })
  end
end
