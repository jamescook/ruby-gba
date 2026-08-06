# frozen_string_literal: true

require "test_helper"

class TestTestPatterns < Minitest::Test
  def test_solid_fill_builds
    rom = RubyGBA::TestPatterns.solid_fill(:red)
    assert_kind_of RubyGBA::ROM, rom
    result = RubyGBA::ROMValidator.check(rom)
    assert result.ok?, "solid_fill ROM failed validation: #{result.report}"
  end

  def test_solid_fill_default_color
    rom = RubyGBA::TestPatterns.solid_fill
    assert_kind_of RubyGBA::ROM, rom
  end

  def test_color_bars_builds
    rom = RubyGBA::TestPatterns.color_bars
    assert_kind_of RubyGBA::ROM, rom
    result = RubyGBA::ROMValidator.check(rom)
    assert result.ok?, "color_bars ROM failed validation: #{result.report}"
  end

  def test_corners_builds
    rom = RubyGBA::TestPatterns.corners
    assert_kind_of RubyGBA::ROM, rom
    result = RubyGBA::ROMValidator.check(rom)
    assert result.ok?, "corners ROM failed validation: #{result.report}"
  end

  def test_crosshair_builds
    rom = RubyGBA::TestPatterns.crosshair
    assert_kind_of RubyGBA::ROM, rom
    result = RubyGBA::ROMValidator.check(rom)
    assert result.ok?, "crosshair ROM failed validation: #{result.report}"
  end
end

class TestTestPatternsRendering < Minitest::Test

  def setup
    require_gemba_core!
  end

  def test_solid_fill_renders_red
    # Full-screen fill = ~150K instructions; needs several frames to complete
    rom = RubyGBA::TestPatterns.solid_fill(:red)
    v = RubyGBA::Verifier.new(rom, frames: 10)
    assert v.red?(0, 0), "Top-left should be red, got #{v.pixel(0, 0)}"
    assert v.red?(120, 80), "Center should be red, got #{v.pixel(120, 80)}"
    assert v.red?(239, 159), "Bottom-right should be red, got #{v.pixel(239, 159)}"
  end

  def test_color_bars_renders_rgb
    # Three 80x160 bars = ~150K instructions total
    rom = RubyGBA::TestPatterns.color_bars
    v = RubyGBA::Verifier.new(rom, frames: 10)
    assert v.red?(40, 80), "Left third should be red, got #{v.pixel(40, 80)}"
    assert v.green?(120, 80), "Middle third should be green, got #{v.pixel(120, 80)}"
    assert v.blue?(200, 80), "Right third should be blue, got #{v.pixel(200, 80)}"
  end

  def test_corners_renders
    rom = RubyGBA::TestPatterns.corners
    v = RubyGBA::Verifier.new(rom)
    assert v.red?(5, 5), "Top-left corner should be red"
    assert v.green?(235, 5), "Top-right corner should be green"
    assert v.blue?(5, 155), "Bottom-left corner should be blue"
    assert v.white?(235, 155), "Bottom-right corner should be white"
    assert v.black?(120, 80), "Center should be black"
  end

  def test_crosshair_renders
    rom = RubyGBA::TestPatterns.crosshair
    v = RubyGBA::Verifier.new(rom)
    assert v.red?(120, 80), "Center should be red, got #{v.pixel(120, 80)}"
    assert v.white?(10, 79), "Horizontal line should be white"
    assert v.white?(119, 10), "Vertical line should be white"
    assert v.black?(0, 0), "Corner should be black"
  end
end
