# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# The simulated framebuffer in isolation — a plain 2D grid of colors the reference
# backend draws into. No IR, no interpreter here: just the screen model and its
# edge-clipping promise.
class TestIRFramebuffer < Minitest::Test
  Framebuffer = RubyGBA::IR::Backends::Reference::Framebuffer

  def test_defaults_to_gba_bitmap_dimensions
    fb = Framebuffer.new
    assert_equal 240, fb.width
    assert_equal 160, fb.height
  end

  def test_set_pixel_round_trips
    fb = Framebuffer.new
    fb.set_pixel(10, 20, 0x1234)
    assert_equal 0x1234, fb.pixel(10, 20)
  end

  def test_unwritten_pixel_reads_the_fill
    fb = Framebuffer.new(fill: 0x7FFF)
    assert_equal 0x7FFF, fb.pixel(0, 0)
  end

  def test_out_of_bounds_write_is_clipped_not_an_error
    fb = Framebuffer.new
    # Writing far off-screen must neither raise nor corrupt a real cell.
    fb.set_pixel(999, 999, 0x001F)
    fb.set_pixel(-5, -5, 0x001F)
    assert_equal 0, fb.pixel(0, 0)
  end

  def test_out_of_bounds_read_returns_nil
    fb = Framebuffer.new
    assert_nil fb.pixel(240, 0)
    assert_nil fb.pixel(0, 160)
    assert_nil fb.pixel(-1, 0)
  end

  def test_fill_rect_fills_only_the_rectangle
    fb = Framebuffer.new
    fb.fill_rect(2, 3, 4, 5, 0x00FF)
    assert_equal 0x00FF, fb.pixel(2, 3)
    assert_equal 0x00FF, fb.pixel(5, 7) # bottom-right corner (2+4-1, 3+5-1)
    assert_equal 0, fb.pixel(6, 3)      # just past the right edge
    assert_equal 0, fb.pixel(2, 8)      # just past the bottom edge
  end

  def test_fill_rect_clips_at_the_screen_edge
    fb = Framebuffer.new(width: 4, height: 4)
    fb.fill_rect(-1, -1, 10, 10, 0x0001) # overflows every edge
    # Every real cell got painted, and nothing raised.
    assert_equal [0x0001] * 16, fb.to_a
  end

  def test_clear_paints_every_pixel
    fb = Framebuffer.new(width: 3, height: 2)
    fb.clear(0x2222)
    assert_equal [0x2222] * 6, fb.to_a
  end
end
