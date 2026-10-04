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
      func(:the_big_one) { 900.times { add! :x, 1 } }
      func(:the_other_big_one) { 900.times { add! :x, 2 } }
      game_loop do
        call :the_big_one
        call :the_other_big_one
      end
    end
  end

  def report_for(rom)
    out = StringIO.new
    RubyGBA::Diagnostics::BuildReport.render(rom, out: out)
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
      game_loop { clear_screen :black; add! :x, 1 }
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

  # --- how fine a fade goes ---

  # A tiled game that fades out over +frames+, placed under a HUD when +under+ says so.
  def fading_game(frames, under: nil)
    tile = SOLID_TILE
    RubyGBA.build("BRFD") do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:badge, "#" => :green) { tile }
      tiles :set, "#" => :red_art
      layers :world, :ui
      layer(:world) { background :field, tiles: :set, map: Array.new(20) { "#" * 30 } }
      layer(:ui) { sprite :badge, at: [200, 8] }
      game_loop do
        pressed(:a).then { fade_out frames: frames, under: under }
        pressed(:b).then { fade_in frames: frames }
      end
    end
  end

  # The one place the author sees the price of a long fade: the colors are walked on each
  # frame it moves, where the display's own fade is free.
  def test_a_long_fade_is_said_to_walk_the_colors_in_33_levels
    text = report_for(fading_game(33))

    assert_match(/33 levels/, text)
    assert_match(/each frame it moves/, text)
  end

  def test_a_short_fade_is_not_mentioned
    refute_match(/33 levels|17 levels/, report_for(fading_game(12)))
  end

  # A placed fade cannot walk the colors, so a long one is told what it gives up.
  def test_a_long_placed_fade_is_said_to_keep_17_levels
    text = report_for(fading_game(33, under: :ui))

    assert_match(/17 levels/, text)
    refute_match(/33 levels/, text)
  end

  # --- save memory, whose size the build picks and nothing else reports ---

  # A game keeping +bytes+ flags in +copies+ copies, with a save_var if +best+.
  private def saving_game(bytes:, copies:, best: false, **options)
    RubyGBA.build("BRPTSAVE", out: nil, err: nil, **options) do
      screen :bitmap
      save_var :best, 0 if best
      flags = list :flags, capacity: bytes, width: :byte, fast: false
      files = save_data(:file, copies: copies) { keep flags }
      game_loop { pressed(:a).then { files[0].save } }
    end
  end

  def test_it_says_which_save_memory_the_build_picked_and_what_takes_it
    text = report_for(saving_game(bytes: 6000, copies: 3))

    assert_match(/save memory: 64K of flash, picked by the build to hold the saves/, text)
    assert_match(/save_data :file, 3 copies: 48\.0K/, text)
    assert_match(/the table of places: 8\.0K/, text)
    assert_match(/free: 8\.0K/, text)
  end

  def test_it_says_when_the_game_asked_for_the_size
    text = report_for(saving_game(bytes: 10, copies: 1, save_memory: 128))

    assert_match(/save memory: 128K of flash, as the game asked/, text)
  end

  # On flash a save goes in slowly, and a fresh cartridge's first power-on writes the table.
  def test_on_flash_it_says_how_many_passes_a_save_takes
    text = report_for(saving_game(bytes: 6000, copies: 3))

    assert_match(/32 bytes a pass/, text)
    assert_match(/save_data :file: about \d+ passes/, text)
    assert_match(/first power-on/, text)
  end

  def test_on_32k_it_names_the_room_kept_for_save_var
    text = report_for(saving_game(bytes: 10, copies: 1, best: true))

    assert_match(/save memory: 32K of battery-backed memory, picked by the build/, text)
    assert_match(/kept for save_var: 4\.0K/, text)
    refute_match(/first power-on/, text)
  end

  # A game with save_vars and no record has the smallest size because nothing needs more, and
  # writes no table of places.
  def test_a_game_with_only_save_vars_is_said_to_have_the_smallest
    rom = RubyGBA.build("BRPTVARS", out: nil, err: nil) do
      screen :bitmap
      save_var :best, 0
      game_loop {}
    end
    text = report_for(rom)

    assert_match(/save memory: 32K of battery-backed memory, the smallest, since nothing asks for more/, text)
    refute_match(/table of places/, text)
    assert_match(/free: 28\.0K/, text)
  end

  # On flash the save_vars are a record of their own, named for what it is.
  def test_on_flash_the_save_var_record_is_named_for_what_it_keeps
    text = report_for(saving_game(bytes: 10, copies: 1, best: true, save_memory: 64))

    section = text.split("save memory:").last
    assert_match(/the save_var numbers: 8\.0K/, section)
    refute_match(/_save_vars/, section)
  end

  def test_a_game_that_saves_nothing_says_nothing_about_save_memory
    refute_match(/save memory/, report_for(crowded_game))
  end

  def test_the_json_says_the_save_memory_and_each_record
    json = RubyGBA::Diagnostics::BuildReport.as_json(saving_game(bytes: 6000, copies: 3))

    assert_equal 64, json[:save_memory][:kilobytes]
    assert_equal false, json[:save_memory][:asked_for]
    assert_equal [{ name: "file", copies: 3, bytes: 48 * 1024 }], json[:save_memory][:records]
  end

  # --- it rides along with the measured half ---

  def test_a_profile_prints_the_build_facts_above_the_measured_ones
    skip "needs the emulator" unless RubyGBA::Diagnostics::Emulator.available?

    out = StringIO.new
    crowded_game.profile(out: out, frames: 5)

    assert_match(/kept in quick memory/, out.string)
    assert_match(/where your frames went/, out.string)
    assert_operator out.string.index("kept in quick memory"), :<,
                    out.string.index("where your frames went"),
                    "the build half comes first — it is what a reader checks before the numbers"
  end
end
