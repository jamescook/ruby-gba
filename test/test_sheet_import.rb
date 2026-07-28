# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Importing art from image files, folded into the verbs that use it:
#   - `tiles from:` slices a tile sheet and points each map-character at a cell;
#   - `sprite frames_from:` slices a sprite sheet into animation frames.
# Two layers are tested apart, as the single-image importer is:
#   - Image.slice / Image::Sheet, the conversion, on a fake adapter (no ImageMagick);
#   - the verbs, that imported cells become drawable tiles / animating frames.
# The whole path against real PNGs (on both backends) is test_sheet_example.rb.
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

  # Run a block with +fake+ standing in as the default image adapter, so the verbs
  # (which don't take an adapter) import through it and need no ImageMagick. An
  # absolute image path skips the on-disk lookup, so the fake path never has to exist.
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

  def two_tile_fake = FakeAdapter.new(dims: [16, 8], rgb: two_tile_rgb)

  # An 8x8 cut-out: an opaque red top row, everything below fully transparent.
  def cutout_rgba
    bytes = (+"").b
    8.times do |y|
      8.times { bytes << (y.zero? ? "\xFF\x00\x00\xFF".b : "\x00\x00\x00\x00".b) }
    end
    bytes
  end

  # ---- Image.slice / Sheet, on a fake adapter (the engine) ------------------

  def test_slice_divides_the_sheet_into_cells
    sheet = Image.slice("x.png", tile_w: 8, tile_h: 8, adapter: two_tile_fake)

    assert_equal [2, 1], [sheet.cols, sheet.rows]
    assert_equal [RED] * 64, sheet.cell(0, 0).data, "the left cell is all red"
    assert_equal [BLUE] * 64, sheet.cell(1, 0).data, "the right cell is all blue"
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
    sheet = Image.slice("x.png", tile_w: 8, tile_h: 8, adapter: two_tile_fake)
    assert_match(/outside/, assert_raises(Image::Error) { sheet.cell(2, 0) }.message)
  end

  # ---- `tiles from:`: a map-character points straight at a sheet cell --------

  def test_tiles_from_imports_cells_and_renders_them
    program = with_default_adapter(two_tile_fake) do
      builder = RubyGBA::Builder.new
      builder.instance_eval do
        screen :tiled
        tiles :dungeon, from: "/sheet/tiles.png", tile: 8, "#" => 0, "." => 1
        background :bg, tiles: :dungeon, map: ["#.", ".#"]
        game_loop { wait_vblank; halt }
      end
      builder.emit_pending_functions
      builder.program
    end

    s = Ruby.new.run(program, max_steps: 200).screen
    assert_equal RED,  s.pixel(4, 4),  "cell 0 (#) painted the top-left tile red"
    assert_equal BLUE, s.pixel(12, 4), "cell 1 (.) painted the next tile blue"
  end

  def test_tiles_from_needs_a_tile_size
    builder = RubyGBA::Builder.new
    err = assert_raises(ArgumentError) do
      builder.instance_eval { screen :tiled; tiles :d, from: "/sheet/x.png", "#" => 0 }
    end
    assert_match(/tile:/, err.message)
  end

  def test_tiles_from_rejects_a_bad_cell_address
    with_default_adapter(two_tile_fake) do
      builder = RubyGBA::Builder.new
      err = assert_raises(ArgumentError) do
        builder.instance_eval { screen :tiled; tiles :d, from: "/sheet/tiles.png", tile: 8, "#" => "nope" }
      end
      assert_match(/cell number or \[column, row\]/, err.message)
    end
  end

  # ---- `sprite frames_from:`: a sheet becomes animation frames ---------------

  def test_frames_from_imports_frames_and_draws_them
    # A slow rate keeps the sprite on its first frame (red) for the whole short run,
    # so the imported frame is what's on screen.
    program = with_default_adapter(two_tile_fake) do
      builder = RubyGBA::Builder.new
      builder.instance_eval do
        screen :bitmap
        clear_screen :black
        hero = sprite :hero, at: [10, 10], frames_from: "/sheet/walk.png", tile: 8, rate: 1000
        game_loop { wait_vblank; hero.move(1, 0); halt }
      end
      builder.emit_pending_functions
      builder.program
    end

    assert_equal RED, Ruby.new.run(program, max_steps: 200).screen.pixel(12, 12),
                 "the first imported frame drew the sprite red"
  end

  def test_frames_from_and_frames_together_are_rejected
    builder = RubyGBA::Builder.new
    err = assert_raises(ArgumentError) do
      builder.instance_eval do
        screen :bitmap
        sprite :h, at: [0, 0], frames_from: "/sheet/x.png", frames: %i[a b], tile: 8, rate: 2
      end
    end
    assert_match(/frames: OR frames_from:/, err.message)
  end

  # ---- paths resolve next to the script, not the working directory -----------

  def test_a_missing_image_says_where_it_looked
    builder = RubyGBA::Builder.new
    err = assert_raises(ArgumentError) do
      builder.instance_eval { screen :tiled; tiles :d, from: "definitely_missing.png", tile: 8, "#" => 0 }
    end
    assert_match(/can't find/, err.message)
    assert_match(/definitely_missing\.png/, err.message)
  end
end
