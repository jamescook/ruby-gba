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

  private def readings_after(frames, start)
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
    skip_on_js "makes a pass take several frames with `frames_each_pass`, which only the interpreter can"
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
    assert_equal({ present: 1, set: 0, hour: 0 },
                 answers(game_player.clock_at(Time.new(2000, 1, 1, 5), set: false).run(asking_program, frames: 2)))
  end

  def test_a_clock_that_was_set_says_both
    assert_equal({ present: 1, set: 1, hour: 21 }, answers(game_player.clock_at(THURSDAY).run(asking_program, frames: 2)))
  end

  # --- setting it ----------------------------------------------------------------

  # A Saturday morning five years on.
  SATURDAY = { year: 2031, month: 5, day: 17, hour: 8, minute: 9, second: 10 }.freeze

  # A game that sets the clock to +to+ on its third pass, and otherwise keeps each reading in a
  # variable of the same name, and 1 in :set while the clock says it was set.
  private def setting_program(to = SATURDAY)
    b = Builder.new
    b.instance_eval do
      now = clock
      passes = var :passes, 0
      set = var :set, 0
      readings = TIME.to_h { |name| [name, var(name, -1)] }
      game_loop do
        (passes == 2).then { now.set_to(**to) }
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

  # ...and from there it keeps time, the part of a second the clock was into carrying on as it
  # was: the clock started on a whole second, so it turns over sixty frames from the start, as
  # it would have with nothing set.
  def test_a_clock_set_moves_on_from_the_time_set
    assert_equal 10, game_player.clock_at(THURSDAY).run(setting_program, frames: 59)[:second]
    assert_equal 11, game_player.clock_at(THURSDAY).run(setting_program, frames: 60)[:second]
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

  # THE TIME SET IS THERE THE NEXT TIME THE GAME IS SWITCHED ON: switched off for an hour, it
  # reads the time it set an hour on, plus the frames each run played.
  def test_the_time_set_comes_back_after_the_power_goes_off
    store = SaveImage.new(kilobytes: 32)
    game_player(save: store).clock_at(THURSDAY).run(setting_program, frames: 30)
    back = game_player(save: store).clock_at(THURSDAY + 3600 + 1).run(asking_and_reading_program, frames: 1)

    assert_equal [9, 9, 11], readings_of(back).values_at(:hour, :minute, :second)
  end

  # A game that only reads the clock, after one that set it, so nothing sets it again.
  private def asking_and_reading_program
    b = Builder.new
    b.instance_eval do
      now = clock
      readings = TIME.to_h { |name| [name, var(name, -1)] }
      game_loop { readings.each { |name, reading| reading.set! now.public_send(name) } }
      # The same saved numbers as the game that set it, declared by setting it where it never runs.
      func(:never_called) { now.set_to(**SATURDAY) }
    end
    b.finalize_program
    b.program
  end
end
