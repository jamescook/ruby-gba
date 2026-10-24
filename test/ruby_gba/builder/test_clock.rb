# frozen_string_literal: true

require "test_helper"

# THE DATE AND TIME, READ BY THE GAME. `clock` hands back the clock a cartridge carries, and its
# readings are numbers like any variable's. A test says what time the clock starts at, the way it
# says which buttons are held, and the time moves on one of the console's frames each frame — a
# little more than a sixtieth of a second.
class TestClock < Minitest::Test
  # A Thursday evening.
  THURSDAY = Time.new(2026, 10, 22, 21, 7, 5)
  TIME = RubyGBA::IR::Clock::TIME

  # A game that keeps each reading of the clock in a variable of the same name, every pass.
  private def program
    b = Builder.new
    b.instance_eval do
      now = clock
      readings = TIME.to_h { |name| [name, var(name, -1)] }
      game_loop do
        readings.each { |name, reading| reading.set! now.public_send(name) }
      end
    end
    b.finalize_program
    b.program
  end

  private def skip_where_there_is_no_clock_yet
    skip_on_js "the browser build has no clock yet"
  end

  private def readings_after(frames, start)
    skip_where_there_is_no_clock_yet
    player = game_player.clock_at(start).run(program, frames: frames)
    TIME.to_h { |name| [name, player[name]] }
  end

  def test_a_game_reads_the_moment_the_clock_was_started_at
    assert_equal({ hour: 21, minute: 7, second: 5, year: 2026, month: 10, day: 22, weekday: 4 },
                 readings_after(1, THURSDAY))
  end

  # The readings a run ends with are the last pass's, which saw every frame the run played.
  def test_sixty_frames_are_a_second
    assert_equal 5, readings_after(59, THURSDAY)[:second]
    assert_equal 6, readings_after(60, THURSDAY)[:second]
  end

  # A clock started half way through a second, as a test handed the time now starts one, turns
  # over half a second sooner: thirty frames are a little more than that.
  def test_a_clock_started_part_way_through_a_second_turns_over_sooner
    halfway = THURSDAY + Rational(1, 2)

    assert_equal 5, readings_after(29, halfway)[:second]
    assert_equal 6, readings_after(30, halfway)[:second]
  end

  # A second before the new year: the date rolls over with the time, to a Friday.
  def test_the_date_rolls_over_at_midnight_on_new_years_eve
    assert_equal({ hour: 0, minute: 0, second: 0, year: 2027, month: 1, day: 1, weekday: 5 },
                 readings_after(60, Time.new(2026, 12, 31, 23, 59, 59)))
  end

  # A second before two in the morning on the day much of the world puts its clocks forward: a
  # clock holds the local time it was set to and counts on one second a second, so it reads two
  # o'clock, never three — whatever time zone the machine running the test is in.
  def test_the_clock_counts_through_a_change_to_summer_time
    assert_equal [2, 0, 0], readings_after(60, Time.new(2026, 3, 8, 1, 59, 59)).values_at(:hour, :minute, :second)
  end

  # A pass the console took three frames over still lets three frames of time go by: the clock
  # keeps real time, not the game's. Twenty passes of three frames are a second.
  def test_a_late_pass_lets_its_frames_of_time_go_by
    skip_on_native "makes a pass take several frames with `frames_each_pass`, which only the interpreter can"
    skip_where_there_is_no_clock_yet
    player = game_player.clock_at(THURSDAY).frames_each_pass { 3 }.run(program, frames: 20)

    assert_equal 6, player[:second]
  end

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
    skip_where_there_is_no_clock_yet

    assert_equal({ present: 1, set: 0, hour: 0 },
                 answers(game_player.clock_at(Time.new(2000, 1, 1, 5), set: false).run(asking_program, frames: 2)))
  end

  def test_a_clock_that_was_set_says_both
    skip_where_there_is_no_clock_yet

    assert_equal({ present: 1, set: 1, hour: 21 }, answers(game_player.clock_at(THURSDAY).run(asking_program, frames: 2)))
  end
end
