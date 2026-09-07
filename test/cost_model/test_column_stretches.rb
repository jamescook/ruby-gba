# frozen_string_literal: true

require_relative "helper"

# WHICH SEE-THROUGH PICTURES SKIP THE ROWS THEY HAVE NOTHING IN, and what a reader is told
# when one cannot.
#
# A picture drawn as a stretched column ships a list, per column, of where that column holds
# pixels — so a lamp in a square of ceiling costs its lit rows and not its square. A picture
# past one of the build's ceilings ships none and walks EVERY row of every column instead.
#
# That has been silent, and worse than silent: the estimate charged the lit share whether the
# build had shipped the lists or not, so a picture that walked its whole height read as a
# fraction of what it cost. Both halves are pinned here — what the build could do, and what
# the report and the estimate then say about it.
class TestColumnStretches < Minitest::Test
  include CostArith

  CEILING = RubyGBA::IR::Backends::GBA::RUNS_MAX_ROWS

  # A lamp: two rows of pixels at the top of the picture, two at the bottom, nothing in the
  # long middle — the shape a scaled sprite really has.
  def lamp(width, height)
    (0...height).flat_map do |y|
      lit = y < 2 || y >= height - 2
      (0...width).map { |x| lit && x.even? ? :white : :transparent }
    end
  end

  def drawing(height, width: 8, pixels: nil)
    art = pixels || lamp(width, height)
    RubyGBA.build("STRETCH", code: "ZSTR", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      image :art, width: width, height: height, data: art, transparent: true
      tall = var :tall, 0
      game_loop do
        tall.set 90
        draw_column_at :art, slice: 0, x: 10, top: 0, height: tall
      end
    end
  end

  def report_of(rom)
    io = StringIO.new
    rom.cost_model.render(rom.source_program, out: io)
    io.string
  end

  def frame_cost(rom) = rom.cost_model.frame_cost(rom.source_program)

  # ANY HEIGHT UP TO THE CEILING, which is the whole of the point. A picture used to have to be
  # 32, 64, 128 or 256 rows tall, because turning a picture row into a screen row divides by the
  # height and only those divide by shifting. Every other height quietly walked its square —
  # and 40 rows is exactly the shape an author reaches for after cropping the empty sky off a
  # sprite sheet, which made cropping a pessimisation nothing could see.
  def test_a_picture_of_any_height_up_to_the_ceiling_skips_the_rows_it_has_nothing_in
    [3, 13, 38, 40, 100, 255, CEILING].each do |height|
      assert drawing(height).column_stretches[:art].skips_empty_rows?,
             "a picture #{height} rows tall must skip the rows it has nothing in"
    end
  end

  # ...and past it, it cannot: a row number is one byte, so a taller picture has rows that
  # cannot be written down.
  def test_a_picture_past_the_ceiling_walks_every_row
    picture = drawing(CEILING + 1).column_stretches[:art]

    refute picture.skips_empty_rows?
    assert_equal :too_tall, picture.held_back_by
  end

  # A picture whose lists together run past what a halfword can point at ships none either.
  # Wide and busy rather than tall: every column here holds many separate stretches.
  def test_a_picture_with_too_many_stretches_to_point_at_walks_every_row
    width = 1024
    height = 64
    combed = (0...height).flat_map { |y| (0...width).map { y.even? ? :white : :transparent } }
    picture = drawing(height, width: width, pixels: combed).column_stretches[:art]

    refute picture.skips_empty_rows?
    assert_equal :too_many, picture.held_back_by
  end

  # THE ESTIMATE HAS TO KNOW, which is the half that hides. A picture that walks every row is
  # charged for every row; charging it the share its pixels take reads as a fraction of what
  # the console really spends, and nothing on the page says which reading you got.
  def test_a_picture_that_walks_every_row_is_charged_for_every_row
    assert_operator frame_cost(drawing(CEILING + 1)), :>, frame_cost(drawing(CEILING)) * 10,
                    "a picture that walks its whole height must cost far more than one that skips"
  end

  # ...and the report names it, says which ceiling it ran into, and says what to change. This
  # is not a guardrail: nothing is WRONG with the picture. It is a speed the game did not get.
  def test_the_report_names_the_picture_that_walks_every_row_and_what_to_change
    report = report_of(drawing(CEILING + 1))

    assert_includes report, "see-through pictures a stretched column draws"
    assert_includes report, ":art — walks every row"
    assert_includes report, "more than #{CEILING} rows tall"
    assert_includes report, "Make it #{CEILING} rows or fewer"
  end

  # A picture that DID ship its lists is named beside it, so a reader can see which is which.
  def test_the_report_shows_the_pictures_that_do_skip_beside_the_one_that_does_not
    fits = lamp(8, 40)
    too_tall = lamp(8, 300)
    rom = RubyGBA.build("BOTH", code: "ZBTH", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      image :lamp, width: 8, height: 40, data: fits, transparent: true
      image :sky, width: 8, height: 300, data: too_tall, transparent: true
      tall = var :tall, 0
      game_loop do
        tall.set 90
        draw_column_at :lamp, slice: 0, x: 10, top: 0, height: tall
        draw_column_at :sky, slice: 0, x: 40, top: 0, height: tall
      end
    end

    report = report_of(rom)

    assert_includes report, "40 rows  :lamp — walks only the rows that hold pixels"
    assert_includes report, "300 rows  :sky — walks every row"
  end

  # ...and a game whose pictures all skip is told nothing. There is nothing to act on, and the
  # report is long enough already.
  def test_a_game_whose_pictures_all_skip_is_not_told_about_them
    refute_includes report_of(drawing(64)), "see-through pictures a stretched column draws"
  end
end
