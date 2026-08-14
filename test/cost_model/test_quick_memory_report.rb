# frozen_string_literal: true

require_relative "helper"

# WHAT THE REPORT SAYS ABOUT THE CONSOLE'S QUICK MEMORY.
#
# The framework decides on its own which routines to keep there, and code kept there runs about
# two and a half times faster. That is the one decision it makes that changes how fast a game
# runs without changing a line of it, so it does not get to be invisible — and the half that was
# invisible was the interesting half: a routine the frame spends real time in that JUST MISSED
# fitting is exactly where a program lost the factor, and a finished build had no way to say so.
#
# WHY A ROUTINE IS TOO BIG is the other thing an author cannot find out. Code is emitted where it
# is written, so a plain Ruby helper called from eight places is emitted eight times — a fact
# with a one-word fix and nothing anywhere to learn it from.
class TestQuickMemoryReport < Minitest::Test
  include CostArith

  # A program with one heavy routine and enough other heavy ones to crowd the memory, so the
  # chooser has to leave something out. +helper+ picks how the big routine got big: a Ruby method
  # called from many places, or one call site repeated.
  def crowded(helper:)
    RubyGBA.build("QMEM", code: "ZQME", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      spin = var :spin, 0

      # A helper written once, over SEVERAL LINES, which is what one looks like. Called from a
      # build block it runs at every call and records its ops where it was called, so calling it
      # from many places emits every one of those lines that many times.
      lump = lambda do
        spin.add 1
        spin.add 2
        spin.add 3
        spin.add 4
        spin.add 5
        spin.sub 6
      end

      func(:crowded_out) do
        if helper
          400.times { lump.call }
        else
          2400.times { spin.add 1 }
        end
      end

      # ...and several routines the frame spends more time in, so the big one is reached last.
      6.times { |n| func(:"hot#{n}") { 300.times { spin.add 1 } } }
      game_loop do
        6.times { |n| repeat(50) { call :"hot#{n}" } }
        call :crowded_out
      end
    end
  end

  def report_of(rom)
    io = StringIO.new
    rom.cost_model.render(rom.source_program, out: io)
    io.string
  end

  def test_it_says_how_big_each_routine_it_kept_is
    report = report_of(crowded(helper: true))

    assert_match(/kept in quick memory/, report)
    assert_match(/[\d.]+K\s+func :hot0/, report, "each routine it kept should carry its size")
  end

  # THE HALF THAT WAS MISSING. A routine that did not fit is where the factor was lost, and the
  # numbers an author needs to act are what it wanted and what was left.
  def test_it_names_what_did_not_fit_and_by_how_much
    report = report_of(crowded(helper: true))

    assert_match(/func :crowded_out did not fit/, report)
    assert_match(/it needs [\d.]+K and [\d.]+K was left/, report)
    assert_match(/runs from the cartridge/, report)
  end

  # A HELPER EMITTED MANY TIMES is told, because the fix is one word and nothing else says so.
  # The evidence is several DIFFERENT lines each emitted the same number of times.
  def test_a_helper_called_from_many_places_is_named_as_one
    report = report_of(crowded(helper: true))

    assert_match(/most repeated line is .+:\d+, emitted \d+ times/, report)
    assert_match(/Several lines repeat together/, report)
    assert_match(/`func` is emitted once/, report)
  end

  # ...and a routine that is big for the OTHER reason is not given that advice, because it would
  # be wrong. One line repeating is one verb whose own expansion is large — a live number lays
  # out all ten shapes for every digit place — and no `func` makes that smaller.
  def test_one_line_repeating_gets_the_count_but_not_the_advice
    report = report_of(crowded(helper: false))

    assert_match(/func :crowded_out did not fit/, report)
    refute_match(/Several lines repeat together/, report)
  end

  # A program whose routines all fit says nothing about any of this, rather than a line saying
  # nothing was left out.
  def test_a_program_that_fits_says_nothing_about_what_did_not
    small = RubyGBA.build("QFIT", code: "ZQFI", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      spin = var :spin, 0
      func(:tiny) { spin.add 1 }
      game_loop { call :tiny }
    end

    refute_match(/did not fit/, report_of(small))
  end
end
