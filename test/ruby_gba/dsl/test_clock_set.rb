# frozen_string_literal: true

require "test_helper"

# SETTING THE CLOCK. A game asks the player the time on a screen of its own and hands the numbers
# to `clock.set!`. As the console's own games did it, nothing is written into the clock chip: the
# game's save keeps how far the time set is from the chip's count, and every reading after is the
# chip's count moved on by that much — so it survives the power going off, and the chip goes on
# counting real time underneath.
class TestClockSet < Minitest::Test
  # The chip's own time: a Thursday evening, on the second.
  CHIP = Time.new(2026, 10, 22, 21, 7, 5)
  TIME = RubyGBA::IR::Clock::TIME
  QUESTIONS = %i[present set].freeze

  # A game that sets the clock to +to+ (year, month, day, hour, minute, second) on a pass that A is
  # pressed on, and keeps each reading and answer in a variable of the same name every pass.
  private def program(to)
    b = Builder.new
    b.instance_eval do
      now = clock
      readings = TIME.to_h { |name| [name, var(name, -1)] }
      present = var :present, -1
      set = var :set, -1
      game_loop do
        pressed(:a).then do
          now.set!(year: to[0], month: to[1], day: to[2], hour: to[3], minute: to[4], second: to[5])
        end
        readings.each { |name, reading| reading.set! now.public_send(name) }
        present.set! 0
        set.set! 0
        now.present?.then { present.set! 1 }
        now.set?.then { set.set! 1 }
      end
    end
    b.finalize_program
    b.program
  end

  # +frames+ played from a chip reading +chip+, A pressed on +press+ (nil: never), and what the
  # game read on its last pass.
  private def readings(to, chip: CHIP, frames: 3, press: 1, save: nil, chip_set: true)
    player = game_player(save: save).clock_at(chip, set: chip_set)
    player.input_each_frame { |frame| frame == press ? [:a] : [] }
    player.run(program(to), frames: frames)
    (TIME + QUESTIONS).to_h { |name| [name, player[name]] }
  end

  private def time_of(time) = { year: time.year, month: time.month, day: time.day, hour: time.hour,
                                minute: time.min, second: time.sec, weekday: time.wday }

  def test_a_game_reads_the_time_it_set
    assert_equal time_of(Time.new(2030, 6, 15, 12, 0, 0)).merge(present: 1, set: 1),
                 readings([2030, 6, 15, 12, 0, 0])
  end

  # The chip goes on counting: sixty frames are a second, as before the clock was set.
  def test_the_time_set_moves_on_with_the_chip
    assert_equal 1, readings([2030, 6, 15, 12, 0, 0], frames: 63)[:second]
  end

  # A second before the new year turns over into it, a Friday.
  def test_the_time_set_runs_on_into_the_next_year
    assert_equal time_of(Time.new(2027, 1, 1, 0, 0, 0)).merge(present: 1, set: 1),
                 readings([2026, 12, 31, 23, 59, 59], frames: 63)
  end

  # A day past the end of its month runs into the next, as a calendar counts: 2026 has no
  # 30th of February, so it is the 2nd of March.
  def test_a_day_past_the_end_of_its_month_runs_into_the_next
    assert_equal [2026, 3, 2], readings([2026, 2, 30, 8, 0, 0]).values_at(:year, :month, :day)
  end

  def test_a_leap_years_29th_of_february_is_a_day_of_its_own
    assert_equal [2028, 2, 29, 2], readings([2028, 2, 29, 8, 0, 0]).values_at(:year, :month, :day, :weekday)
  end

  # The time set is kept in the game's save, so the console off and on again an hour later
  # reads an hour on from it, with nobody setting it again.
  def test_the_time_set_survives_the_power_going_off
    image = RubyGBA::IR::SaveImage.new
    readings([2030, 6, 15, 12, 0, 0], save: image)

    later = readings([2030, 6, 15, 12, 0, 0], chip: CHIP + 3600, press: nil, save: image)
    assert_equal time_of(Time.new(2030, 6, 15, 13, 0, 0)).merge(present: 1, set: 1), later
  end

  # A chip whose battery ran out is there and was never set; the game can set it all the same,
  # since what it keeps is the difference from the chip's count, whatever that count is.
  def test_a_chip_never_set_reads_the_time_the_game_sets
    before = readings([2030, 6, 15, 12, 0, 0], press: nil, chip: Time.new(2000, 1, 1, 0, 0, 7), chip_set: false)
    after = readings([2030, 6, 15, 12, 0, 0], chip: Time.new(2000, 1, 1, 0, 0, 7), chip_set: false)

    assert_equal({ present: 1, set: 0, hour: 0 }, before.slice(:present, :set, :hour))
    assert_equal time_of(Time.new(2030, 6, 15, 12, 0, 0)).merge(present: 1, set: 1), after
  end
end
