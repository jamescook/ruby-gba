# frozen_string_literal: true

require "test_helper"

# SETTING THE CLOCK. `clock.set_to` keeps how far the time set is from the clock's own, in two
# saved numbers, and every reading adds it on: so the time set is read at once, moves on as the
# clock does, and is there the next time the game is switched on.
class TestClockSetTo < Minitest::Test
  # A Thursday evening, as the clock starts...
  THURSDAY = Time.new(2026, 10, 22, 21, 7, 5)
  # ...and a Saturday morning five years on, as the game sets it.
  SATURDAY = { year: 2031, month: 5, day: 17, hour: 8, minute: 9, second: 10 }.freeze
  TIME = VBlank::IR::Clock::TIME

  # A game that sets the clock to +to+ on its third pass, and otherwise keeps each reading in a
  # variable of the same name, and 1 in :set while the clock says it was set. +at_power_on+
  # keeps the hour as the game starts up, in a variable's starting value.
  private def setting_program(to = SATURDAY, set_on_pass: 2)
    b = Builder.new
    b.instance_eval do
      now = clock
      var :hour_at_power_on, now.hour
      before_the_loop = var :hour_before_the_loop, -1
      before_the_loop.set! now.hour
      passes = var :passes, 0
      set = var :set, 0
      readings = TIME.to_h { |name| [name, var(name, -1)] }
      game_loop do
        (passes == set_on_pass).then { now.set_to(**to) }
        readings.each { |name, reading| reading.set! now.public_send(name) }
        set.set! 0
        now.set?.then { set.set! 1 }
        passes.add! 1
      end
    end
    b.finalize_program
    b.program
  end

  private def readings_of(player) = TIME.to_h { |name| [name, player[name]] }

  # The pass that sets it reads the time set, and the day of the week it falls on is worked out.
  def test_a_game_sets_the_clock_and_reads_the_time_it_set
    player = game_player.clock_at(THURSDAY).run(setting_program, frames: 3)

    assert_equal SATURDAY.merge(weekday: 6), readings_of(player)
  end

  # ...and from there it keeps time: two and a half seconds of frames on, it reads two seconds
  # on. Which frame the second turns over on is the Advance's to say (in
  # test/advance/vblank/dsl/test_clock_set_to_on_the_advance.rb): a Game Boy Color takes more
  # than a frame over the pass that sets it, and the clock keeps real time through that.
  def test_a_clock_set_moves_on_from_the_time_set
    assert_equal 12, game_player.clock_at(THURSDAY).run(setting_program, frames: 150)[:second]
  end

  # A clock whose battery ran out reads zeros until the game sets it, and is set from then on.
  def test_setting_a_clock_never_set_makes_it_set
    before = game_player.clock_at(Time.new(2000, 1, 1, 5), set: false).run(setting_program, frames: 2)
    after = game_player.clock_at(Time.new(2000, 1, 1, 5), set: false).run(setting_program, frames: 3)

    assert_equal [0, 0], [before[:set], before[:year]]
    assert_equal [1, 2031], [after[:set], after[:year]]
  end

  # On a cartridge with no clock, setting it does nothing: it reads zeros still.
  def test_setting_a_missing_clock_does_nothing
    player = game_player.run(setting_program, frames: 4)

    assert_equal [0, 0, 0], [player[:set], player[:year], player[:hour]]
  end

  # A day past the end of its month is the last day of it, and a year past what a clock can hold
  # is the last one it can: 30 February 2150 is 28 February 2099, a Saturday.
  def test_a_date_that_cannot_be_kept_is_held_to_one_that_can
    player = game_player.clock_at(THURSDAY).run(setting_program(SATURDAY.merge(year: 2150, month: 2, day: 30)), frames: 3)

    assert_equal [2099, 2, 28, 6], readings_of(player).values_at(:year, :month, :day, :weekday)
  end

  # Only the setting is held to 2099: a clock set to the last second of it moves on into 2100,
  # whose first day was a Friday.
  def test_a_clock_set_to_the_end_of_2099_moves_on_into_2100
    last_second = { year: 2099, month: 12, day: 31, hour: 23, minute: 59, second: 59 }
    player = game_player.clock_at(THURSDAY).run(setting_program(last_second), frames: 60)

    assert_equal({ year: 2100, month: 1, day: 1, weekday: 5, hour: 0, minute: 0, second: 0 },
                 readings_of(player).slice(:year, :month, :day, :weekday, :hour, :minute, :second))
  end

  # THE TIME SET IS THERE THE NEXT TIME THE GAME IS SWITCHED ON: switched off for an hour, it
  # reads the time it set an hour on, plus the frames each run played.
  def test_the_time_set_comes_back_after_the_power_goes_off
    store = SaveImage.new(kilobytes: 32)
    game_player(save: store).clock_at(THURSDAY).run(setting_program, frames: 30)
    back = game_player(save: store).clock_at(THURSDAY + 3600 + 1).run(setting_program(set_on_pass: -1), frames: 1)

    assert_equal [9, 9, 11], readings_of(back).values_at(:hour, :minute, :second)
  end
end
