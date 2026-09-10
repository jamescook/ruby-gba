# frozen_string_literal: true

require "test_helper"

# {Flicker} read off a REAL RUN, through `rom.profile`.
#
# The rule itself is tested as a pure comparison in test_flicker.rb. This file is
# about the half that cannot be faked: reading both of a tear-free screen's
# pictures out of the console's video memory, and getting the same answer the
# player would get by looking at the screen.
class TestFlickerMeasured < Minitest::Test
  include GembaSupport

  def setup
    require_gemba_core!
  end

  # How many marks the trail lays down before it stops, and how far apart.
  #
  # IT STOPS ON PURPOSE. A trail that ran on for ever would wrap and lay every mark
  # down again on the other picture, so the two would agree in the end and a broken
  # game would read as a clean one — for a reason that has nothing to do with the
  # rule. Bounded, both programs below are permanently settled well before the
  # reading is taken, and what they read is what they mean.
  MARKS = 24
  STEP = 8

  # A TRAIL, written the way somebody writes one the first time: add a mark a frame
  # and never repaint. Half the marks land in each of the screen's two pictures, and
  # once the trail stops they stay that way.
  def losing_rom
    RubyGBA.build("FLICKLOSE", code: "FLKL", maker: "01", validate: false) do
      screen :bitmap, tear_free: true
      clear_screen :black
      n = var :n, 0
      game_loop do
        n.add 1
        (n <= MARKS).then { draw_rect_at n * STEP, 40, 6, 6, :red }
      end
    end
  end

  # The same trail with every mark drawn on two frames running — one for each of the
  # screen's pictures. This is wolf3d's fizzle in miniature, and it is the case a
  # build-time check cannot tell apart from the one above: same verbs, same shape,
  # and the only difference is how many frames each mark is drawn on.
  def kept_rom
    RubyGBA.build("FLICKKEEP", code: "FLKK", maker: "01", validate: false) do
      screen :bitmap, tear_free: true
      clear_screen :black
      n = var :n, 0
      game_loop do
        n.add 1
        (n <= MARKS).then { draw_rect_at n * STEP, 40, 6, 6, :red }
        # ...and the frame before's mark again, so every one is drawn on two frames
        # running, which is one of each picture. Both ends are guarded: without the
        # lower one the first mark is drawn on its own frame only, and without the
        # upper one the last mark is — and either leaves one mark on one picture.
        ((n >= 2) & (n <= MARKS + 1)).then { draw_rect_at (n - 1) * STEP, 40, 6, 6, :red }
      end
    end
  end

  # A game that repaints the whole screen every frame: nothing is ever left behind.
  #
  # It steps a whole mark's width a frame, ON PURPOSE. A mark that crawled a pixel at a
  # time would overlap itself and leave only a sliver of difference between the two
  # pictures — under the floor, and the reading would come out clean whether or not the
  # rule was right. Stepping clear each time makes a wrong rule show up.
  def repainting_rom
    RubyGBA.build("FLICKFULL", code: "FLKF", maker: "01", validate: false) do
      screen :bitmap, tear_free: true
      n = var :n, 0
      game_loop do
        n.add 1
        clear_screen :black
        draw_rect_at (n * 8) % 200, 40, 6, 6, :red
      end
    end
  end

  def flicker_of(rom) = RubyGBA::Profiler.run(rom, frames: 12).flicker

  # THE ONE THAT MATTERS. The console really is showing two different pictures in
  # turn, and the reading says so and says where.
  def test_a_dissolve_drawn_once_is_caught_on_the_console
    reading = flicker_of(losing_rom)

    assert_predicate reading, :measured?
    assert_predicate reading, :losing?, "half the dots land in each picture"
    assert_operator reading.pixels, :>, RubyGBA::Flicker::FLOOR
    assert_equal 40, reading.first[1], "the stuck pixels are on the row the dots are drawn on"
  end

  # ...and the same drawing put into both pictures is NOT caught. This is the
  # acceptance the bead turned on: a game that adds on purpose and handles it must
  # not be warned about, and no build-time check can tell it from the one above.
  def test_the_same_dissolve_drawn_into_both_pictures_is_not_caught
    reading = flicker_of(kept_rom)

    assert_predicate reading, :measured?
    refute_predicate reading, :losing?,
                     "every dot reached both pictures, so nothing flickers"
  end

  def test_a_repainting_game_is_not_caught
    reading = flicker_of(repainting_rom)

    assert_predicate reading, :measured?
    refute_predicate reading, :losing?
  end

  # WHY THE WINDOW IS TWO FRAMES AND NOT ONE, pinned rather than asserted in a comment.
  #
  # Only one picture is drawn into per frame, so a one-frame window sees one of them
  # take its turn and the other stand still — and which one that is depends on where
  # the window happened to start. Two frames gives each picture exactly one turn, so
  # the answer cannot depend on the parity. A game that repaints everything is the
  # case that shows it up: over one frame the picture that was not drawn into still
  # holds the last frame's marks, which reads as a disagreement nothing is fixing.
  #
  # Measured here at both parities, on the same game, through the same rule.
  def test_the_reading_does_not_depend_on_which_frame_the_window_starts
    rom = repainting_rom
    readings = [0, 1].map do |offset|
      RubyGBA::Profiler.run(rom, frames: 12 + offset).flicker
    end

    assert(readings.all?(&:measured?), "both windows should have been looked at")
    assert_equal readings.first.pixels, readings.last.pixels,
                 "a repainting game reads the same however the window falls"
    assert(readings.none?(&:losing?), "...and reads clean at both, got #{readings.map(&:pixels)}")
  end

  # A screen that keeps one picture cannot lose half a drawing, and says nothing
  # rather than saying "no".
  def test_a_plain_bitmap_game_is_not_asked
    rom = RubyGBA.build("FLICKPLAIN", code: "FLKP", maker: "01", validate: false) do
      screen :bitmap
      n = var :n, 0
      game_loop do
        n.add 1
        draw_rect_at (n * 8) % 200, 40, 6, 6, :red
      end
    end

    assert_nil RubyGBA::Profiler.run(rom, frames: 8).flicker
  end

  # The switch that turns the per-pixel readings off entirely.
  def test_the_picture_readings_can_be_turned_off
    assert_nil RubyGBA::Profiler.run(losing_rom, frames: 8, picture: false).flicker
  end

  # What the author reads. The wording is free to improve; that it names the
  # symptom, where to look, and both fixes is not.
  def test_the_report_says_what_the_player_sees_and_what_to_do
    out = StringIO.new
    RubyGBA::Profiler.render(RubyGBA::Profiler.run(losing_rom, frames: 12), out: out)
    said = out.string

    assert_match(/pixels flicker/, said)
    assert_match(/keeps two pictures/, said)
    assert_match(/keep_showing/, said)
    refute_match(/\bpage\b/i, said, "the author is never made to learn the word")
  end

  def test_the_report_says_so_when_every_drawing_arrives
    out = StringIO.new
    RubyGBA::Profiler.render(RubyGBA::Profiler.run(kept_rom, frames: 12), out: out)

    assert_match(/every drawing reached both/, out.string)
  end
end
