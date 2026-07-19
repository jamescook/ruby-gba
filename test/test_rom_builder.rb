# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/ruby_gba"

class TestRomBuilder < Minitest::Test
  def test_build_produces_valid_header
    rom = RubyGBA.build("TEEKTEST", code: "BTKE", maker: "01") do
      entry { loop_forever }
    end

    buf = rom.buffer

    # Entry point: branch to 0xC0 (header ends at 0xC0, code starts there)
    # Branch offset: (0xC0 - 8) / 4 = 0x2E
    assert_equal [0xEA00002E].pack("V"), buf[0, 4], "entry branch"

    # Code at 0xC0: branch to self (infinite loop)
    assert_equal [0xEAFFFFFE].pack("V"), buf[0xC0, 4], "loop_forever"

    # Title
    assert_equal "TEEKTEST\x00\x00\x00\x00", buf[0xA0, 12], "title"

    # Game code
    assert_equal "BTKE", buf[0xAC, 4], "game code"

    # Maker code
    assert_equal "01", buf[0xB0, 2], "maker code"

    # Fixed byte
    assert_equal 0x96, buf.getbyte(0xB2), "fixed byte"

    # Complement checksum
    sum = (0xA0..0xBC).sum { |i| buf.getbyte(i) }
    expected = (-(sum + 0x19)) & 0xFF
    assert_equal expected, buf.getbyte(0xBD), "checksum"
  end

  def test_build_embeds_nintendo_logo
    require "digest"
    rom = RubyGBA.build("LOGOTEST", code: "BLGO", maker: "01") do
      entry { loop_forever }
    end

    logo = rom.buffer[0x04, 156]
    refute logo.bytes.all?(&:zero?), "logo region (0x04..0x9F) must not be all zeros"

    # Pinned against the canonical Nintendo logo hash — a single wrong byte
    # fails the GBA BIOS boot check on real hardware. This is deliberately
    # independent of Constants::HEADER_LOGO_BYTES so it catches a bad constant.
    assert_equal "17daa0fec02fc33c0f6abb549a8b80b6613b48ee",
                 Digest::SHA1.hexdigest(logo), "logo must match the canonical Nintendo logo"

    # Logo must fill exactly 0x04..0x9F and not spill into the title at 0xA0.
    assert_equal "LOGOTEST\x00\x00\x00\x00", rom.buffer[0xA0, 12], "title intact after logo"
  end

  def test_write_creates_file
    rom = RubyGBA.build("WRITETEST", code: "BWTE", maker: "99") do
      entry { loop_forever }
    end

    Tempfile.create(["test", ".gba"]) do |f|
      rom.write(f.path)
      written = File.binread(f.path)
      assert_equal rom.buffer, written
      assert_operator written.bytesize, :>=, 512
    end
  end

  def test_title_truncated_to_12_chars
    rom = RubyGBA.build("LONGERTHANTWELVE", code: "BXXX", maker: "01") do
      entry { loop_forever }
    end

    assert_equal "LONGERTHANTW", rom.buffer[0xA0, 12]
  end

  def test_invalid_game_code_raises
    assert_raises(ArgumentError) do
      RubyGBA.build("TEST", code: "AB", maker: "01") { entry { loop_forever } }
    end
  end

  def test_invalid_maker_code_raises
    assert_raises(ArgumentError) do
      RubyGBA.build("TEST", code: "ABCD", maker: "X") { entry { loop_forever } }
    end
  end

  def test_nop_emits_correctly
    rom = RubyGBA.build("NOPTEST", code: "BNOP", maker: "01") do
      entry do
        nop
        loop_forever
      end
    end

    buf = rom.buffer
    assert_equal [0xE1A00000].pack("V"), buf[0xC0, 4], "nop at entry"
    assert_equal [0xEAFFFFFE].pack("V"), buf[0xC4, 4], "loop after nop"
  end

  def test_header_intact_after_code_emission
    # Verify that emitted code doesn't overwrite the header region (0x00-0xBF)
    rom = RubyGBA.build("TEEKTEST", code: "BTKE", maker: "01") do
      entry { loop_forever }
    end

    buf = rom.buffer
    assert_equal "TEEKTEST\x00\x00\x00\x00", buf[0xA0, 12], "title preserved"
    assert_equal "BTKE", buf[0xAC, 4], "game code preserved"
    assert_equal "01", buf[0xB0, 2], "maker code preserved"
    assert_equal 0x96, buf.getbyte(0xB2), "fixed byte preserved"
  end

  # ---- power-of-two padding (real GBA carts are power-of-two sized) ----

  def power_of_two?(number)
    number.positive? && (number & (number - 1)).zero?
  end

  def test_finalize_pads_the_rom_up_to_a_power_of_two
    rom = RubyGBA::ROM.new(title: "PAD", code: "TEST", maker: "01")
    rom.emit("\xAB".b * 5000)
    rom.finalize!(doctor: false)
    assert power_of_two?(rom.size), "ROM size #{rom.size} should be a power of two"
  end

  def test_finalize_pads_to_the_smallest_fitting_power_of_two
    rom = RubyGBA::ROM.new(title: "PAD", code: "TEST", maker: "01")
    rom.emit("\xAB".b * 5000)
    before = rom.size
    rom.finalize!(doctor: false)
    assert_operator rom.size, :>=, before
    assert_operator rom.size / 2, :<, before, "halving the size would no longer fit the code"
  end

  def test_padding_preserves_the_code_and_zero_fills_the_rest
    rom = RubyGBA::ROM.new(title: "PAD", code: "TEST", maker: "01")
    start = rom.code_offset
    payload = "\xAB\xCD".b * 100
    rom.emit(payload)
    rom.finalize!(doctor: false)

    assert_equal payload, rom.buffer[start, payload.bytesize], "emitted code untouched by padding"
    tail = rom.buffer[(start + payload.bytesize)..]
    assert tail.bytes.all?(&:zero?), "everything past the code is zero padding"
  end
end
