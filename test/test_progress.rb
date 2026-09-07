# frozen_string_literal: true

require "test_helper"

require "stringio"

# WHAT A BUILD SAYS IT IS DOING (lib/ruby_gba/progress.rb).
#
# A big game takes a while to build, and a build that says nothing is indistinguishable from one
# that has hung. These check the thing a build talks to: that the default says nothing at all,
# that one pointed at a stream says the phases in order with what each took, and that a phase
# reporting tens of thousands of times does not turn into tens of thousands of lines.
class TestProgress < Minitest::Test
  Progress = RubyGBA::Progress

  # A clock that only moves when a test moves it, so an elapsed time is a fact rather than a
  # race. It answers the one question Progress asks of a clock.
  class FakeClock
    def initialize = @now = 0.0
    def clock_gettime(_kind) = @now
    def pass(seconds) = @now += seconds
  end

  def a_terminal
    out = StringIO.new
    def out.tty? = true
    out
  end

  # --- THE ONE THAT SAYS NOTHING ---------------------------------------------------------------

  # It is the DEFAULT, so every method has to be here. A caller asking "is anybody listening?"
  # before every line is forty chances to forget one, and reads as uncertainty about something
  # that is never uncertain.
  def test_the_silent_one_answers_every_method
    quiet = Progress.silent

    assert_nil quiet.step("anything")
    assert_nil quiet.of(1, 2, "anything")
    assert_nil quiet.tick
    assert_nil quiet.done
  end

  def test_the_silent_one_is_what_a_build_gets_unless_it_asks
    err = StringIO.new
    RubyGBA.build("QUIET", code: "AQUI", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      fill_rect 0, 0, 8, 8, :red
      halt
    end

    refute_match(/lowering|the guardrails|checking the tree/, err.string,
                 "a build that did not ask for progress should not talk about itself")
  end

  # --- THE ONE THAT WRITES ---------------------------------------------------------------------

  def test_it_names_each_phase_in_the_order_they_happened
    out = StringIO.new
    progress = Progress::Printed.new(out, clock: FakeClock.new)
    %w[reading checking lowering].each { |phase| progress.step(phase) }
    progress.done

    assert_equal %w[reading checking lowering], out.string.lines.map { |line| line.split.first }
  end

  # A phase's time is written when the phase ENDS, so it is only ever reported once it really
  # has elapsed — which is why starting the next phase is what closes the last.
  def test_each_phase_says_how_long_it_took
    clock = FakeClock.new
    out = StringIO.new
    progress = Progress::Printed.new(out, clock: clock)

    progress.step("reading")
    clock.pass(2.5)
    progress.step("lowering")
    clock.pass(41.0)
    progress.done

    assert_match(/reading\s+2\.5s/, out.string)
    assert_match(/lowering\s+41\.0s/, out.string)
  end

  def test_a_countable_phase_says_where_it_got_to
    out = a_terminal
    progress = Progress::Printed.new(out, clock: FakeClock.new)
    progress.step("the guardrails")
    progress.of(27, 27, "DrawBudget")
    progress.done

    assert_match(/the guardrails.*27 of 27\s+DrawBudget/, out.string)
  end

  # --- A PHASE THAT REPORTS TENS OF THOUSANDS OF TIMES -----------------------------------------

  # THE ONE THAT WOULD COST MORE THAN IT REPORTS. Lowering ticks per instruction; printing that
  # often would be slower than the work being described, so the SINK decides when to draw.
  def test_a_hundred_thousand_ticks_is_not_a_hundred_thousand_lines
    clock = FakeClock.new
    out = a_terminal
    progress = Progress::Printed.new(out, clock: clock)
    progress.step("lowering")
    100_000.times do |n|
      clock.pass(0.001) # a hundred seconds of ticking, in total
      progress.tick
      _ = n
    end
    progress.done

    # A line at most every tenth of a second over a hundred seconds is about a thousand, and
    # the point is only that it is bounded by the CLOCK rather than by the tick count.
    written = out.string.count("\r")

    assert_operator written, :<, 2_000, "the sink should throttle, not print every tick"
    assert_operator written, :>, 100, "...but it should still be showing progress"
  end

  def test_ticking_costs_nothing_worth_measuring_when_nobody_is_listening
    quiet = Progress.silent
    from = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    1_000_000.times { quiet.tick }
    spent = Process.clock_gettime(Process::CLOCK_MONOTONIC) - from

    assert_operator spent, :<, 1.0, "a million ticks into the silent one should be free"
  end

  # --- WHERE IT IS WRITING DECIDES HOW MUCH IT SHOWS -------------------------------------------

  # A log is read afterwards and a carriage return in one is noise, so anywhere but a terminal
  # gets one tidy line per phase and nothing in between.
  def test_a_log_gets_one_line_per_phase_and_no_rewriting
    out = StringIO.new
    progress = Progress::Printed.new(out, clock: FakeClock.new)
    progress.step("lowering")
    500.times { progress.tick }
    progress.done

    assert_equal 1, out.string.lines.length
    refute_includes out.string, "\r"
  end

  # ...and a terminal gets one line kept and rewritten, which is what reads as a build getting
  # on with it rather than a wall of text.
  def test_a_terminal_gets_one_line_kept_and_rewritten
    clock = FakeClock.new
    out = a_terminal
    progress = Progress::Printed.new(out, clock: clock)
    progress.step("lowering")
    3.times do
      clock.pass(1.0)
      progress.of(1, 3)
    end
    progress.done

    assert_includes out.string, "\r"
    assert_equal 1, out.string.lines.length, "a rewritten line is still one line"
  end

  # --- THROUGH A REAL BUILD --------------------------------------------------------------------

  def test_a_real_build_names_its_phases_in_order
    out = StringIO.new
    RubyGBA.build("SPEAK", code: "ASPK", maker: "01", out: StringIO.new, err: StringIO.new,
                          progress: Progress.to(out)) do
      screen :bitmap
      fill_rect 0, 0, 8, 8, :red
      halt
    end

    phases = out.string.lines.map(&:strip)

    assert_match(/\Areading the game/, phases.first)
    assert(phases.any? { |line| line.start_with?("the guardrails") })
    assert(phases.any? { |line| line.start_with?("lowering it to machine code") })
    assert_match(/\Aassembling the cartridge/, phases.last)
  end

  def test_a_game_can_be_asked_to_report_when_it_builds_its_rom
    out = StringIO.new
    game = RubyGBA.game("SPEAK", code: "ASPK", maker: "01") do
      screen :bitmap
      fill_rect 0, 0, 8, 8, :red
      halt
    end
    game.build_rom(out: StringIO.new, err: StringIO.new, progress: Progress.to(out))

    assert_match(/reading the game/, out.string)
  end
end
