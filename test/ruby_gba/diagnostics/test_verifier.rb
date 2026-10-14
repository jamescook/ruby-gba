# frozen_string_literal: true

require "test_helper"
require "comparison_games"

class TestVerifier < Minitest::Test
  include ComparisonGames

  def setup
    require_emulator!
  end

  def test_red_pixel_readback
    rom = RubyGBA.build("REDPIX", code: "BRDP", maker: "01") do
      screen :bitmap
      pixel 120, 80, :red
      halt
    end
    v = RubyGBA::Diagnostics::Verifier.new(rom)
    assert v.red?(120, 80), "Expected red at (120, 80), got #{v.pixel(120, 80)}"
  end

  def test_black_background
    rom = RubyGBA.build("REDPIX", code: "BRDP", maker: "01") do
      screen :bitmap
      pixel 120, 80, :red
      halt
    end
    v = RubyGBA::Diagnostics::Verifier.new(rom)
    assert v.black?(0, 0), "Expected black at (0, 0), got #{v.pixel(0, 0)}"
  end

  def test_green_pixel_readback
    rom = RubyGBA.build("GRNPIX", code: "BGRP", maker: "01") do
      screen :bitmap
      pixel 50, 50, :green
      halt
    end
    v = RubyGBA::Diagnostics::Verifier.new(rom)
    assert v.green?(50, 50), "Expected green at (50, 50), got #{v.pixel(50, 50)}"
  end

  def test_blue_pixel_readback
    rom = RubyGBA.build("BLUPIX", code: "BBLP", maker: "01") do
      screen :bitmap
      pixel 200, 100, :blue
      halt
    end
    v = RubyGBA::Diagnostics::Verifier.new(rom)
    assert v.blue?(200, 100), "Expected blue at (200, 100), got #{v.pixel(200, 100)}"
  end

  def test_fill_rect_region
    rom = RubyGBA.build("FILL", code: "BFIL", maker: "01") do
      screen :bitmap
      fill_rect 10, 10, 20, 20, :red
      halt
    end
    v = RubyGBA::Diagnostics::Verifier.new(rom)
    assert v.region_color?(10, 10, 20, 20, :red),
           "Expected all red in rect. Mismatch: #{v.region_mismatch(10, 10, 20, 20, :red)}"
  end

  def test_fill_rect_outside_is_black
    rom = RubyGBA.build("FILL", code: "BFIL", maker: "01") do
      screen :bitmap
      fill_rect 100, 70, 40, 20, :blue
      halt
    end
    v = RubyGBA::Diagnostics::Verifier.new(rom)
    assert v.black?(0, 0), "Expected black outside rect"
    assert v.black?(99, 70), "Expected black just outside rect"
    assert v.blue?(100, 70), "Expected blue inside rect"
  end

  def test_pixel_gba_returns_15bit
    rom = RubyGBA.build("WHITE", code: "BWHT", maker: "01") do
      screen :bitmap
      pixel 0, 0, :white
      halt
    end
    v = RubyGBA::Diagnostics::Verifier.new(rom)
    assert_equal 0x7FFF, v.pixel_gba(0, 0)
  end

  def test_all_black_empty_screen
    rom = RubyGBA.build("EMPTY", code: "BEMP", maker: "01") do
      screen :bitmap
      halt
    end
    v = RubyGBA::Diagnostics::Verifier.new(rom)
    assert v.all_black?, "Expected all black for empty screen"
  end

  def test_all_black_false_when_pixel_drawn
    rom = RubyGBA.build("DOT", code: "BDOT", maker: "01") do
      screen :bitmap
      pixel 0, 0, :white
      halt
    end
    v = RubyGBA::Diagnostics::Verifier.new(rom)
    refute v.all_black?, "Screen should not be all black"
  end

  def test_screen_map
    rom = RubyGBA.build("RECT", code: "BRCT", maker: "01") do
      screen :bitmap
      fill_rect 0, 0, 16, 16, :red
      halt
    end
    v = RubyGBA::Diagnostics::Verifier.new(rom)
    map = v.screen_map
    # Top-left 2x2 tiles should be R, rest should be .
    lines = map.split("\n")
    assert_equal "R", lines[0][0], "Expected R in top-left tile"
    assert_equal "R", lines[1][1], "Expected R in second tile row"
    assert_equal ".", lines[0][2], "Expected . outside rect"
  end

  def test_report
    rom = RubyGBA.build("REPORT", code: "BRPT", maker: "01") do
      screen :bitmap
      fill_rect 10, 10, 20, 20, :green
      halt
    end
    v = RubyGBA::Diagnostics::Verifier.new(rom)
    report = v.report
    assert_includes report, "Frame Verifier Report"
    assert_includes report, "Unique colors"
    assert_includes report, "(black)"
    assert_includes report, "(green)"
  end

  def test_region_mismatch_returns_nil_on_match
    rom = RubyGBA.build("MATCH", code: "BMCH", maker: "01") do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red
      halt
    end
    v = RubyGBA::Diagnostics::Verifier.new(rom)
    assert_nil v.region_mismatch(0, 0, 10, 10, :red)
  end

  def test_region_mismatch_returns_details
    rom = RubyGBA.build("MISMATCH", code: "BMIS", maker: "01") do
      screen :bitmap
      pixel 5, 5, :red
      halt
    end
    v = RubyGBA::Diagnostics::Verifier.new(rom)
    info = v.region_mismatch(0, 0, 10, 10, :red)
    refute_nil info, "Expected mismatch info for non-uniform region"
    assert_equal 0, info[:x]
    assert_equal 0, info[:y]
  end

  def test_coords_validation
    rom = RubyGBA.build("BOUNDS", code: "BBND", maker: "01") do
      screen :bitmap
      halt
    end
    v = RubyGBA::Diagnostics::Verifier.new(rom)
    assert_raises(ArgumentError) { v.pixel(240, 0) }
    assert_raises(ArgumentError) { v.pixel(0, 160) }
    assert_raises(ArgumentError) { v.pixel(-1, 0) }
  end

  # A verified ROM goes to a temporary file, and the emulator keeps a cartridge's save
  # memory in a .sav beside whatever ROM it opened — creating it whether the game saves
  # anything or not. That is one abandoned file per verification, and this suite verifies
  # thousands. So the save goes in a directory of the Verifier's own instead.
  def test_verifying_a_rom_leaves_no_save_file_loose_in_the_temp_directory
    rom = RubyGBA.build("SAVER", code: "BSVR", maker: "01") do
      screen :bitmap
      high = save_var :high_score, 0
      s = var :s, 0
      game_loop do
        s.set! 7
        (s > high).then { high.set! s }
      end
    end

    # The temp directory is shared with every other test running at the same moment, so this
    # reads it rather than pointing it somewhere of its own: the temp directory is the whole
    # process's, and moving it moved every other core's temp files into a directory this test
    # was about to remove. A save a Verifier dropped there would be named after its ROM.
    loose = -> { Dir.glob(File.join(Dir.tmpdir, "verify*.sav")) }
    before = loose.call
    v = RubyGBA::Diagnostics::Verifier.new(rom, frames: 6)
    v.pixel(0, 0) # force the render, which is what opens the emulator

    assert_empty loose.call - before, "verifying a ROM dropped a save file next to it in the temp directory"
  end

  # --- questions about the whole screen ---
  #
  # Each is answered by the emulator in one pass over the picture. What each is held to
  # here is the long way round: every pixel's colour as a number, gone through in Ruby.

  PIXELS = 240 * 160
  BLUE, GREEN, RED, WHITE = %i[blue green red white].map { |name| RubyGBA::Graphics::Color.resolve(name) }

  # Blue with a green block and a red strip on it.
  private def a_picture
    reader_of(RubyGBA.build("PICTURE") do
      screen :bitmap
      clear_screen :blue
      fill_rect 100, 60, 40, 40, :green
      fill_rect 10, 10, 20, 6, :red
      game_loop {}
    end)
  end

  private def all_red
    reader_of(RubyGBA.build("ALLRED") do
      screen :bitmap
      clear_screen :red
      game_loop {}
    end)
  end

  # A grey screen the emulator holds as one of two numbers for the same five-bit colour: see
  # ComparisonGames#grey_screen.
  private def grey(brightened:) = reader_of(grey_screen(brightened: brightened))

  # A white box on blue that walks two pixels to the right on every frame.
  private def a_walking_box
    reader_of(RubyGBA.build("WALKBOX") do
      screen :bitmap
      x = var :x, 20
      game_loop do
        clear_screen :blue
        draw_rect_at x, 60, 8, 8, :white
        x.add! 2
      end
    end)
  end

  private def reader_of(rom) = RubyGBA::Diagnostics::Verifier.new(rom, frames: 6, vars: rom.var_addresses)

  private def levels_of(colour) = (colour & 0x1F) + ((colour >> 5) & 0x1F) + ((colour >> 10) & 0x1F)

  def test_the_whole_screen_as_colours_is_every_pixel_a_row_at_a_time
    shown = a_picture.frame_gba

    assert_equal PIXELS, shown.size
    assert_equal({ BLUE => PIXELS - 1600 - 120, GREEN => 1600, RED => 120 }, shown.tally)
    assert_equal [RED, BLUE], [shown[(10 * 240) + 29], shown[(10 * 240) + 30]], "the strip ends at its edge"
    assert_equal [BLUE, GREEN], [shown[(60 * 240) + 99], shown[(60 * 240) + 100]], "and the block begins at its own"
  end

  def test_the_whole_screen_as_one_string_is_the_same_colours_two_bytes_each
    reader = a_picture

    assert_equal PIXELS * 2, reader.frame_colors.bytesize
    assert_equal reader.frame_gba, reader.frame_colors.unpack("v*")
  end

  def test_a_screen_of_one_colour_says_which_and_a_picture_says_none
    assert_equal RED, all_red.only_color
    assert_nil a_picture.only_color
  end

  def test_how_bright_a_screen_is_is_the_levels_of_every_pixel_added_up
    reader = a_picture

    assert_equal PIXELS * 31, reader.brightness, "three plain colours, one full channel each"
    assert_equal reader.frame_gba.sum { |colour| levels_of(colour) }, reader.brightness
    assert_equal PIXELS * 17 * 3, grey(brightened: true).brightness, "the levels a console shows"
  end

  # THE SAME COLOURS ARE THE SAME PICTURE, whatever the emulator holds below the five bits of
  # each channel a console shows: it keeps eight, and works a colour the display brightened
  # out at all eight of them.
  def test_two_readers_showing_the_same_colours_show_the_same_picture
    plain = grey(brightened: false)
    brightened = grey(brightened: true)

    refute_equal plain.pixel(0, 0), brightened.pixel(0, 0), "the emulator holds the two greys as different numbers"
    refute_equal plain.picture, brightened.picture
    assert_equal plain.frame_gba, brightened.frame_gba, "and they are one colour at five bits a channel"
    assert plain.same_picture_as?(brightened)
    assert_nil plain.difference_from(brightened)
  end

  def test_two_readers_showing_different_pictures_say_how_they_differ
    picture = a_picture
    red = all_red
    differing = picture.frame_gba.zip(red.frame_gba).count { |ours, theirs| ours != theirs }

    refute picture.same_picture_as?(red)
    assert_equal PIXELS - 120, differing, "all but the red strip, counted the long way"
    assert_equal({ count: PIXELS - 120, box: [0, 0, 240, 160], at: [0, 0], colors: [BLUE, RED] }, picture.difference_from(red))
  end

  def test_a_difference_leaves_out_what_is_not_looked_at
    picture = a_picture
    block_only = "\x00".b * PIXELS
    (60...100).each { |row| block_only[(row * 240) + 100, 40] = "\x01".b * 40 }

    assert_equal({ count: 1600, box: [100, 60, 40, 40], at: [100, 60], colors: [GREEN, RED] },
                 picture.difference_from(all_red, looked_at: block_only))
    assert_nil picture.difference_from(all_red, looked_at: "\x00".b * PIXELS)
  end

  # A PICTURE KEPT FROM EARLIER answers the same two questions a second reader does: has the
  # screen changed since, and where.
  def test_a_reader_is_compared_with_a_picture_it_kept_earlier
    reader = a_walking_box
    kept = reader.picture
    was_at = reader.var(:x) - 2

    assert reader.same_picture_as?(kept), "nothing has been played since"
    reader.step

    refute reader.same_picture_as?(kept)
    assert_equal({ count: 32, box: [was_at, 60, 10, 8], at: [was_at, 60], colors: [BLUE, WHITE] },
                 reader.difference_from(kept), "two columns left behind and two new ones, eight rows of each")
  end

  def test_the_colours_of_a_picture_are_not_a_picture_to_compare_with
    reader = a_picture

    [-> { reader.same_picture_as?(reader.frame_colors) }, -> { reader.difference_from(reader.frame_colors) },
     -> { reader.same_picture_as?(reader.frame_gba) }].each do |ask|
      message = assert_raises(ArgumentError, &ask).message

      assert_match(/`picture`/, message, "it says what to give")
      assert_operator message.length, :<, 600, "and does not print the screen it was given"
    end
  end

  def test_a_picture_that_was_kept_cannot_be_changed
    kept = a_picture.picture

    assert_raises(FrozenError) { kept.setbyte(0, 9) }
  end

  # ALL BLACK IS ASKED OF WHAT THE EMULATOR HOLDS, eight bits a channel, as it always was.
  # The darkest grey there is, darkened half way by the display, comes to a number below
  # the lowest of the five bits: black to every reader of colours, and not to this one.
  def test_a_screen_lit_only_below_five_bits_is_not_all_black
    rom = RubyGBA.build("DIMMED") do
      screen :bitmap
      clear_screen rgb(1, 1, 1)
      fade :black, 50
      game_loop {}
    end
    reader = reader_of(rom)

    assert_equal 0, reader.only_color, "black, by the colours"
    assert reader.black?(120, 80)
    assert_equal 0, reader.brightness
    assert_operator reader.pixel(120, 80)[:r], :>, 0, "and the emulator holds a number above nought"
    refute reader.all_black?
  end
end
