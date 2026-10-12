# frozen_string_literal: true

require "test_helper"

# What paces the window's frames, worked out from how often the monitor refreshes
# (runtime/rg_pacing.h). The console draws a little under sixty frames a second. A monitor that
# refreshes at very nearly a whole number of times that rate paces the game itself, each picture
# shown for that many refreshes, and the game runs as much faster or slower as the two rates
# differ. Any other monitor, and one that does not say its rate, leaves the pacing to the
# console's own clock.
class TestNativePacing < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  Zig = RubyGBA::IR::Backends::Native::Zig
  HARNESS = Ractor.make_shareable(File.expand_path("pacing_harness.c", __dir__))

  # The console's frames a second: 2^24 ticks of its clock a second, 280,896 of them a frame.
  CONSOLE = Rational(16_777_216, 280_896)

  # A monitor's refreshes a second, and how many of them each picture is shown for.
  PACED_BY_THE_MONITOR = { 60.0 => 1, 59.94 => 1, 59.0 => 1, 61.0 => 1, 120.0 => 2, 119.88 => 2,
                           180.0 => 3, 240.0 => 4, 360.0 => 6 }.freeze
  # Monitors the console's clock paces the game on, but faster than the console, so each picture
  # can still wait for a refresh and never be shown torn: 75, 144 and 165 are no whole number of
  # the console's frames, and 62, 117 and 123 are too far either side of one and of two.
  FASTER_THAN_THE_CONSOLE = [75.0, 144.0, 165.0, 62.0, 117.0, 123.0].freeze
  # ...and ones where waiting for a refresh would slow the game, or cannot be trusted: slower
  # than the console, or a monitor that says nothing, or nonsense.
  NOT_WAITED_FOR = [58.0, 50.0, 30.0, 0.0, -60.0, 1.0e12].freeze

  def test_a_monitor_at_a_whole_number_of_the_consoles_rate_paces_the_game
    answers = pacing_for(PACED_BY_THE_MONITOR.keys)

    PACED_BY_THE_MONITOR.each do |rate, refreshes|
      shown_for, waits, speed = answers.fetch(rate)

      assert_equal refreshes, shown_for, "a #{rate}Hz monitor should show each picture for #{refreshes} refreshes"
      assert_equal 1, waits, "waiting for each of them (#{rate}Hz)"
      assert_in_delta rate / refreshes / CONSOLE, speed, 1e-6, "and the game should run as fast as that makes it (#{rate}Hz)"
    end
  end

  def test_any_other_monitor_leaves_the_pacing_to_the_consoles_clock
    answers = pacing_for(FASTER_THAN_THE_CONSOLE + NOT_WAITED_FOR)

    FASTER_THAN_THE_CONSOLE.each do |rate|
      assert_equal [0, 1, 1.0], answers.fetch(rate), "a #{rate}Hz monitor should not pace the game, and each picture should wait for a refresh"
    end
    NOT_WAITED_FOR.each do |rate|
      assert_equal [0, 0, 1.0], answers.fetch(rate), "a #{rate}Hz monitor should not pace the game or be waited for"
    end
  end

  # Showing a picture waits for nothing while the window is hidden, so where the monitor paces
  # the game a limit stands behind it: two hundredths faster than the monitor's own frames, with
  # four frames let through at once. A frame here comes round a millisecond after the one before
  # unless the limit holds it, on a 60Hz monitor and on a 120Hz one, where a frame is two
  # refreshes and so the same sixtieth of a second.
  #
  # The first frame and the four let through come a millisecond apart. The sixth is held until a
  # fastest frame after the first, and each of the rest a fastest frame after the one before: 595
  # held, the last of them 595 fastest frames after the first, which came a millisecond in.
  def test_a_game_nothing_is_holding_is_held_to_a_shade_over_the_monitors_pace
    fastest_frame = 1_000_000_000 / 60.0 / 1.02

    [60, 120].each do |rate|
      held, took = frames_played(rate, [1_000_000, 600])

      assert_equal 595, held, "all but the first and the four let through should have been held (#{rate}Hz)"
      assert_in_delta (595 * fastest_frame) + 1_000_000, took, 1_000, "and those a fastest frame apart (#{rate}Hz)"
    end
  end

  # ...and a game the monitor IS holding, a frame every sixtieth of a second, is never held by it.
  def test_a_game_the_monitor_is_holding_is_left_alone
    held, took = frames_played(60, [16_666_667, 600])

    assert_equal [0, 600 * 16_666_667], [held, took]
  end

  # However long the game stood still, no more than the four frames let through come at once
  # afterwards. One frame comes ten seconds late, and then twenty a millisecond apart: four of
  # those get through, and the other sixteen are held.
  def test_a_long_pause_earns_no_more_than_the_few_frames_let_through
    late, then_free, = frames_played(60, [10_000_000_000, 1], [1_000_000, 20])

    assert_equal [0, 16], [late, then_free]
  end

  private

  # What the C answers for each rate, as { rate => [refreshes a picture, 1 when a picture waits
  # for a refresh, speed] }.
  def pacing_for(rates)
    answers = asked(rates.map { |rate| "monitor #{rate}" })
    rates.zip(answers.map { |refreshes, waits, speed| [refreshes.to_i, waits.to_i, speed.to_f] }).to_h
  end

  # One run of frames on a monitor of +rate+, in +legs+ of [gap, count]: count frames, each
  # coming round gap nanoseconds after the one before unless the limit holds it longer. Gives how
  # many frames of each leg the limit held, and then how long the whole run took.
  def frames_played(rate, *legs) = asked(["frames #{rate} #{legs.length} #{legs.flatten.join(' ')}"]).first.map(&:to_i)

  # The harness's answers to +questions+, a line each, split into words — at both of the
  # settings the backend is built at, which have to agree.
  def asked(questions)
    checked, fast = %i[checked fast].map do |mode|
      exe = Zig.compile_without_sdl([HARNESS], mode: mode)
      Zig.run_program(exe, input: questions.map { |question| "#{question}\n" }.join).lines.map(&:split)
    end
    assert_equal checked, fast, "the checked and the optimised build should answer alike"
    checked
  end
end
