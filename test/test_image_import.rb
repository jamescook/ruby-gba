# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The image importer (RubyGBA::Image): turn a real image file on the host machine
# into GBA-ready pixels, behind a swappable adapter.
#
# Two layers are tested apart:
#   - the library's conversion (RGB -> the console's color) with a fake adapter,
#     so it runs with no external tool;
#   - the real ImageMagick adapter, end-to-end against committed PNG fixtures.
#
# The ImageMagick tests do NOT skip when the tool is missing — importing is the
# whole point of the feature, so its absence is a real failure with a message
# that names the install (not a silent green run).
class TestImageImport < Minitest::Test
  include RubyGBA::IR::Build
  include GembaSupport

  Image = RubyGBA::Image
  Color = RubyGBA::Color
  Ruby = RubyGBA::IR::Backends::Ruby

  FIXTURES = File.expand_path("fixtures", __dir__)
  # The 2x2 fixture is red / green / blue / white, row-major (top-left first).
  TWO_BY_TWO = File.join(FIXTURES, "import_2x2.png")
  SOLID_RED  = File.join(FIXTURES, "import_solid_red_4x4.png")
  EXPECTED   = [0x001F, 0x03E0, 0x7C00, 0x7FFF].freeze # red, green, blue, white

  # An adapter that returns canned RGB — lets the library be tested with no
  # ImageMagick at all. Its job is exactly the real adapter's: hand back
  # width*height*3 raw bytes.
  class FakeAdapter
    def initialize(rgb) = @rgb = rgb
    def rgb_pixels(_path, width:, height:) = @rgb
  end

  # ---- the library, on a fake adapter (no external tool) --------------------

  def test_load_returns_a_bitmap_of_the_requested_size
    rgb = [255, 0, 0, 0, 255, 0].pack("C*") # two pixels: red, green
    bmp = Image.load("anything.png", width: 2, height: 1, adapter: FakeAdapter.new(rgb))

    assert_equal 2, bmp.width
    assert_equal 1, bmp.height
  end

  def test_load_downsamples_rgb_to_the_consoles_color
    # Each pixel goes through Color.rgb8, the codebase's single 8-bit downsample,
    # so an imported red matches a hand-written :red.
    rgb = [255, 0, 0, 0, 255, 0].pack("C*")
    bmp = Image.load("anything.png", width: 2, height: 1, adapter: FakeAdapter.new(rgb))

    assert_equal [Color.resolve(:red), Color.resolve(:green)], bmp.data
    assert(bmp.data.all?(Integer), "data is a flat list of color integers")
  end

  def test_load_rejects_the_wrong_amount_of_pixel_data
    rgb = [255, 0, 0].pack("C*") # one pixel, but we ask for four
    err = assert_raises(Image::Error) do
      Image.load("anything.png", width: 2, height: 2, adapter: FakeAdapter.new(rgb))
    end
    assert_match(/2x2/, err.message)
  end

  def test_missing_image_magick_is_a_plain_language_error
    # Simulate "not installed" by making every candidate binary look absent, then
    # assert the error tells the user how to fix it — no stack-trace leak.
    adapter = Image::Adapters::ImageMagick.new
    adapter.define_singleton_method(:available?) { |_name| false }

    err = assert_raises(Image::BackendUnavailable) do
      adapter.rgb_pixels(TWO_BY_TWO, width: 2, height: 2)
    end
    assert_match(/imagemagick/i, err.message)
    assert_match(/brew install|apt-get install/i, err.message)
  end

  # ---- the real ImageMagick adapter, end-to-end (must have the tool) --------

  def test_image_magick_converts_a_real_png_to_the_expected_colors
    bmp = Image.load(TWO_BY_TWO, width: 2, height: 2)

    assert_equal 4, bmp.data.length
    assert_equal EXPECTED, bmp.data,
                 "the 2x2 fixture converts to red, green, blue, white (row-major)"
  end

  def test_image_magick_resizes_down_to_the_requested_size
    # A 4x4 solid red asked for at 2x2: resize is exercised, and a solid color
    # averages to itself, so the result is unambiguously four reds.
    bmp = Image.load(SOLID_RED, width: 2, height: 2)

    assert_equal [Color.resolve(:red)] * 4, bmp.data
  end

  # ---- the whole path: import -> embed -> blit ------------------------------

  def photo_program(x, y)
    fixture = TWO_BY_TWO
    builder = RubyGBA::Builder.new
    builder.instance_eval do
      display :bitmap
      clear_screen :black
      image :photo, from: fixture, width: 2, height: 2 # imported and embedded
      blit :photo, x, y
      halt
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_imported_image_embeds_and_blits_on_the_interpreter
    screen = Ruby.new.run(photo_program(10, 20)).screen

    assert_equal EXPECTED[0], screen.pixel(10, 20), "top-left red"
    assert_equal EXPECTED[1], screen.pixel(11, 20), "top-right green"
    assert_equal EXPECTED[2], screen.pixel(10, 21), "bottom-left blue"
    assert_equal EXPECTED[3], screen.pixel(11, 21), "bottom-right white"
  end

  def test_imported_image_draws_on_hardware
    rom = RubyGBA::ROM.assemble(
      RubyGBA::IR::Backends::GBA.new.lower(photo_program(10, 20)),
      title: "PHOTO", code: "BPHT", maker: "01",
    )
    v = assert_gemba_loads_rom(rom)
    assert v.red?(10, 20),   "top-left red"
    assert v.green?(11, 20), "top-right green"
    assert v.blue?(10, 21),  "bottom-left blue"
    assert v.white?(11, 21), "bottom-right white"
  end
end
