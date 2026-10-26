# frozen_string_literal: true

require "test_helper"

# SETTING THE CLOCK, on the Advance alone. Its chip keeps the date, so what a game reads before its
# saved offset comes back is the chip's own date and time; the Color's keeps none, and a game there
# reads nothing then (test/vblank/ir/backends/gbc/test_gbc_clock.rb). And it sets the clock in a
# pass of one frame, so which frame the second turns over on can be said. The rest of setting the
# clock is the same on both, in test/vblank/dsl/test_clock_set_to.rb.
class TestClockSetToOnTheAdvance < Minitest::Test
  THURSDAY = Time.new(2026, 10, 22, 21, 7, 5)

  # A game that sets the clock to a Saturday morning on its third pass, unless +set_on_pass+ says
  # never, and keeps the hour as it starts up, in a variable's starting value and before its loop,
  # and the hour and the second each pass.
  private def setting_program(set_on_pass: 2)
    b = Builder.new
    b.instance_eval do
      now = clock
      var :hour_at_power_on, now.hour
      before_the_loop = var :hour_before_the_loop, -1
      before_the_loop.set! now.hour
      passes = var :passes, 0
      hour = var :hour, -1
      second = var :second, -1
      game_loop do
        (passes == set_on_pass).then { now.set_to(year: 2031, month: 5, day: 17, hour: 8, minute: 9, second: 10) }
        hour.set! now.hour
        second.set! now.second
        passes.add! 1
      end
    end
    b.finalize_program
    b.program
  end

  # From the time set it keeps time, the part of a second the clock was into carrying on as it
  # was: the clock started on a whole second, so it turns over sixty frames from the start, as it
  # would have with nothing set.
  def test_a_clock_set_turns_over_sixty_frames_from_the_start
    assert_equal 10, game_player.clock_at(THURSDAY).run(setting_program, frames: 59)[:second]
    assert_equal 11, game_player.clock_at(THURSDAY).run(setting_program, frames: 60)[:second]
  end

  # A reading made as the game starts up, in a variable's starting value, comes before the saved
  # offset has been read back, so it is the clock's own time: an hour on from Thursday evening,
  # not the time the game set. Read before the game loop, it is.
  def test_a_reading_made_before_the_save_is_read_back_is_the_clocks_own
    store = SaveImage.new(kilobytes: 32)
    game_player(save: store).clock_at(THURSDAY).run(setting_program, frames: 30)
    back = game_player(save: store).clock_at(THURSDAY + 3600 + 1).run(setting_program(set_on_pass: -1), frames: 1)

    assert_equal [22, 9, 9], [back[:hour_at_power_on], back[:hour_before_the_loop], back[:hour]]
  end
end
