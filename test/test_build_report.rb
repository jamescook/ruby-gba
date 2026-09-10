# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT THE BUILD MADE OF A PROGRAM — the exact half of a profile.
#
# Every fact here is read off the finished build, so these assert the SENTENCES rather than
# the sizes: how big a routine came out moves whenever the lowering does, and none of these
# tests should care. What must not move is which facts get stated at all — each one is
# something a running cartridge cannot tell you afterwards, which is the whole reason this
# report exists beside the measured one.
class TestBuildReport < Minitest::Test
  # Two routines far too big for the 32K, so something must be kept and something passed over.
  def crowded_game
    RubyGBA.build("BRPT", code: "BRPT", maker: "01") do
      screen :bitmap, tear_free: true
      clear_screen :black
      var :x, 0
      func(:the_big_one) { 900.times { add :x, 1 } }
      func(:the_other_big_one) { 900.times { add :x, 2 } }
      game_loop do
        call :the_big_one
        call :the_other_big_one
      end
    end
  end

  def report_for(rom)
    out = StringIO.new
    RubyGBA::BuildReport.render(rom, out: out)
    out.string
  end

  def test_it_says_what_was_kept_in_the_quick_memory_and_how_much_room_is_left
    text = report_for(crowded_game)

    assert_match(/kept in quick memory/, text)
    assert_match(/of 32K used/, text)
    assert_match(/free/, text)
  end

  # THE ACTIONABLE HALF, and the one a finished cartridge cannot answer: a routine that just
  # missed is exactly where a game lost that speed, and by then the evidence is gone.
  def test_it_names_what_did_not_fit_with_what_it_wanted_and_what_was_left
    text = report_for(crowded_game)

    assert_match(/did not fit/, text)
    assert_match(/it needs .*K and .*K was left when its turn came/, text)
  end

  def test_it_says_whether_the_list_was_chosen_by_measuring_or_from_the_shape
    assert_match(/chosen from the shape of the program/, report_for(crowded_game))
  end

  def test_it_says_how_much_of_a_font_the_game_actually_draws
    rom = RubyGBA.build("BRFT", code: "BRFT", maker: "01") do
      screen :bitmap
      clear_screen :black
      draw_text "HI", 10, 10, :white
      halt
    end

    assert_match(/font :default draws \d+ of its \d+ glyphs/, report_for(rom))
  end

  # --- the tear question, at build time ---

  # A game that draws straight into the picture the display is reading CAN tear, and that is
  # a fact about the screen it chose rather than about how long anything takes.
  def test_a_single_buffered_game_is_told_it_can_tear
    rom = RubyGBA.build("BRTR", code: "BRTR", maker: "01") do
      screen :bitmap
      var :x, 0
      game_loop { clear_screen :black; add :x, 1 }
    end

    assert_match(/it can tear/, report_for(rom))
    assert_match(/Run it to see whether it does/, report_for(rom),
                 "...and the answer is measured, not guessed at here")
  end

  # ...and one that cannot tear is told nothing, because "we did not look" must never read
  # as "nothing was wrong". A double-buffered game shows a finished page all at once.
  def test_a_game_that_cannot_tear_is_told_nothing_about_tearing
    refute_match(/tear/, report_for(crowded_game))
  end

  # NO CLAIM ABOUT HOW LONG ANYTHING TAKES survives here. This report used to price a frame
  # in scanlines against a budget and call it fits or tears — a second statement of what the
  # hardware costs, kept in step with the backend by hand. Time is measured now.
  def test_it_makes_no_claim_about_how_long_a_frame_takes
    text = report_for(crowded_game)

    refute_match(/scanline/i, text)
    refute_match(/budget/i, text)
    refute_match(/\bfits\b/, text)
  end

  # --- it rides along with the measured half ---

  def test_a_profile_prints_the_build_facts_above_the_measured_ones
    skip "needs the emulator" unless RubyGBA::Emulator.available?

    out = StringIO.new
    crowded_game.profile(out: out, frames: 5)

    assert_match(/kept in quick memory/, out.string)
    assert_match(/where your frames went/, out.string)
    assert_operator out.string.index("kept in quick memory"), :<,
                    out.string.index("where your frames went"),
                    "the build half comes first — it is what a reader checks before the numbers"
  end
end
