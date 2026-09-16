# frozen_string_literal: true

require "test_helper"

class TestColor < Minitest::Test
  def test_rgb_packs_channels
    # Red in low bits, green in middle, blue in high bits
    assert_equal 0x001F, RubyGBA::Color.rgb(31, 0, 0)   # full red
    assert_equal 0x03E0, RubyGBA::Color.rgb(0, 31, 0)   # full green
    assert_equal 0x7C00, RubyGBA::Color.rgb(0, 0, 31)   # full blue
    assert_equal 0x7FFF, RubyGBA::Color.rgb(31, 31, 31)  # white
    assert_equal 0x0000, RubyGBA::Color.rgb(0, 0, 0)     # black
  end

  def test_rgb_rejects_out_of_range
    err = assert_raises(ArgumentError) { RubyGBA::Color.rgb(32, 0, 0) }
    assert_match(/red.*out of range.*0-31/, err.message)
    assert_match(/rgb8/, err.message, "should hint about rgb8 for large values")

    err = assert_raises(ArgumentError) { RubyGBA::Color.rgb(0, -1, 0) }
    assert_match(/green.*out of range/, err.message)
  end

  def test_rgb8_downsamples
    assert_equal RubyGBA::Color.rgb(31, 0, 0), RubyGBA::Color.rgb8(255, 0, 0)
    assert_equal RubyGBA::Color.rgb(0, 31, 0), RubyGBA::Color.rgb8(0, 255, 0)
    assert_equal RubyGBA::Color.rgb(16, 16, 16), RubyGBA::Color.rgb8(128, 128, 128)
  end

  def test_rgb8_rejects_out_of_range
    assert_raises(ArgumentError) { RubyGBA::Color.rgb8(256, 0, 0) }
    assert_raises(ArgumentError) { RubyGBA::Color.rgb8(0, -1, 0) }
  end

  def test_from_hex_with_hash
    assert_equal 0x001F, RubyGBA::Color.from_hex("#FF0000")  # red
    assert_equal 0x03E0, RubyGBA::Color.from_hex("#00FF00")  # green
    assert_equal 0x7C00, RubyGBA::Color.from_hex("#0000FF")  # blue
  end

  def test_from_hex_without_hash
    assert_equal 0x7FFF, RubyGBA::Color.from_hex("FFFFFF")
  end

  def test_from_hex_downsamples
    # 0x80 >> 3 = 16, so mid-gray each channel
    result = RubyGBA::Color.from_hex("#808080")
    assert_equal RubyGBA::Color.rgb(16, 16, 16), result
  end

  def test_from_hex_rejects_invalid
    assert_raises(ArgumentError) { RubyGBA::Color.from_hex("nope") }
    assert_raises(ArgumentError) { RubyGBA::Color.from_hex("#FFF") }
  end

  def test_resolve_symbol
    assert_equal 0x001F, RubyGBA::Color.resolve(:red)
    assert_equal 0x0000, RubyGBA::Color.resolve(:black)
    assert_equal 0x7FFF, RubyGBA::Color.resolve(:white)
  end

  def test_resolve_integer_passthrough
    assert_equal 0x001F, RubyGBA::Color.resolve(0x001F)
  end

  def test_resolve_integer_masks_to_15bit
    assert_equal 0x7FFF, RubyGBA::Color.resolve(0xFFFF)
  end

  def test_resolve_string
    assert_equal 0x001F, RubyGBA::Color.resolve("#FF0000")
  end

  def test_resolve_unknown_symbol_raises
    assert_raises(ArgumentError) { RubyGBA::Color.resolve(:chartreuse) }
  end

  def test_presets_match_rgb
    assert_equal RubyGBA::Color.rgb(31, 0, 0), RubyGBA::Color::PRESETS[:red]
    assert_equal RubyGBA::Color.rgb(0, 31, 0), RubyGBA::Color::PRESETS[:green]
    assert_equal RubyGBA::Color.rgb(0, 0, 31), RubyGBA::Color::PRESETS[:blue]
    assert_equal RubyGBA::Color.rgb(31, 31, 0), RubyGBA::Color::PRESETS[:yellow]
  end
end
