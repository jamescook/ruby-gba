# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# The `image` DSL verb (array form): define a bitmap from raw pixel data — the
# shape the image importer produces — validate its dimensions, and pack the
# pixels to the GBA's 15-bit BGR555 for embedding in the ROM. Drawing it is
# blit's job (separate); here we cover the definition and its validation.
class TestImage < Minitest::Test
  Builder = RubyGBA::Builder
  Color = RubyGBA::Color

  def build(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def bitmap_of(program, name)
    program.each.find { |n| n.kind == :bitmap && n[:name] == name }
  end

  def test_array_form_packs_pixels_as_bgr555_halfwords
    prog = build { image :duo, width: 2, height: 1, data: [:red, :blue] }
    node = bitmap_of(prog, :duo)

    assert_equal 2, node[:width]
    assert_equal 1, node[:height]
    # red = 0x001F, blue = 0x7C00, stored as little-endian 16-bit halfwords.
    assert_equal "\x1F\x00\x00\x7C".b, node[:pixels]
  end

  def test_accepts_raw_bgr555_integers_too
    # The importer emits resolved BGR555 ints; they pass straight through.
    prog = build { image :one, width: 1, height: 1, data: [0x7C00] }
    assert_equal "\x00\x7C".b, bitmap_of(prog, :one)[:pixels]
  end

  def test_rejects_nonpositive_dimensions
    assert_raises(ArgumentError) { build { image :x, width: 0, height: 4, data: [] } }
    assert_raises(ArgumentError) { build { image :x, width: 4, height: -1, data: [] } }
  end

  def test_rejects_a_data_length_that_does_not_match_the_dimensions
    err = assert_raises(ArgumentError) do
      build { image :x, width: 2, height: 2, data: [:red, :blue] } # needs 4
    end
    assert_match(/4/, err.message)   # names the expected count
    assert_match(/2/, err.message)   # and what was given
  end

  # ---- ASCII-art authoring form ----

  def test_ascii_form_infers_dimensions_and_maps_chars
    prog = build do
      image :bar, "." => :black, "#" => :red do
        <<~ART
          .#.
          ###
        ART
      end
    end
    node = bitmap_of(prog, :bar)

    assert_equal 3, node[:width]
    assert_equal 2, node[:height]
    black = Color.resolve(:black)
    red = Color.resolve(:red)
    assert_equal [black, red, black, red, red, red].pack("v*"), node[:pixels]
    assert_nil node[:transparent], "no :transparent char means an opaque bitmap"
  end

  def test_ascii_form_marks_transparent_pixels
    prog = build do
      image :dot, "." => :transparent, "#" => :red do
        <<~ART
          .#.
        ART
      end
    end
    node = bitmap_of(prog, :dot)

    refute_nil node[:transparent]
    lo, mid, hi = node[:pixels].unpack("v3")
    assert_equal node[:transparent], lo, "'.' is transparent, not a color"
    assert_equal Color.resolve(:red), mid
    assert_equal node[:transparent], hi
  end

  def test_ascii_form_rejects_ragged_rows
    err = assert_raises(ArgumentError) do
      build { image(:x, "#" => :red) { "##\n#\n" } }
    end
    assert_match(/ragged|same length/i, err.message)
  end

  def test_ascii_form_rejects_an_unmapped_char
    err = assert_raises(ArgumentError) do
      build { image(:x, "#" => :red) { "#?#\n" } }
    end
    assert_match(/\?/, err.message)
  end

  # ---- image + blit, observed on the fake screen ----

  def screen_after(&block)
    prog = build(&block)
    RubyGBA::IR::Backends::Reference.new.run(prog).screen
  end

  def test_blit_draws_each_pixel_of_the_image_at_the_position
    fb = screen_after do
      screen :bitmap
      image :quad, width: 2, height: 2, data: [:red, :green, :blue, :white]
      blit :quad, 10, 20
    end

    assert_equal Color.resolve(:red),   fb.pixel(10, 20)
    assert_equal Color.resolve(:green), fb.pixel(11, 20)
    assert_equal Color.resolve(:blue),  fb.pixel(10, 21)
    assert_equal Color.resolve(:white), fb.pixel(11, 21)
    assert_equal 0, fb.pixel(12, 20) # just outside the image
  end

  def test_blit_follows_a_variable_position
    fb = screen_after do
      screen :bitmap
      image :dot, width: 1, height: 1, data: [:red]
      set :px, 100
      set :py, 50
      blit :dot, :px, :py
    end

    assert_equal Color.resolve(:red), fb.pixel(100, 50)
    assert_equal 0, fb.pixel(99, 50)
  end

  def test_blit_lets_the_background_show_through_transparent_pixels
    fb = screen_after do
      screen :bitmap
      clear_screen :blue
      image :dot, "." => :transparent, "#" => :red do
        <<~ART
          .#.
        ART
      end
      blit :dot, 10, 10
    end

    assert_equal Color.resolve(:blue), fb.pixel(10, 10), "transparent -> background shows"
    assert_equal Color.resolve(:red),  fb.pixel(11, 10), "the lit pixel is drawn"
    assert_equal Color.resolve(:blue), fb.pixel(12, 10), "transparent -> background shows"
  end
end
