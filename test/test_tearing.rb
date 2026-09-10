# frozen_string_literal: true

require "test_helper"
require "stringio"

# THE ONE VERDICT THAT COULD ONLY EVER BE ESTIMATED, now measured (lib/ruby_gba/tearing.rb).
#
# The display draws each row as it reaches it, out of video memory as it stands at that
# moment — so the picture the emulator hands back is what the screen really showed, seam and
# all. Video memory read at the frame boundary, where the game has finished, is the picture
# it meant to show. A row where the two differ went up before the game was done with it.
#
# These are behaviour tests on real cartridges: a program that draws far too much tears, one
# that draws little does not, and a screen with no framebuffer says so rather than answering.
class TestTearing < Minitest::Test
  include GembaSupport

  # A program that repaints a band the full width of the screen in a different colour every
  # frame. The band's HEIGHT is how much drawing there is to do, which is what decides
  # whether it can finish before the display arrives. Two draws under opposite tests, so the
  # colour really changes each frame — a repaint in the same colour tears invisibly.
  def alternating_band(height)
    RubyGBA.build("TEAR", code: "BTER", maker: "01", err: StringIO.new) do
      screen :bitmap
      c = var :c, 0
      game_loop do
        c.set(1 - c)
        (c == 0).then { fill_rect 0, 0, 240, height, :red }
        (c == 1).then { fill_rect 0, 0, 240, height, :blue }
      end
    end
  end

  def tearing_of(rom)
    require_gemba_core!
    readings = RubyGBA::Analyzer.profile(rom.source_program, options: rom.build_options)
    readings.values.first.tearing
  end

  def test_a_program_that_draws_far_too_much_is_measured_tearing
    reading = tearing_of(alternating_band(90))

    assert_predicate reading, :measured?
    assert_predicate reading, :torn?
    assert_operator reading.rows, :>, 0, "some rows went up before the game had finished them"
    assert_operator reading.first, :<=, reading.last, "the seam runs from somewhere to somewhere"
  end

  def test_a_program_with_little_to_draw_is_measured_whole
    reading = tearing_of(alternating_band(4))

    assert_predicate reading, :measured?
    refute_predicate reading, :torn?
    assert_equal 0, reading.rows
  end

  # A tear-free screen keeps two pages and shows the finished one, so it cannot tear — and
  # there is no single picture to read a tear off. It answers "not measured here", which is
  # a different thing from "no tear" and must not be mistaken for it.
  def test_a_tear_free_screen_is_not_measured_rather_than_reported_clean
    rom = RubyGBA.build("TEARF", code: "BTRF", maker: "01", err: StringIO.new) do
      screen :bitmap, tear_free: true
      c = var :c, 0
      game_loop do
        c.set(1 - c)
        (c == 0).then { fill_rect 0, 0, 240, 90, :red }
        (c == 1).then { fill_rect 0, 0, 240, 90, :blue }
      end
    end

    refute_predicate tearing_of(rom), :measured?
  end

  # A tiled screen has no framebuffer at all — the console builds the picture from tiles as
  # it draws — so there is nothing to hold a shown row against.
  def test_a_tiled_screen_has_no_picture_to_read_a_tear_off
    rom = RubyGBA.build("TILED", code: "BTLD", maker: "01", err: StringIO.new) do
      screen :tiled
      image(:blk, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :blk
      background :bg, tiles: :set, map: Array.new(20) { "#" * 30 }
      game_loop { }
    end

    refute_predicate tearing_of(rom), :measured?
  end

  # MORE DRAWING TEARS MORE OF THE PICTURE, which is what says the reading tracks the thing
  # it claims to measure rather than answering the same way whatever it is shown.
  def test_more_drawing_shows_more_of_the_picture_stale
    assert_operator tearing_of(alternating_band(120)).rows, :>,
                    tearing_of(alternating_band(40)).rows,
                    "a bigger overrun has to put more of the screen up stale"
  end

  # THE TWO HALVES OF THE TEAR QUESTION, in the one report that carries both. The build says
  # a game CAN tear — a fact about the screen it chose — and the run says whether it did.
  # Neither is an estimate, which is the whole change: this used to be a frame priced in
  # scanlines against the gap between frames, and it was invented arithmetic for a question a
  # run settles outright.
  def test_the_report_says_the_game_can_tear_and_then_whether_it_did
    io = StringIO.new
    alternating_band(90).profile(out: io, frames: 10)

    assert_match(/it can tear/, io.string, "the build says it is possible")
    assert_match(/the picture tore on \d+ of the \d+ frames looked at/, io.string,
                 "...and the run says it happened")
    refute_match(/scanline/i, io.string)
  end
end
