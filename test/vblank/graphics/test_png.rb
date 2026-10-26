# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "png_reading"

# WRITING A PICTURE TO A FILE. The framework reads art out of PNG files; this is the other
# direction — a screen, or any block of the console's colours, written as a PNG a person can
# open.
#
# What is checked is the file, read back by something that is not the writer: an image tool
# that knows nothing about this framework, and the PNG format's own rules read by hand.
class TestPNG < Minitest::Test
  # The image tool that reads the pictures back is a child process, which Ruby cannot reliably
  # start from inside a Ractor — the spawn can wait for ever — so on the main Ractor, not in
  # the pool. See test_helper.
  runs_on_the_main_ractor!

  include PNGReading

  PNG = VBlank::Graphics::PNG
  Image = VBlank::Graphics::Image

  RED = 0x001F
  GREEN = 0x03E0
  BLUE = 0x7C00
  WHITE = 0x7FFF

  # The colours an image tool reads back out of a PNG file, as the console's own.
  private def read_back(path, width, height) = Image.load(path, width: width, height: height).data

  def test_a_written_picture_reads_back_as_the_colours_it_was_given
    Dir.mktmpdir do |dir|
      path = PNG.write(File.join(dir, "four.png"), width: 2, height: 2, pixels: [RED, GREEN, BLUE, WHITE])

      assert_equal [RED, GREEN, BLUE, WHITE], read_back(path, 2, 2)
    end
  end

  # A whole screen, every pixel its own colour where it can be: the colour is worked out from
  # where the pixel is, so a row or a column written in the wrong place reads back wrong.
  def test_a_whole_screen_reads_back_pixel_for_pixel
    pixels = Array.new(240 * 160) { |at| ((at % 240) % 32) | (((at / 240) % 32) << 5) | ((at % 7) << 10) }
    Dir.mktmpdir do |dir|
      path = PNG.write(File.join(dir, "screen.png"), width: 240, height: 160, pixels: pixels)

      assert_equal pixels, read_back(path, 240, 160)
    end
  end

  def test_a_picture_of_another_shape_keeps_its_rows
    pixels = [RED, GREEN, BLUE, WHITE, WHITE, BLUE] # three across, two down
    Dir.mktmpdir do |dir|
      path = PNG.write(File.join(dir, "wide.png"), width: 3, height: 2, pixels: pixels)

      assert_equal pixels, read_back(path, 3, 2)
    end
  end

  # A PICTURE WITH SEE-THROUGH PARTS, which is what a sprite's art is: how solid each pixel is
  # is handed over beside its colour, 0 for see-through up to 255 for solid. Read back as a
  # cut-out, the see-through pixels are the marker that means "draw nothing here".
  def test_a_picture_can_have_see_through_pixels
    Dir.mktmpdir do |dir|
      path = PNG.write(File.join(dir, "cutout.png"), width: 2, height: 2,
                                                     pixels: [RED, GREEN, BLUE, WHITE], alpha: [255, 255, 0, 0])
      seen = Image.load(path, width: 2, height: 2, transparent: true).data

      assert_equal [RED, GREEN, Image::TRANSPARENT, Image::TRANSPARENT], seen
    end
  end

  def test_the_wrong_number_of_see_through_values_is_refused
    err = assert_raises(ArgumentError) { PNG.encode(width: 2, height: 1, pixels: [RED, GREEN], alpha: [255]) }

    assert_match(/alpha: has 1 value/, err.message)
  end

  # How solid a pixel is fits in one byte, so a value outside that is a slip and not a picture.
  def test_a_see_through_value_outside_a_byte_is_refused
    [256, -1].each do |wrong|
      err = assert_raises(ArgumentError) { PNG.encode(width: 2, height: 1, pixels: [RED, GREEN], alpha: [255, wrong]) }

      assert_match(/#{wrong}/, err.message)
      assert_match(/0 to 255/, err.message)
    end
  end

  # A picture with no width or no height is not a picture, and written out it would be a
  # file no viewer opens.
  def test_a_picture_with_no_size_is_refused
    [[0, 4], [4, 0], [-1, 1]].each do |width, height|
      err = assert_raises(ArgumentError) { PNG.encode(width: width, height: height, pixels: []) }

      assert_match(/at least 1/, err.message)
    end
  end

  # The size, asked of the file itself: the image tool's own word for how wide and tall it is.
  def test_a_written_picture_is_the_size_it_was_given
    Dir.mktmpdir do |dir|
      path = PNG.write(File.join(dir, "wide.png"), width: 7, height: 3, pixels: Array.new(21, BLUE))

      assert_equal [7, 3], Image.default_adapter.dimensions(path)
    end
  end

  # The bytes themselves, read by the format's rules: the signature every PNG starts with,
  # then each row as one byte saying it is stored as it stands and three bytes a pixel. A
  # colour here has 32 levels a channel and a PNG has 256, so each is stretched to fill: full
  # stays full, and half way is 132.
  def test_the_bytes_are_a_truecolour_png
    png = PNG.encode(width: 2, height: 1, pixels: [WHITE, 16])

    assert_equal [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], png.bytes.first(8)
    assert_equal [0, 255, 255, 255, 132, 0, 0], png_rows(png)
    assert_equal [2, 1, 8, 2], png_chunk(png, "IHDR").unpack("N2C2"), "width, height, 8 bits a channel, truecolour"
  end

  # A picture with the wrong number of pixels would be written sheared, every row after the
  # first starting in the wrong place, so it is refused where it is handed over.
  def test_the_wrong_number_of_pixels_is_refused
    err = assert_raises(ArgumentError) { PNG.encode(width: 2, height: 2, pixels: [RED, GREEN, BLUE]) }

    assert_match(/3 pixels/, err.message)
    assert_match(/4/, err.message, "and it says how many a 2 by 2 picture has")
  end
end
