# frozen_string_literal: true

require "test_helper"

# {TickRate} counted off a REAL RUN, through `rom.profile`.
#
# The half that cannot be faked: finding each timer's handler inside the one routine
# the console interrupts into, and counting the ticks that really arrived.
class TestTickRateMeasured < Minitest::Test
  include GembaSupport

  def setup
    require_gemba_core!
  end

  # +work+ is how many times the handler spins; +clears+ how many full-screen fills the
  # frame does. Both are the two things that cost ticks, and this can make either.
  def rom_for(rate:, work: 0, clears: 1, name: "TICK")
    RubyGBA.build(name, code: "TCKM", maker: "01", validate: false) do
      screen :bitmap
      beats = var :beats, 0
      spin = var :spin, 0
      t = timer :beat, per_second: rate
      t.on_tick do
        beats.add 1
        repeat(work) { spin.add 1 } if work.positive?
      end
      game_loop do
        clears.times { |i| clear_screen(i.even? ? :black : :blue) }
      end
    end
  end

  def rate_of(rom) = RubyGBA::Profiler.run(rom, frames: 60, picture: false).tick_rates.first

  # THE MECHANISM. A game that draws nothing gets every tick it asked for, which is what
  # says the handler was found and the ticks counted against real time correctly.
  def test_a_timer_with_nothing_in_its_way_delivers_its_rate
    reading = rate_of(rom_for(rate: 4096, clears: 0))

    assert_predicate reading, :measured?
    assert_equal :beat, reading.name
    assert_equal 4096, reading.asked
    assert_in_delta 1.0, reading.share, 0.02
    refute_predicate reading, :short?
  end

  def test_a_handler_too_long_to_keep_up_loses_ticks
    reading = rate_of(rom_for(rate: 16_384, work: 200, clears: 0))

    assert_predicate reading, :short?
    assert_operator reading.share, :<, 0.6
  end

  # A slow timer over the window has too few ticks to read, and says so rather than
  # guessing.
  def test_a_slow_timer_is_not_judged_over_a_short_run
    refute_predicate rate_of(rom_for(rate: 4, clears: 0)), :measured?
  end

  # WHY THERE IS NO WARNING HERE, pinned as a measurement so nobody rebuilds one.
  #
  # A handler that does ONE ADDITION, in a game whose only other work is ordinary
  # full-screen fills. A transfer stalls the console and holds interrupts off while it
  # runs, so the ticks go missing with nothing wrong in the handler at all — and it
  # reaches further down than the halving a genuinely slow handler causes. Any threshold
  # on "delivered against asked" would fire on this game.
  def test_ordinary_drawing_costs_more_ticks_than_a_slow_handler_would
    trivial_handler = rate_of(rom_for(rate: 4096, work: 0, clears: 4))

    assert_predicate trivial_handler, :measured?
    assert_operator trivial_handler.share, :<, 0.5,
                    "four full-screen fills cost more than half the ticks, with a one-line handler"
  end

  # ...and the same game drawing less keeps its ticks, so the drawing is what did it.
  def test_the_same_handler_keeps_its_ticks_when_the_game_draws_less
    assert_operator rate_of(rom_for(rate: 4096, work: 0, clears: 0)).share, :>,
                    rate_of(rom_for(rate: 4096, work: 0, clears: 4)).share + 0.4
  end

  # What the author reads: the number, and both causes, with neither asserted.
  def test_the_report_gives_the_number_and_does_not_blame_the_handler
    out = StringIO.new
    RubyGBA::Profiler.render(
      RubyGBA::Profiler.run(rom_for(rate: 4096, clears: 4), frames: 60, picture: false), out: out
    )
    said = out.string

    assert_match(/timer :beat asked for 4096 ticks a second and is getting/, said)
    assert_match(/either the `on_tick` body is too long/, said)
    assert_match(/or drawing is holding interrupts off/, said)
  end

  def test_a_timer_keeping_up_prints_nothing_about_itself
    out = StringIO.new
    RubyGBA::Profiler.render(
      RubyGBA::Profiler.run(rom_for(rate: 4096, clears: 0), frames: 60, picture: false), out: out
    )

    refute_match(/timer :beat/, out.string)
  end

  # A game with no timer at all has nothing to say and no line to print.
  def test_a_game_with_no_timer_reads_nothing
    rom = RubyGBA.build("NOTIMER", code: "TCKN", maker: "01", validate: false) do
      screen :bitmap
      game_loop { clear_screen :black }
    end

    assert_empty RubyGBA::Profiler.run(rom, frames: 20, picture: false).tick_rates
  end
end
