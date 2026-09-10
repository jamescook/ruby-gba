# frozen_string_literal: true

require "test_helper"

# {TickRate} — what rate is a timer really delivering?
#
# The rule is a pure comparison, so it is tested as one here. The half that has to
# run on the console is in test_tick_rate_measured.rb.
class TestTickRateRule < Minitest::Test
  TickRate = RubyGBA::TickRate

  def read(asked:, ticks:, seconds: 1.0)
    TickRate.read(name: :beat, asked: asked, ticks: ticks, seconds: seconds)
  end

  def test_a_timer_keeping_up_says_nothing
    reading = read(asked: 4000, ticks: 4000)

    assert_predicate reading, :measured?
    refute_predicate reading, :short?
  end

  def test_a_timer_getting_half_its_ticks_is_worth_saying
    reading = read(asked: 4000, ticks: 2000)

    assert_predicate reading, :short?
    assert_equal 4000, reading.asked
    assert_equal 2000, reading.got
    assert_in_delta 0.5, reading.share
  end

  # A tick either way is a counting boundary, not something to print.
  def test_a_tick_either_way_says_nothing
    refute_predicate read(asked: 4000, ticks: 3999), :short?
    refute_predicate read(asked: 4000, ticks: 4001), :short?
  end

  # THE NOISE CASE, and it has nothing to do with the frame rate: a slow timer over a
  # short window has too few ticks for a ratio to mean anything. Four a second over a
  # second is four ticks, where one either way is a quarter of the answer.
  def test_a_timer_too_slow_to_judge_says_nothing
    reading = read(asked: 4, ticks: 2)

    refute_predicate reading, :measured?
    refute_predicate reading, :short?, "an unmeasured reading is never reported"
  end

  # ...and the same slow timer over a long enough run IS read.
  def test_the_same_slow_timer_over_a_long_run_is_read
    reading = read(asked: 4, ticks: 20, seconds: 10.0)

    assert_predicate reading, :measured?
    assert_predicate reading, :short?
    assert_equal 2, reading.got
  end

  def test_a_run_of_no_length_says_nothing
    refute_predicate read(asked: 4000, ticks: 0, seconds: 0.0), :measured?
  end

  # "We could not tell" must never read as "nothing was wrong".
  def test_an_unmeasured_reading_says_so
    reading = TickRate::Reading.unmeasured(:beat, 4000)

    refute_predicate reading, :measured?
    refute_predicate reading, :short?
    assert_in_delta 0.0, reading.share
  end

  # THE DENOMINATOR IS REAL TIME, NOT FRAMES OF THE GAME. Sixty hardware frames is one
  # second whether the game finished sixty passes in them or thirty, so the same ticks
  # over the same window read the same. This is the false alarm the design has to avoid:
  # measuring against passes would report every frame-dropping game as losing ticks.
  def test_the_reading_is_about_real_time_not_the_games_pace
    one_second = 60 / 60.0
    at_sixty = read(asked: 4000, ticks: 4000, seconds: one_second)
    # The same run of a game managing only thirty passes: the same hardware frames, the
    # same real time, the same ticks.
    at_thirty = read(asked: 4000, ticks: 4000, seconds: one_second)

    assert_equal at_sixty.got, at_thirty.got
    refute_predicate at_thirty, :short?
  end
end
