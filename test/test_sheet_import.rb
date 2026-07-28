# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The sheet importer: slice one image into a grid of equal-size cells (a tile sheet
# or a sprite sheet) and hand each cell back as ready-to-use pixels. Two layers are
# tested apart, exactly as the single-image importer is:
#   - Image.slice / Image::Sheet, the conversion, on a fake adapter (no ImageMagick);
#   - the `sheet` DSL verb, that each named cell becomes an ordinary image the rest
#     of the framework can draw.
# The whole path against real PNGs (import -> tiles -> render, on both backends) is
# test_sheet_example.rb.
class TestSheetImport < Minitest::Test
  Image = RubyGBA::Image
  Color = RubyGBA::Color
  Ruby = RubyGBA::IR::Backends::Ruby

  RED  = Color.rgb8(255, 0, 0) # 0x001F
  BLUE = Color.rgb8(0, 0, 255) # 0x7C00
  MARKER = Image::TRANSPARENT  # 0x8000, the see-through marker

  # An adapter that hands back canned dimensions and pixels — lets the importer be
  # tested with no ImageMagick. Same shape the real adapter exposes.
  class FakeAdapter
    def initialize(dims:, rgb: nil, rgba: nil)
      @dims = dims
      @rgb = rgb
      @rgba = rgba
    end

    def dimensions(_path) = @dims
    def rgb_pixels(_path, width:, height:) = @rgb
    def rgba_pixels(_path, width:, height:) = @rgba
  end

  # Run a block with +fake+ standing in as the default image adapter, so the `sheet`
  # verb (which doesn't take an adapter) imports through it and needs no ImageMagick.
  # Restores the real one afterward.
  def with_default_adapter(fake)
    saved = Image.instance_variable_get(:@default_adapter)
    Image.instance_variable_set(:@default_adapter, fake)
    yield
  ensure
    Image.instance_variable_set(:@default_adapter, saved)
  end

  # A 16x8 opaque sheet: an 8x8 solid-red cell, then an 8x8 solid-blue cell.
  def two_tile_rgb
    bytes = (+"").b
    8.times do
      8.times { bytes << 255.chr << 0.chr << 0.chr } # left cell: red
      8.times { bytes << 0.chr << 0.chr << 255.chr } # right cell: blue
    end
    bytes
  end

  # An 8x8 cut-out: an opaque red top row, everything below fully transparent.
  def cutout_rgba
    bytes = (+"").b
    8.times do |y|
      8.times do
        bytes << (y.zero? ? "\xFF\x00\x00\xFF".b : "\x00\x00\x00\x00".b)
      end
    end
    bytes
  end

  # ---- Image.slice / Sheet, on a fake adapter (no external tool) ------------

  def test_slice_divides_the_sheet_into_cells
    sheet = Image.slice("x.png", tile_w: 8, tile_h: 8,
                        adapter: FakeAdapter.new(dims: [16, 8], rgb: two_tile_rgb))

    assert_equal [2, 1], [sheet.cols, sheet.rows]
    assert_equal [8, 8], [sheet.tile_w, sheet.tile_h]
  end

  def test_each_cell_carries_its_own_pixels
    sheet = Image.slice("x.png", tile_w: 8, tile_h: 8,
                        adapter: FakeAdapter.new(dims: [16, 8], rgb: two_tile_rgb))

    assert_equal [RED] * 64, sheet.cell(0, 0).data, "the left cell is all red"
    assert_equal [BLUE] * 64, sheet.cell(1, 0).data, "the right cell is all blue"
    assert_nil sheet.cell(0, 0).transparent, "an opaque sheet's cells carry no marker"
  end

  def test_a_transparent_sheets_cells_mark_see_through_pixels
    sheet = Image.slice("x.png", tile_w: 8, tile_h: 8, transparent: true,
                        adapter: FakeAdapter.new(dims: [8, 8], rgba: cutout_rgba))
    cell = sheet.cell(0, 0)

    assert_equal RED, cell.data[0], "the opaque top-left pixel keeps its color"
    assert_equal MARKER, cell.data[8], "the pixel below it was transparent -> the marker"
    assert_equal MARKER, cell.transparent
  end

  def test_a_size_that_does_not_divide_evenly_is_a_plain_language_error
    err = assert_raises(Image::Error) do
      Image.slice("bad.png", tile_w: 8, tile_h: 8, adapter: FakeAdapter.new(dims: [17, 8]))
    end
    assert_match(/divide evenly/, err.message)
    assert_match(/17x8/, err.message)
  end

  def test_a_cell_outside_the_grid_is_a_plain_language_error
    sheet = Image.slice("x.png", tile_w: 8, tile_h: 8,
                        adapter: FakeAdapter.new(dims: [16, 8], rgb: two_tile_rgb))
    err = assert_raises(Image::Error) { sheet.cell(2, 0) }
    assert_match(/outside/, err.message)
  end

  # ---- the `sheet` verb: each cell becomes a usable image -------------------

  def test_sheet_defines_images_that_draw
    fake = FakeAdapter.new(dims: [16, 8], rgb: two_tile_rgb)
    program = with_default_adapter(fake) do
      builder = RubyGBA::Builder.new
      builder.instance_eval do
        screen :bitmap
        clear_screen :black
        sheet "tiles.png", tile: 8, as: { brick: [0, 0], floor: [1, 0] }
        blit :brick, 0, 0
        blit :floor, 8, 0
        halt
      end
      builder.emit_pending_functions
      builder.program
    end

    screen = Ruby.new.run(program).screen
    assert_equal RED, screen.pixel(2, 2), "cell [0,0] imported as :brick and drew red"
    assert_equal BLUE, screen.pixel(10, 2), "cell [1,0] imported as :floor and drew blue"
  end

  def test_a_number_addresses_a_cell_left_to_right
    # In a 2-across sheet, cell number 1 is [1, 0] — the same right (blue) cell.
    fake = FakeAdapter.new(dims: [16, 8], rgb: two_tile_rgb)
    program = with_default_adapter(fake) do
      builder = RubyGBA::Builder.new
      builder.instance_eval do
        screen :bitmap
        clear_screen :black
        sheet "tiles.png", tile: 8, as: { second: 1 }
        blit :second, 0, 0
        halt
      end
      builder.emit_pending_functions
      builder.program
    end

    assert_equal BLUE, Ruby.new.run(program).screen.pixel(2, 2)
  end

  def test_empty_as_is_rejected
    builder = RubyGBA::Builder.new
    err = assert_raises(ArgumentError) { builder.sheet("x.png", tile: 8, as: {}) }
    assert_match(/at least one cell/, err.message)
  end

  def test_a_bad_tile_size_is_rejected
    builder = RubyGBA::Builder.new
    err = assert_raises(ArgumentError) { builder.sheet("x.png", tile: "big", as: { a: 0 }) }
    assert_match(/square.*\[width, height\]|width, height/, err.message)
  end

  def test_a_bad_cell_address_is_rejected
    fake = FakeAdapter.new(dims: [16, 8], rgb: two_tile_rgb)
    with_default_adapter(fake) do
      builder = RubyGBA::Builder.new
      err = assert_raises(ArgumentError) { builder.sheet("x.png", tile: 8, as: { a: "nope" }) }
      assert_match(/column, row.*or a cell number|cell number/, err.message)
    end
  end
end
