# frozen_string_literal: true

require_relative "test_helper"

# Tests for RubyGBAEmulator::Screen — the questions a test asks of a whole screen, answered
# in the extension. Each answer is held to what going through the pixels in Ruby gives,
# since that is what the callers did before and what they have to keep getting.
class TestRubyGBAEmulatorScreen < Minitest::Test
  include RubyGBAEmulatorTestSupport

  Screen = RubyGBAEmulator::Screen

  WIDTH = 240
  HEIGHT = 160

  # A screen as the emulator hands one over, made by hand: four bytes a pixel, red first.
  def screen_of(*pixels) = pixels.flatten.pack("C*")

  # A whole screen of one [red, green, blue], with the pixels in +changed+ (a Hash of
  # [x, y] to [red, green, blue]) set apart.
  def whole_screen(colour, changed = {})
    pixels = Array.new(WIDTH * HEIGHT) { colour + [0] }
    changed.each { |(x, y), other| pixels[(y * WIDTH) + x] = other + [0] }
    screen_of(pixels)
  end

  # The console's own colour for one pixel of the emulator's, worked out the long way.
  def console_colour(word)
    ((word & 0xFF) >> 3) | ((((word >> 8) & 0xFF) >> 3) << 5) | ((((word >> 16) & 0xFF) >> 3) << 10)
  end

  def colours_in_ruby(screen) = screen.unpack("V*").map { |word| console_colour(word) }

  # Blue with a green block and a red block on it, off a real cartridge.
  def a_picture
    path = build_rom("SCREEN", code: "TSCR") do
      screen :bitmap
      clear_screen :blue
      fill_rect 100, 60, 40, 40, :green
      fill_rect 10, 10, 20, 6, :red
      game_loop {}
    end
    with_probe(path) { |probe| probe.step(4).frame_buffer }
  end

  def one_colour_in_ruby(screen)
    colours = colours_in_ruby(screen).uniq
    colours.first if colours.length == 1
  end

  def test_the_colours_are_the_consoles_own_two_bytes_a_pixel
    assert_equal [0x001F, 0x03E0, 0x7C00, 0x7FFF].pack("v*"),
                 Screen.colors(screen_of([255, 0, 0, 0], [0, 255, 0, 0], [0, 0, 255, 0], [255, 255, 255, 0]))
  end

  def test_the_colours_drop_what_the_emulator_holds_below_five_bits
    seventeen = 17 | (17 << 5) | (17 << 10)

    assert_equal [seventeen, seventeen].pack("v*"), Screen.colors(screen_of([140, 140, 140, 0], [139, 136, 143, 0]))
  end

  def test_the_colours_of_a_real_screen_are_what_going_through_it_in_ruby_gives
    frame = a_picture

    assert_equal colours_in_ruby(frame).pack("v*"), Screen.colors(frame)
    assert_equal 3, Screen.colors(frame).unpack("v*").uniq.length, "the picture has its three colours"
  end

  def test_the_colours_as_a_list_are_the_same_colours_as_numbers
    frame = a_picture

    assert_equal [0x001F, 0x7FFF], Screen.color_list(screen_of([255, 0, 0, 0], [255, 255, 255, 9]))
    assert_equal colours_in_ruby(frame), Screen.color_list(frame)
    assert_equal WIDTH * HEIGHT, Screen.color_list(frame).length
    assert_empty Screen.color_list("")
  end

  # --- is every pixel one colour ---------------------------------------------------------

  def test_a_screen_of_one_colour_says_which
    assert_equal 0, Screen.only_color(whole_screen([0, 0, 0])), "black"
    assert_equal 0x7FFF, Screen.only_color(whole_screen([255, 255, 255])), "white"
    assert_equal 0x001F, Screen.only_color(whole_screen([255, 0, 0])), "red"
  end

  def test_one_pixel_of_another_colour_is_not_one_colour
    assert_nil Screen.only_color(whole_screen([0, 0, 0], [0, 0] => [8, 0, 0])), "the first pixel"
    assert_nil Screen.only_color(whole_screen([0, 0, 0], [239, 159] => [0, 0, 8])), "the last pixel"
    assert_nil Screen.only_color(whole_screen([0, 0, 0], [117, 80] => [0, 8, 0])), "one in the middle"
  end

  def test_one_colour_is_one_the_console_shows_whatever_is_below_five_bits
    seventeen = 17 | (17 << 5) | (17 << 10)

    assert_equal seventeen, Screen.only_color(whole_screen([140, 140, 140], [3, 3] => [139, 136, 143]))
    assert_equal 0, Screen.only_color(whole_screen([0, 0, 0], [3, 3] => [7, 7, 7])), "black at five bits"
  end

  def test_one_colour_of_real_screens_is_what_going_through_them_in_ruby_gives
    red = with_probe(red_rom) { |probe| probe.step(6).frame_buffer }

    assert_equal 0x001F, one_colour_in_ruby(red), "the Ruby says a red screen is red"
    assert_equal one_colour_in_ruby(red), Screen.only_color(red)
    assert_nil one_colour_in_ruby(a_picture)
    assert_nil Screen.only_color(a_picture)
  end

  def test_a_screen_of_no_pixels_has_no_colour
    assert_nil Screen.only_color("")
  end

  # --- are two screens the same picture --------------------------------------------------

  def same_in_ruby?(one, other) = colours_in_ruby(one) == colours_in_ruby(other)

  def test_two_screens_of_the_same_bytes_are_the_same_picture
    assert Screen.same?(a_picture, a_picture)
  end

  def test_two_screens_are_the_same_picture_whatever_is_below_five_bits
    palette_grey = whole_screen([140, 140, 140])
    brightened_grey = whole_screen([139, 139, 139])

    refute_equal palette_grey, brightened_grey, "the two are different bytes"
    assert same_in_ruby?(palette_grey, brightened_grey), "the Ruby says they are one picture"
    assert Screen.same?(palette_grey, brightened_grey)
  end

  def test_one_pixel_a_console_shows_differently_is_another_picture
    blue = [0, 0, 255]
    one_level_out = [[8, 0, 255], [0, 8, 255], [0, 0, 247]]

    [[0, 0], [239, 159], [101, 77]].each do |place|
      one_level_out.each do |other|
        changed = whole_screen(blue, place => other)

        refute same_in_ruby?(whole_screen(blue), changed), "the Ruby says #{other} at #{place} is another picture"
        refute Screen.same?(whole_screen(blue), changed), "#{other} at #{place}"
      end
    end
  end

  def test_the_fourth_byte_of_a_pixel_is_not_colour
    assert Screen.same?(screen_of([1, 2, 3, 0]), screen_of([1, 2, 3, 255]))
  end

  def test_two_screens_of_different_sizes_cannot_be_compared
    error = assert_raises(ArgumentError) { Screen.same?(whole_screen([0, 0, 0]), screen_of([0, 0, 0, 0])) }

    assert_match(/38400 and 1\b/, error.message)
  end

  def test_the_colours_of_a_screen_are_not_a_screen
    frame = a_picture
    error = assert_raises(ArgumentError) { Screen.same?(frame, Screen.colors(frame)[0, 6]) }

    assert_match(/whole number of pixels/, error.message)
  end

  # --- how two screens differ ------------------------------------------------------------

  # The same answer worked out the long way: every pixel's colour as a number, then the
  # places they differ. +looked_at+ is a byte a pixel, nought for one that is left out.
  def difference_in_ruby(one, other, looked_at = nil)
    ours = colours_in_ruby(one)
    theirs = colours_in_ruby(other)
    places = (0...ours.size).select { |at| ours[at] != theirs[at] && (looked_at.nil? || looked_at.getbyte(at) != 0) }
    return nil if places.empty?

    columns = places.map { |at| at % WIDTH }.minmax
    rows = places.map { |at| at / WIDTH }.minmax
    { count: places.size, box: [columns.first, rows.first, columns.last - columns.first + 1, rows.last - rows.first + 1],
      at: [places.first % WIDTH, places.first / WIDTH], colors: [ours[places.first], theirs[places.first]] }
  end

  # A byte a pixel, set for every pixel but those in +left_out+, each [x, y, width, height].
  def looking_at_all_but(*left_out)
    mask = "\x01".b * (WIDTH * HEIGHT)
    left_out.each do |x, y, width, height|
      (y...(y + height)).each { |row| mask[(row * WIDTH) + x, width] = "\x00".b * width }
    end
    mask
  end

  def test_two_screens_that_are_one_picture_have_no_difference
    assert_nil Screen.difference(a_picture, a_picture, WIDTH)
    assert_nil Screen.difference(whole_screen([140, 140, 140]), whole_screen([139, 139, 139]), WIDTH),
               "different bytes, and one picture at five bits a channel"
  end

  def test_one_differing_pixel_is_counted_boxed_and_named_with_both_colours
    blue = whole_screen([0, 0, 255])
    changed = whole_screen([0, 0, 255], [101, 77] => [255, 255, 255])

    assert_equal({ count: 1, box: [101, 77, 1, 1], at: [101, 77], colors: [0x7C00, 0x7FFF] },
                 Screen.difference(blue, changed, WIDTH))
  end

  def test_the_box_holds_every_differing_pixel_and_the_first_is_the_topmost_then_leftmost
    black = whole_screen([0, 0, 0])
    changed = whole_screen([0, 0, 0], [200, 3] => [255, 0, 0], [5, 9] => [0, 255, 0], [5, 3] => [0, 0, 255],
                                      [120, 150] => [255, 255, 255])

    assert_equal({ count: 4, box: [5, 3, 196, 148], at: [5, 3], colors: [0, 0x7C00] },
                 Screen.difference(black, changed, WIDTH))
  end

  def test_the_corners_of_the_screen_are_in_the_box
    black = whole_screen([0, 0, 0])
    changed = whole_screen([0, 0, 0], [0, 0] => [8, 0, 0], [239, 159] => [8, 0, 0])

    assert_equal({ count: 2, box: [0, 0, 240, 160], at: [0, 0], colors: [0, 1] }, Screen.difference(black, changed, WIDTH))
  end

  def test_the_difference_of_real_screens_is_what_going_through_them_in_ruby_gives
    picture = a_picture
    red = with_probe(red_rom) { |probe| probe.step(6).frame_buffer }
    worked_out = difference_in_ruby(picture, red)

    assert_equal (WIDTH * HEIGHT) - (20 * 6), worked_out[:count], "the Ruby says all but the red block differ"
    assert_equal worked_out, Screen.difference(picture, red, WIDTH)
  end

  def test_pixels_that_are_not_looked_at_are_not_in_the_answer
    black = whole_screen([0, 0, 0])
    changed = whole_screen([0, 0, 0], [2, 2] => [255, 0, 0], [3, 2] => [255, 0, 0], [100, 50] => [0, 255, 0],
                                      [101, 90] => [0, 0, 255])
    looked_at = looking_at_all_but([0, 0, 10, 10])

    assert_equal({ count: 2, box: [100, 50, 2, 41], at: [100, 50], colors: [0, 0x03E0] },
                 Screen.difference(black, changed, WIDTH, looked_at))
    assert_equal difference_in_ruby(black, changed, looked_at), Screen.difference(black, changed, WIDTH, looked_at)
  end

  def test_a_difference_wholly_in_what_is_not_looked_at_is_no_difference
    black = whole_screen([0, 0, 0])
    changed = whole_screen([0, 0, 0], [2, 2] => [255, 0, 0], [9, 9] => [255, 0, 0])

    assert_nil Screen.difference(black, changed, WIDTH, looking_at_all_but([0, 0, 10, 10]))
  end

  def test_a_width_the_screen_is_not_rows_of_is_refused
    error = assert_raises(ArgumentError) { Screen.difference(a_picture, a_picture, 241) }

    assert_match(/241/, error.message)
    assert_match(/38400/, error.message)
    assert_raises(ArgumentError) { Screen.difference(a_picture, a_picture, 0) }
    assert_raises(ArgumentError) { Screen.difference(a_picture, a_picture, -240) }
  end

  def test_a_list_of_what_is_looked_at_must_say_so_for_every_pixel
    error = assert_raises(ArgumentError) { Screen.difference(a_picture, a_picture, WIDTH, "\x01".b * 100) }

    assert_match(/100/, error.message)
    assert_match(/38400/, error.message)
  end

  # --- how bright a screen is ------------------------------------------------------------

  def brightness_in_ruby(screen)
    colours_in_ruby(screen).sum { |colour| (colour & 0x1F) + ((colour >> 5) & 0x1F) + ((colour >> 10) & 0x1F) }
  end

  def test_a_black_screen_has_no_brightness_and_a_white_one_has_the_most
    assert_equal 0, Screen.brightness(whole_screen([0, 0, 0]))
    assert_equal WIDTH * HEIGHT * 31 * 3, Screen.brightness(whole_screen([255, 255, 255]))
  end

  def test_brightness_is_the_sum_of_the_levels_a_console_shows
    assert_equal 31 + 16 + 1, Screen.brightness(screen_of([255, 0, 0, 0], [0, 132, 0, 0], [0, 0, 8, 0]))
    assert_equal 17 * 3, Screen.brightness(screen_of([139, 136, 143, 255])), "nothing below five bits, nor the fourth byte"
  end

  def test_the_brightness_of_a_real_screen_is_what_going_through_it_in_ruby_gives
    frame = a_picture

    assert_equal WIDTH * HEIGHT * 31, brightness_in_ruby(frame), "the Ruby says three plain colours, one full channel each"
    assert_equal brightness_in_ruby(frame), Screen.brightness(frame)
  end

  # --- which bits of a channel are looked at ---------------------------------------------

  # One channel lit at one bit, for each of the five bits a console shows.
  EACH_BIT_SHOWN = [8, 16, 32, 64, 128].flat_map { |bit| [[bit, 0, 0], [0, bit, 0], [0, 0, bit]] }

  # ...and at the bits below them, which a console does not.
  BELOW_THE_BITS_SHOWN = [1, 2, 4, 7].flat_map { |bits| [[bits, 0, 0], [0, bits, 0], [0, 0, bits]] }

  def test_a_pixel_out_by_any_one_of_the_five_bits_is_seen
    black = whole_screen([0, 0, 0])

    EACH_BIT_SHOWN.each do |other|
      changed = whole_screen([0, 0, 0], [7, 5] => other)

      assert_nil Screen.only_color(changed), "#{other} is not black"
      refute Screen.same?(black, changed), "#{other} is another picture"
      assert_equal 1, Screen.difference(black, changed, WIDTH)[:count], "#{other} is one pixel out"
    end
  end

  def test_a_pixel_out_only_below_the_five_bits_is_not
    black = whole_screen([0, 0, 0])

    BELOW_THE_BITS_SHOWN.each do |other|
      changed = whole_screen([0, 0, 0], [7, 5] => other)

      assert_equal 0, Screen.only_color(changed), "#{other} is black at five bits"
      assert Screen.same?(black, changed), "#{other} is the same picture"
      assert_nil Screen.difference(black, changed, WIDTH), "#{other} is no pixel out"
      assert_equal 0, Screen.brightness(changed), "#{other} adds no level"
    end
  end

  def test_one_colour_at_eight_bits_is_the_number_the_emulator_holds
    assert_equal 0, Screen.only_color(whole_screen([0, 0, 0]), 8)
    assert_equal 0xFFFFFF, Screen.only_color(whole_screen([255, 255, 255]), 8)
    assert_equal 0x8B8C8D, Screen.only_color(whole_screen([0x8D, 0x8C, 0x8B]), 8), "red in the low byte, then green, then blue"
    assert_equal 0x030201, Screen.only_color(screen_of([1, 2, 3, 0], [1, 2, 3, 255]), 8), "the fourth byte is not colour"
  end

  def test_one_colour_at_eight_bits_sees_what_five_bits_do_not
    BELOW_THE_BITS_SHOWN.each do |other|
      dim = whole_screen([0, 0, 0], [200, 150] => other)

      assert_nil Screen.only_color(dim, 8), "#{other} is lit, as the emulator holds it"
      assert_equal 0, Screen.only_color(dim, 5)
      assert_equal 0, Screen.only_color(dim), "and five bits is what is asked with nothing said"
    end
  end

  def test_brightness_at_eight_bits_is_every_channel_as_the_emulator_holds_it
    frame = a_picture
    in_ruby = frame.unpack("V*").sum { |word| (word & 0xFF) + ((word >> 8) & 0xFF) + ((word >> 16) & 0xFF) }

    assert_equal 255 + 132 + 8, Screen.brightness(screen_of([255, 0, 0, 0], [0, 132, 0, 0], [0, 0, 8, 0]), 8)
    assert_equal 139 + 136 + 143, Screen.brightness(screen_of([139, 136, 143, 255]), 8), "and not the fourth byte"
    assert_equal WIDTH * HEIGHT * 255, in_ruby, "the Ruby says three plain colours, one full channel each"
    assert_equal in_ruby, Screen.brightness(frame, 8)
    assert_equal Screen.brightness(frame), Screen.brightness(frame, 5)
  end

  def test_the_bits_of_a_channel_are_five_or_eight
    black = whole_screen([0, 0, 0])

    [-> { Screen.only_color(black, 6) }, -> { Screen.brightness(black, 15) }].each do |ask|
      assert_match(/5.*8/, assert_raises(ArgumentError, &ask).message)
    end
  end

  # --- what the answers do not take on trust ---------------------------------------------

  def test_any_byte_but_nought_says_a_pixel_is_looked_at
    black = whole_screen([0, 0, 0])
    changed = whole_screen([0, 0, 0], [1, 1] => [255, 0, 0], [2, 1] => [255, 0, 0], [3, 1] => [255, 0, 0],
                                      [4, 1] => [255, 0, 0])
    looked_at = "\x00".b * (WIDTH * HEIGHT)
    looked_at.setbyte(WIDTH + 1, 255)
    looked_at.setbyte(WIDTH + 2, 2)
    looked_at.setbyte(WIDTH + 3, 128)

    assert_equal({ count: 3, box: [1, 1, 3, 1], at: [1, 1], colors: [0, 0x001F] },
                 Screen.difference(black, changed, WIDTH, looked_at))
  end

  def test_the_width_says_where_a_row_ends
    black = screen_of(*([[0, 0, 0, 0]] * 12))
    changed = screen_of(*Array.new(12) { |at| [7, 11].include?(at) ? [255, 255, 255, 0] : [0, 0, 0, 0] })

    assert_equal [1, 2, 2, 2], Screen.difference(black, changed, 3)[:box], "four rows of three"
    assert_equal [1, 2], Screen.difference(black, changed, 3)[:at]
    assert_equal [3, 1, 1, 2], Screen.difference(black, changed, 4)[:box], "three rows of four"
    assert_equal [3, 1], Screen.difference(black, changed, 4)[:at]
    assert_equal [7, 0, 5, 1], Screen.difference(black, changed, 12)[:box], "one row of twelve"
  end

  def test_every_question_refuses_bytes_that_are_not_whole_pixels_and_says_what_to_give
    odd = "\x00".b * 6

    [-> { Screen.colors(odd) }, -> { Screen.color_list(odd) }, -> { Screen.only_color(odd) },
     -> { Screen.brightness(odd) }, -> { Screen.same?(odd, odd) }, -> { Screen.difference(odd, odd, 1) }].each do |ask|
      message = assert_raises(ArgumentError, &ask).message

      assert_match(/whole number of pixels/, message)
      assert_match(/frame_buffer/, message, "it says what to give")
    end
  end

  def test_each_refusal_of_two_screens_says_what_to_give
    frame = a_picture
    sizes = assert_raises(ArgumentError) { Screen.difference(frame, screen_of([0, 0, 0, 0]), 1) }.message
    width = assert_raises(ArgumentError) { Screen.difference(frame, frame, 241) }.message
    mask = assert_raises(ArgumentError) { Screen.difference(frame, frame, WIDTH, "\x01".b * 100) }.message

    assert_match(/frame_buffer/, sizes)
    assert_match(/Give the width of the screen/, width)
    assert_match(/Give a string of 38400 bytes/, mask)
  end

  # A width or a mask that changes a screen while it is being turned into what the
  # extension reads must not leave it reading where the screen used to be.
  def test_a_width_that_empties_a_screen_as_it_is_read_is_refused_and_not_read_past
    one = whole_screen([0, 0, 0])
    other = whole_screen([9, 9, 9])
    width = Object.new
    width.define_singleton_method(:to_int) do
      one.replace("")
      WIDTH
    end

    assert_raises(ArgumentError) { Screen.difference(one, other, width) }
  end

  # --- the screen a probe is showing now -------------------------------------------------

  def test_a_probe_answers_each_question_of_the_screen_it_is_showing
    kept = a_picture

    with_probe(red_rom) do |probe|
      now = probe.step(6).frame_buffer

      assert_equal Screen.colors(now), probe.screen_colors
      assert_equal [0x001F] * (WIDTH * HEIGHT), probe.screen_color_list
      assert_equal 0x001F, probe.only_color
      assert_equal 0x0000FF, probe.only_color(8), "red as the emulator holds it"
      assert_equal WIDTH * HEIGHT * 31, probe.brightness
      assert_equal WIDTH * HEIGHT * 255, probe.brightness(8)
      assert probe.same_screen?(now.dup)
      refute probe.same_screen?(kept)
      assert_nil probe.screen_difference(now.dup)
      assert_equal Screen.difference(now, kept, WIDTH), probe.screen_difference(kept)
      assert_equal (20 * 6), (WIDTH * HEIGHT) - probe.screen_difference(kept)[:count], "all but the red block differ"
    end
  end

  def test_a_probe_leaves_out_what_is_not_looked_at
    kept = a_picture

    with_probe(red_rom) do |probe|
      probe.step(6)
      green_block_only = "\x00".b * (WIDTH * HEIGHT)
      (60...100).each { |row| green_block_only[(row * WIDTH) + 100, 40] = "\x01".b * 40 }

      assert_equal({ count: 40 * 40, box: [100, 60, 40, 40], at: [100, 60], colors: [0x001F, 0x03E0] },
                   probe.screen_difference(kept, looked_at: green_block_only))
    end
  end

  def test_a_probe_that_has_run_no_frame_has_no_screen_to_ask_about
    with_probe(red_rom) do |probe|
      [-> { probe.screen_colors }, -> { probe.screen_color_list }, -> { probe.only_color }, -> { probe.brightness },
       -> { probe.same_screen?(whole_screen([0, 0, 0])) }, -> { probe.screen_difference(whole_screen([0, 0, 0])) }].each do |ask|
        assert_match(/step/, assert_raises(RuntimeError, &ask).message)
      end
    end
  end
end
