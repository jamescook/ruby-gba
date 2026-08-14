# frozen_string_literal: true

require_relative "helper"
require "tmpdir"

# A COLUMN WHOSE HEIGHT THE GAME WORKS OUT, and what a frame should be told it costs.
#
# `draw_column_at` stretches one column of a picture to a height. When that height is a number
# written in the program the model counts its rows and is done. When the game works it out there
# is no size a build can prove — and that is EVERY column of a first-person view, because
# working the height out from a distance is what perspective is.
#
# It used to be charged its divide and nothing else. So eighty wall columns came to the price of
# eighty divides, and the estimate could not see a renderer at all.
#
# WHY THIS ONE CAN BE ANSWERED where a computed loop count cannot: a column is CLIPPED, so
# however tall it is drawn it can never walk more rows than the screen has. That ceiling is a
# fact about the hardware rather than a guess about the game.
class TestStretchedColumn < Minitest::Test
  include CostArith

  Cost = RubyGBA::IR::CostModel
  COLUMNS = 60
  WIDE = 3

  # +tall+ rows per column, COLUMNS of them. +told+ passes the estimate hint; +fixed+ writes the
  # height as a number in the program instead of working it out; +area+ wraps it in an `inside`.
  def columns(tall, told: nil, fixed: false, area: nil)
    RubyGBA.build("COLS", code: "ZCOL", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap, tear_free: true
      image :strip, width: 8, height: 8, data: Array.new(64) { |n| (n % 30) + 1 }
      h = var :h, tall
      game_loop do
        body = lambda do
          repeat(COLUMNS) do |col|
            draw_column_at :strip, slice: 0, x: col * WIDE, top: 0,
                                   height: fixed ? tall : h, width: WIDE, estimate: told
          end
        end
        area ? inside(0, 0, 240, area) { body.call } : body.call
      end
    end
  end

  def steady(rom) = rom.cost_model.steady_cost(rom.source_program)

  def report_of(rom)
    io = StringIO.new
    rom.cost_model.render(rom.source_program, out: io)
    io.string
  end

  # THE HEART OF IT. The same eighty columns cost the same whether the height was written down
  # or worked out — priced as nothing, the worked-out one came to a fiftieth of the other.
  def test_a_worked_out_height_is_not_free
    worked_out = steady(columns(64))

    assert_operator worked_out, :>, steady(columns(1, told: { usually: 1 })) * 4,
                    "a column that walks sixty-four rows must cost more than one that walks one"
  end

  # ...and the author can say how tall, which is the only way anything can know. Told the truth,
  # it lands on what a column written at that height costs.
  # Not to the last decimal: a height the game works out is READ from a variable every column,
  # where one written in the program is not, and that read is real work the model is right to
  # charge. Everything else about the two is the same.
  def test_saying_how_tall_is_what_gets_counted
    assert_in_delta steady(columns(64, fixed: true)), steady(columns(64, told: { usually: 64 })),
                    steady(columns(64, fixed: true)) * 0.01,
                    "told sixty-four, it should cost about what sixty-four rows cost"
    assert_operator steady(columns(16, told: { usually: 16 })), :<,
                    steady(columns(64, told: { usually: 64 })),
                    "and a shorter column should cost less"
  end

  # Unsaid, it guesses half the rows it is allowed and the report says so. Half rather than the
  # quarter a list guesses, because heights above the ceiling PILE UP at it — a wall you are
  # close to is clipped, not drawn shorter.
  def test_unsaid_it_guesses_half_the_ceiling_and_says_so
    assert_in_delta steady(columns(999, told: { usually: 80 })), steady(columns(999)), 0.01,
                    "half of the screen's 160 rows"
    assert_includes report_of(columns(999)), "a stretched column counts the rows it usually draws"
    assert_includes report_of(columns(999)), "a guess"
  end

  def test_when_the_height_is_given_the_report_says_it_was_told
    report = report_of(columns(64, told: { usually: 64 }))

    assert_includes report, "the height you gave"
    refute_includes report, "a stretched column counts the rows it usually draws — :strip 64 of 160, a guess"
  end

  # AN AREA LOWERS THE CEILING, because a column is clipped to it. That is not a detail for a
  # first-person view with a status bar under it: the guess is half of what the column may reach,
  # so the area is the difference between a guess that is close and one that is a quarter out.
  def test_an_area_lowers_what_the_guess_is_half_of
    assert_in_delta steady(columns(999, area: 128, told: { usually: 64 })),
                    steady(columns(999, area: 128)), 0.01,
                    "inside a 128-row area, half is 64 rather than 80"
    assert_includes report_of(columns(999, area: 128)), "of 128"
  end

  # A height written in the program is priced exactly as it always was, and saying it twice is a
  # friendly error rather than two numbers that can disagree.
  def test_a_height_written_in_the_program_may_not_also_be_estimated
    error = assert_raises(ArgumentError) { columns(64, fixed: true, told: { usually: 64 }) }

    assert_match(/works out/, error.message)
  end

  # --- and against the console -------------------------------------------------------

  # WHAT IT REALLY COSTS. The whole point of the number is that an author decides by it, so it is
  # held against the emulator rather than against itself.
  def test_the_estimate_tracks_what_the_console_spends
    require_gemba_core!
    [[64, 64], [32, 32]].each do |tall, told|
      rom = columns(tall, told: { usually: told })
      Dir.mktmpdir do |dir|
        path = File.join(dir, "c.gba")
        rom.write(path)
        probe = RubyGBA::Emulator.probe(path)
        probe.step(12)
        console = 3.times.map { 15.times.map { RubyGBA::Analyzer.frame_scanlines(probe.frame_cost) }.max }.min
        probe.close

        assert_in_delta 1.0, steady(rom) / console, 0.15,
                        "#{tall} rows a column: estimate #{steady(rom)}, console #{console}"
      end
    end
  end
end
