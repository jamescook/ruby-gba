# frozen_string_literal: true

require "test_helper"

# The built-in test-pattern ROMs (lib/vblank/cartridge/test_patterns.rb) are Advance
# cartridges, built and checked here; each one drawing its picture in the emulator is in
# test_patterns_rendering.rb beside this file.
class TestTestPatterns < Minitest::Test
  def test_solid_fill_builds
    rom = VBlank::Cartridge::TestPatterns.solid_fill(:red)
    assert_kind_of VBlank::Cartridge::ROM, rom
    result = VBlank::Cartridge::ROMValidator.check(rom)
    assert result.ok?, "solid_fill ROM failed validation: #{result.report}"
  end

  def test_solid_fill_default_color
    rom = VBlank::Cartridge::TestPatterns.solid_fill
    assert_kind_of VBlank::Cartridge::ROM, rom
  end

  def test_color_bars_builds
    rom = VBlank::Cartridge::TestPatterns.color_bars
    assert_kind_of VBlank::Cartridge::ROM, rom
    result = VBlank::Cartridge::ROMValidator.check(rom)
    assert result.ok?, "color_bars ROM failed validation: #{result.report}"
  end

  def test_corners_builds
    rom = VBlank::Cartridge::TestPatterns.corners
    assert_kind_of VBlank::Cartridge::ROM, rom
    result = VBlank::Cartridge::ROMValidator.check(rom)
    assert result.ok?, "corners ROM failed validation: #{result.report}"
  end

  def test_crosshair_builds
    rom = VBlank::Cartridge::TestPatterns.crosshair
    assert_kind_of VBlank::Cartridge::ROM, rom
    result = VBlank::Cartridge::ROMValidator.check(rom)
    assert result.ok?, "crosshair ROM failed validation: #{result.report}"
  end
end
