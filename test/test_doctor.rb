# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

class TestDoctor < Minitest::Test
  def test_valid_rom_passes
    rom = RubyGBA.build("GOOD", code: "BGOD", maker: "01") do
      display :bitmap
      pixel 120, 80, :red
      halt
    end
    result = RubyGBA::Doctor.check(rom)
    assert result.ok?, "Expected valid ROM to pass, got: #{result.report}"
  end

  def test_empty_rom_warns_no_code
    rom = RubyGBA::ROM.new(title: "EMPTY", code: "BEMP", maker: "01")
    rom.finalize!(doctor: false)
    result = RubyGBA::Doctor.check(rom)
    assert result.ok?, "Empty ROM should not be an error (just a warning)"
    assert result.warnings.any? { |w| w.include?("all zeros") },
           "Expected warning about empty code region"
  end

  def test_bad_fixed_byte_detected
    rom = RubyGBA::ROM.new(title: "BAD", code: "BBAD", maker: "01")
    rom.finalize!(doctor: false)
    rom.buffer.setbyte(0xB2, 0x00)  # corrupt fixed byte
    result = RubyGBA::Doctor.check(rom)
    refute result.ok?
    assert result.errors.any? { |e| e.include?("0x96") }
  end

  def test_bad_checksum_detected
    rom = RubyGBA::ROM.new(title: "BAD", code: "BBAD", maker: "01")
    rom.finalize!(doctor: false)
    rom.buffer.setbyte(0xBD, 0xFF)  # corrupt checksum
    result = RubyGBA::Doctor.check(rom)
    refute result.ok?
    assert result.errors.any? { |e| e.include?("checksum") }
  end

  def test_empty_logo_detected
    rom = RubyGBA::ROM.new(title: "NOLOGO", code: "BNLG", maker: "01")
    rom.finalize!(doctor: false)
    rom.buffer[0x04, 156] = "\x00".b * 156  # wipe the Nintendo logo
    result = RubyGBA::Doctor.check(rom)
    refute result.ok?
    assert result.errors.any? { |e| e.include?("logo") && e.include?("all zeros") },
           "Expected error about empty logo, got: #{result.report}"
  end

  def test_corrupt_logo_detected
    rom = RubyGBA::ROM.new(title: "BADLOGO", code: "BBLG", maker: "01")
    rom.finalize!(doctor: false)
    rom.buffer.setbyte(0x50, rom.buffer.getbyte(0x50) ^ 0xFF)  # flip one logo byte
    result = RubyGBA::Doctor.check(rom)
    refute result.ok?
    assert result.errors.any? { |e| e.include?("logo") },
           "Expected error about corrupt logo, got: #{result.report}"
  end

  def test_missing_entry_branch_detected
    rom = RubyGBA::ROM.new(title: "BAD", code: "BBAD", maker: "01")
    # Don't finalize — no entry branch written
    rom.buffer[0, 4] = [0x00000000].pack("V")
    result = RubyGBA::Doctor.check(rom)
    refute result.ok?
    assert result.errors.any? { |e| e.include?("not an unconditional branch") }
  end

  def test_no_halt_warns
    rom = RubyGBA::ROM.new(title: "NOHALT", code: "BNOH", maker: "01")
    rom.emit(RubyGBA::ASM.nop)
    rom.emit(RubyGBA::ASM.nop)
    rom.finalize!(doctor: false)
    result = RubyGBA::Doctor.check(rom)
    assert result.warnings.any? { |w| w.include?("halt") },
           "Expected warning about missing halt"
  end

  def test_game_loop_rom_is_not_warned_about_missing_halt
    # A game_loop is a deliberate infinite loop that ends in a *backward*
    # branch, not a fall-through — it must not trip the "no halt" warning.
    rom = RubyGBA.build("LOOP", code: "BLPG", maker: "01", doctor: false) do
      display :bitmap
      game_loop do
        wait_vblank
      end
    end
    result = RubyGBA::Doctor.check(rom)
    refute result.warnings.any? { |w| w.include?("halt") },
           "game_loop backward branch should count as a terminator, got: #{result.report}"
  end

  def test_unconditional_backward_branch_is_a_valid_terminator
    rom = RubyGBA::ROM.new(title: "BACK", code: "BBCK", maker: "01")
    rom.emit(RubyGBA::ASM.nop)
    rom.emit(RubyGBA::ASM.branch(-1)) # unconditional branch back to the nop
    rom.finalize!(doctor: false)
    result = RubyGBA::Doctor.check(rom)
    refute result.warnings.any? { |w| w.include?("halt") },
           "an unconditional backward branch loops rather than falling off the end"
  end

  def test_conditional_backward_branch_still_warns
    # A conditional branch can fall through, so on its own it is NOT a
    # terminator — this guards the fix against being too broad.
    rom = RubyGBA::ROM.new(title: "COND", code: "BCND", maker: "01")
    rom.emit(RubyGBA::ASM.nop)
    rom.emit(RubyGBA::ASM.branch_cond(:ne, -1))
    rom.finalize!(doctor: false)
    result = RubyGBA::Doctor.check(rom)
    assert result.warnings.any? { |w| w.include?("halt") },
           "a conditional branch can fall through and must still warn"
  end

  def test_doctor_on_by_default_in_build
    # Valid ROM should build fine with doctor on
    rom = RubyGBA.build("OK", code: "BROK", maker: "01") do
      entry { loop_forever }
    end
    assert_kind_of RubyGBA::ROM, rom
  end

  def test_doctor_can_be_disabled
    rom = RubyGBA.build("OK", code: "BROK", maker: "01", doctor: false) do
      entry { loop_forever }
    end
    assert_kind_of RubyGBA::ROM, rom
  end

  def test_report_format
    rom = RubyGBA.build("GOOD", code: "BGOD", maker: "01") do
      halt
    end
    result = RubyGBA::Doctor.check(rom)
    report = result.report
    assert_includes report, "OK"
  end

  def test_check_file
    require "tempfile"
    rom = RubyGBA.build("FILE", code: "BFIL", maker: "01") do
      display :bitmap
      halt
    end
    Tempfile.create(["test", ".gba"]) do |f|
      rom.write(f.path)
      result = RubyGBA::Doctor.check_file(f.path)
      assert result.ok?, "File check failed: #{result.report}"
    end
  end
end
