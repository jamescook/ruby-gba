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
end
