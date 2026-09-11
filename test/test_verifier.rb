# frozen_string_literal: true

require "test_helper"

class TestVerifier < Minitest::Test

  def setup
    require_emulator!
  end

  def test_red_pixel_readback
    rom = RubyGBA.build("REDPIX", code: "BRDP", maker: "01") do
      screen :bitmap
      pixel 120, 80, :red
      halt
    end
    v = RubyGBA::Verifier.new(rom)
    assert v.red?(120, 80), "Expected red at (120, 80), got #{v.pixel(120, 80)}"
  end

  def test_black_background
    rom = RubyGBA.build("REDPIX", code: "BRDP", maker: "01") do
      screen :bitmap
      pixel 120, 80, :red
      halt
    end
    v = RubyGBA::Verifier.new(rom)
    assert v.black?(0, 0), "Expected black at (0, 0), got #{v.pixel(0, 0)}"
  end

  def test_green_pixel_readback
    rom = RubyGBA.build("GRNPIX", code: "BGRP", maker: "01") do
      screen :bitmap
      pixel 50, 50, :green
      halt
    end
    v = RubyGBA::Verifier.new(rom)
    assert v.green?(50, 50), "Expected green at (50, 50), got #{v.pixel(50, 50)}"
  end

  def test_blue_pixel_readback
    rom = RubyGBA.build("BLUPIX", code: "BBLP", maker: "01") do
      screen :bitmap
      pixel 200, 100, :blue
      halt
    end
    v = RubyGBA::Verifier.new(rom)
    assert v.blue?(200, 100), "Expected blue at (200, 100), got #{v.pixel(200, 100)}"
  end

  def test_fill_rect_region
    rom = RubyGBA.build("FILL", code: "BFIL", maker: "01") do
      screen :bitmap
      fill_rect 10, 10, 20, 20, :red
      halt
    end
    v = RubyGBA::Verifier.new(rom)
    assert v.region_color?(10, 10, 20, 20, :red),
           "Expected all red in rect. Mismatch: #{v.region_mismatch(10, 10, 20, 20, :red)}"
  end

  def test_fill_rect_outside_is_black
    rom = RubyGBA.build("FILL", code: "BFIL", maker: "01") do
      screen :bitmap
      fill_rect 100, 70, 40, 20, :blue
      halt
    end
    v = RubyGBA::Verifier.new(rom)
    assert v.black?(0, 0), "Expected black outside rect"
    assert v.black?(99, 70), "Expected black just outside rect"
    assert v.blue?(100, 70), "Expected blue inside rect"
  end

  def test_pixel_gba_returns_15bit
    rom = RubyGBA.build("WHITE", code: "BWHT", maker: "01") do
      screen :bitmap
      pixel 0, 0, :white
      halt
    end
    v = RubyGBA::Verifier.new(rom)
    assert_equal 0x7FFF, v.pixel_gba(0, 0)
  end

  def test_all_black_empty_screen
    rom = RubyGBA.build("EMPTY", code: "BEMP", maker: "01") do
      screen :bitmap
      halt
    end
    v = RubyGBA::Verifier.new(rom)
    assert v.all_black?, "Expected all black for empty screen"
  end

  def test_all_black_false_when_pixel_drawn
    rom = RubyGBA.build("DOT", code: "BDOT", maker: "01") do
      screen :bitmap
      pixel 0, 0, :white
      halt
    end
    v = RubyGBA::Verifier.new(rom)
    refute v.all_black?, "Screen should not be all black"
  end

  def test_screen_map
    rom = RubyGBA.build("RECT", code: "BRCT", maker: "01") do
      screen :bitmap
      fill_rect 0, 0, 16, 16, :red
      halt
    end
    v = RubyGBA::Verifier.new(rom)
    map = v.screen_map
    # Top-left 2x2 tiles should be R, rest should be .
    lines = map.split("\n")
    assert_equal "R", lines[0][0], "Expected R in top-left tile"
    assert_equal "R", lines[1][1], "Expected R in second tile row"
    assert_equal ".", lines[0][2], "Expected . outside rect"
  end

  def test_report
    rom = RubyGBA.build("REPORT", code: "BRPT", maker: "01") do
      screen :bitmap
      fill_rect 10, 10, 20, 20, :green
      halt
    end
    v = RubyGBA::Verifier.new(rom)
    report = v.report
    assert_includes report, "Frame Verifier Report"
    assert_includes report, "Unique colors"
    assert_includes report, "(black)"
    assert_includes report, "(green)"
  end

  def test_region_mismatch_returns_nil_on_match
    rom = RubyGBA.build("MATCH", code: "BMCH", maker: "01") do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red
      halt
    end
    v = RubyGBA::Verifier.new(rom)
    assert_nil v.region_mismatch(0, 0, 10, 10, :red)
  end

  def test_region_mismatch_returns_details
    rom = RubyGBA.build("MISMATCH", code: "BMIS", maker: "01") do
      screen :bitmap
      pixel 5, 5, :red
      halt
    end
    v = RubyGBA::Verifier.new(rom)
    info = v.region_mismatch(0, 0, 10, 10, :red)
    refute_nil info, "Expected mismatch info for non-uniform region"
    assert_equal 0, info[:x]
    assert_equal 0, info[:y]
  end

  def test_coords_validation
    rom = RubyGBA.build("BOUNDS", code: "BBND", maker: "01") do
      screen :bitmap
      halt
    end
    v = RubyGBA::Verifier.new(rom)
    assert_raises(ArgumentError) { v.pixel(240, 0) }
    assert_raises(ArgumentError) { v.pixel(0, 160) }
    assert_raises(ArgumentError) { v.pixel(-1, 0) }
  end

  # A verified ROM goes to a temporary file, and the emulator keeps a cartridge's save
  # memory in a .sav beside whatever ROM it opened — creating it whether the game saves
  # anything or not. That is one abandoned file per verification, and this suite verifies
  # thousands. So the save goes in a directory of the Verifier's own instead.
  def test_verifying_a_rom_leaves_no_save_file_loose_in_the_temp_directory
    rom = RubyGBA.build("SAVER", code: "BSVR", maker: "01") do
      screen :bitmap
      high = save_var :high_score, 0
      s = var :s, 0
      game_loop do
        s.set 7
        (s > high).then { high.set s }
      end
    end

    in_a_temp_directory_of_its_own do |dir|
      v = RubyGBA::Verifier.new(rom, frames: 6)
      v.pixel(0, 0) # force the render, which is what opens the emulator

      loose = Dir.children(dir).grep(/\.sav\z/)
      assert_empty loose, "verifying a ROM dropped a save file next to it in the temp directory"
    end
  end

  private

  # Run the block with the temp directory pointed at an empty one, so what a Verifier
  # leaves behind can be read off it directly.
  def in_a_temp_directory_of_its_own
    require "tmpdir"
    Dir.mktmpdir("verify-check") do |dir|
      was = ENV["TMPDIR"]
      ENV["TMPDIR"] = dir
      begin
        yield dir
      ensure
        ENV["TMPDIR"] = was
      end
    end
  end
end
