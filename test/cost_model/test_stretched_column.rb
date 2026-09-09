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

  # --- the same wall, drawn as a rectangle ---------------------------------------------

  # A GAME CAN WRITE A WALL EITHER WAY: as a column of a picture, or as a plain rectangle as
  # tall as the distance says. The reasoning above is about a HEIGHT and not about a picture, so
  # it has to hold for both — and it did not. Measured on examples/raycaster.rb, which draws its
  # walls with `draw_rect_at`: thirty of them a frame came to nothing at all, and the estimate
  # read the game at half what the console spends.

  # +tall+ rows per rectangle, COLUMNS of them, on the same screen as the columns above so the
  # two are comparable.
  def rects(tall, told: nil, fixed: false, wide: nil)
    RubyGBA.build("RECT", code: "ZRCT", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap, tear_free: true
      h = var :h, tall
      w = var :w, WIDE
      game_loop do
        repeat(COLUMNS) do |col|
          draw_rect_at(col * WIDE, 0, wide ? w : WIDE, fixed ? tall : h, :red, estimate: told)
        end
      end
    end
  end

  def test_a_worked_out_rect_height_is_not_free
    worked_out = steady(rects(64))

    assert_operator worked_out, :>, steady(rects(1, told: { usually: 1 })) * 4,
                    "a rectangle sixty-four rows tall must cost more than one row"
  end

  def test_saying_how_tall_a_rect_is_is_what_gets_counted
    assert_in_delta steady(rects(64, fixed: true)), steady(rects(64, told: { usually: 64 })),
                    steady(rects(64, fixed: true)) * 0.02,
                    "told sixty-four, it should cost about what sixty-four rows cost"
  end

  def test_a_rect_unsaid_guesses_half_the_ceiling_and_says_so
    assert_in_delta steady(rects(999, told: { usually: 80 })), steady(rects(999)), 0.01,
                    "half of the screen's 160 rows"
    assert_includes report_of(rects(999)), "a stretched rectangle counts the rows it usually draws"
    assert_includes report_of(rects(999)), "a guess"
  end

  def test_when_a_rect_height_is_given_the_report_says_it_was_told
    assert_includes report_of(rects(64, told: { usually: 64 })), "the height you gave"
  end

  def test_a_rect_height_written_in_the_program_may_not_also_be_estimated
    error = assert_raises(ArgumentError) { rects(64, fixed: true, told: { usually: 64 }) }

    assert_match(/rectangle whose height the game works out/, error.message)
  end

  # A WIDTH IS DELIBERATELY NOT GUESSED, and the asymmetry is the argument rather than an
  # oversight: a height is clipped to the screen, so it has a ceiling to be measured against and
  # tall ones pile up at it. A width has no such story — a bar spreads evenly across its range —
  # so there is nothing to take half OF, and the estimate says it could not account for the
  # rectangle rather than inventing a number.
  def test_a_width_the_game_works_out_is_still_left_out_rather_than_guessed
    assert_in_delta steady(rects(1, wide: true)), steady(rects(999, wide: true)), 0.01,
                    "with no provable width the rectangle is charged nothing, so its height cannot matter"
    assert_operator steady(rects(999)), :>, steady(rects(999, wide: true)),
                    "...where the same rectangle at a width the build can prove is charged"
    report = report_of(rects(999, wide: true))

    assert_includes report, "whose size the game works out here isn't counted"
    refute_includes report, "counts the rows it usually draws",
                    "it counted no rows for this rectangle, so it must not claim a height it guessed"
  end

  # --- and against the console -------------------------------------------------------

  # WHAT IT REALLY COSTS. The whole point of the number is that an author decides by it, so it is
  # held against the emulator rather than against itself.
  #
  # A SEVENTH, and the number that used to be a fifth was not the column weights. It was the one
  # figure the model had for how much faster code runs in the quick memory: this frame really
  # speeds up about three times over, where a frame of arithmetic speeds up 2.30, so a moved
  # column read a sixth dear while the same column left in the cartridge read a fourteenth
  # light. Each weight carries its own gain now (see CostModel::DEFAULT_GAINS), and the two
  # readings agree with each other to within a hundredth — which is the real check here, since
  # where a routine is placed cannot change what its work costs.
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

        assert_in_delta 1.0, steady(rom) / console, 1.0 / 7,
                        "#{tall} rows a column: estimate #{steady(rom)}, console #{console}"
      end
    end
  end
end
