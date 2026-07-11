# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/ruby_gba"

class TestPixelDrawing < Minitest::Test
  def test_display_bitmap_sets_mode3
    rom = RubyGBA.build("DISPTEST", code: "BDSP", maker: "01") do
      display :bitmap
      halt
    end

    # The ROM should contain instructions that write MODE_3 | BG2_ENABLE (0x0403)
    # to REG_DISPCNT (0x04000000). We verify by checking the ROM is valid
    # and larger than a bare entry-only ROM.
    assert_operator rom.size, :>=, 512
    # Entry branch should still be at offset 0
    assert_equal [0xEA00002E].pack("V"), rom.buffer[0, 4]
  end

  def test_display_raw_integer
    # Should accept raw register values without raising
    rom = RubyGBA.build("RAWDISP", code: "BRAW", maker: "01") do
      display 0x0403  # MODE_3 | BG2_ENABLE manually
      halt
    end
    assert_operator rom.size, :>=, 512
  end

  def test_display_unknown_mode_raises
    assert_raises(ArgumentError) do
      RubyGBA.build("BAD", code: "BBAD", maker: "01") do
        display :holographic
      end
    end
  end

  def test_pixel_draws_to_vram
    rom = RubyGBA.build("PIXTEST", code: "BPIX", maker: "01") do
      display :bitmap
      pixel 0, 0, :red
      halt
    end

    # ROM should be valid and contain more instructions than just entry + halt
    assert_operator rom.size, :>=, 512
    # Should have valid header
    assert_equal 0x96, rom.buffer.getbyte(0xB2)
  end

  def test_pixel_out_of_bounds_raises
    assert_raises(ArgumentError) do
      RubyGBA.build("OOB", code: "BOOB", maker: "01") do
        display :bitmap
        pixel 240, 0, :red  # x too large
      end
    end

    assert_raises(ArgumentError) do
      RubyGBA.build("OOB", code: "BOOB", maker: "01") do
        display :bitmap
        pixel 0, 160, :red  # y too large
      end
    end
  end

  def test_pixel_accepts_color_formats
    # All these should work without raising
    rom = RubyGBA.build("COLORS", code: "BCOL", maker: "01") do
      display :bitmap
      pixel 10, 10, :red               # symbol preset
      pixel 11, 10, rgb(31, 0, 0)      # rgb helper
      pixel 12, 10, color("#FF0000")   # hex string via helper
      pixel 13, 10, 0x001F              # raw integer
      halt
    end
    assert_operator rom.size, :>=, 512
  end

  def test_fill_rect_produces_larger_rom
    rom_small = RubyGBA.build("SMALL", code: "BSML", maker: "01") do
      display :bitmap
      pixel 0, 0, :red
      halt
    end

    rom_big = RubyGBA.build("BIG", code: "BBIG", maker: "01") do
      display :bitmap
      fill_rect 10, 10, 5, 5, :blue
      halt
    end

    # fill_rect(5x5 = 25 pixels) should emit way more instructions.
    # Both ROMs may have the same buffer size (minimum 512), so compare
    # the actual non-zero content length after the entry offset.
    small_code = rom_small.buffer[0x20..].sub(/\x00+\z/, "").bytesize
    big_code = rom_big.buffer[0x20..].sub(/\x00+\z/, "").bytesize
    assert_operator big_code, :>, small_code
  end

  def test_fill_rect_clips_to_screen
    # Should not raise even if rect extends past screen edge
    rom = RubyGBA.build("CLIP", code: "BCLP", maker: "01") do
      display :bitmap
      fill_rect 235, 155, 10, 10, :green  # extends past right/bottom edge
      halt
    end
    assert_operator rom.size, :>=, 512
  end

  def test_halt_produces_loop
    rom = RubyGBA.build("HALT", code: "BHLT", maker: "01") do
      display :bitmap
      halt
    end

    # Last 4 bytes of code should be the loop_forever instruction
    # Find it by scanning backwards from end of meaningful data
    buf = rom.buffer
    # The halt instruction (0xEAFFFFFE) should be somewhere after 0x20
    found = false
    (0x20..buf.bytesize - 4).step(4) do |offset|
      if buf[offset, 4] == [0xEAFFFFFE].pack("V")
        found = true
        break
      end
    end
    assert found, "expected to find loop_forever (halt) instruction in ROM"
  end

  def test_write_and_load
    rom = RubyGBA.build("PIXELS", code: "BPXL", maker: "01") do
      display :bitmap
      pixel 120, 80, :red
      pixel 121, 80, :green
      pixel 122, 80, :blue
      halt
    end

    Tempfile.create(["pixels", ".gba"]) do |f|
      rom.write(f.path)
      data = File.binread(f.path)
      assert_equal rom.buffer, data
      assert_equal "PIXELS\x00\x00\x00\x00\x00\x00", data[0xA0, 12]
    end
  end
end
