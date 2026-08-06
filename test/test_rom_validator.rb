# frozen_string_literal: true

require "test_helper"

require "tempfile"

# The ROM-image validator: the structural checks on the finished cartridge bytes
# (header, logo, checksum, entry branch, size, code, title). These only exist
# after lowering, so they run at finalization rather than as IR guardrails (which
# reason about the program before any ROM exists).
class TestROMValidator < Minitest::Test
  ROMValidator = RubyGBA::ROMValidator

  def test_a_valid_rom_passes
    rom = RubyGBA.build("GOOD", code: "BGOD", maker: "01") do
      screen :bitmap
      pixel 120, 80, :red
      halt
    end
    result = ROMValidator.check(rom)
    assert result.ok?, "expected a valid ROM to pass, got: #{result.report}"
  end

  def test_empty_code_region_is_a_warning_not_an_error
    rom = ROM.new(title: "EMPTY", code: "BEMP", maker: "01")
    rom.finalize!(validate: false)
    result = ROMValidator.check(rom)

    assert result.ok?, "no code is a warning, not an error"
    assert(result.warnings.any? { |w| w.include?("all zeros") }, "warns the code region is empty")
  end

  def test_a_bad_fixed_byte_is_an_error
    rom = finalized_rom
    rom.buffer.setbyte(0xB2, 0x00)
    result = ROMValidator.check(rom)

    refute result.ok?
    assert(result.errors.any? { |e| e.include?("0x96") })
  end

  def test_a_bad_checksum_is_an_error
    rom = finalized_rom
    rom.buffer.setbyte(0xBD, 0xFF)
    result = ROMValidator.check(rom)

    refute result.ok?
    assert(result.errors.any? { |e| e.include?("checksum") })
  end

  def test_an_all_zero_logo_is_an_error
    rom = finalized_rom
    rom.buffer[0x04, 156] = "\x00".b * 156
    result = ROMValidator.check(rom)

    refute result.ok?
    assert(result.errors.any? { |e| e.include?("logo") && e.include?("all zeros") }, result.report)
  end

  def test_a_corrupt_logo_is_an_error
    rom = finalized_rom
    rom.buffer.setbyte(0x50, rom.buffer.getbyte(0x50) ^ 0xFF)
    result = ROMValidator.check(rom)

    refute result.ok?
    assert(result.errors.any? { |e| e.include?("logo") }, result.report)
  end

  def test_a_missing_entry_branch_is_an_error
    rom = ROM.new(title: "BAD", code: "BBAD", maker: "01")
    rom.buffer[0, 4] = [0x00000000].pack("V") # never finalized — no entry branch
    result = ROMValidator.check(rom)

    refute result.ok?
    assert(result.errors.any? { |e| e.include?("not an unconditional branch") })
  end

  def test_an_empty_title_is_a_warning
    rom = ROM.new(title: "", code: "BEMP", maker: "01")
    rom.emit(RubyGBA::ASM.loop_forever)
    rom.finalize!(validate: false)
    result = ROMValidator.check(rom)

    assert result.ok?, "an empty title is a warning, not an error"
    assert(result.warnings.any? { |w| w.include?("title") })
  end

  def test_report_says_ok_for_a_clean_rom
    rom = RubyGBA.build("GOOD", code: "BGOD", maker: "01") { halt }
    assert_includes ROMValidator.check(rom).report, "OK"
  end

  def test_check_file_validates_a_gba_on_disk
    rom = RubyGBA.build("FILE", code: "BFIL", maker: "01") do
      screen :bitmap
      halt
    end
    Tempfile.create(["rom_image", ".gba"]) do |f|
      rom.write(f.path)
      result = ROMValidator.check_file(f.path)
      assert result.ok?, "file check failed: #{result.report}"
    end
  end

  # ---- finalize! runs the validation and halts on a structural error --------

  def test_finalize_raises_rom_error_on_a_structural_problem
    # Corrupt the fixed byte before finalizing — finalize! rewrites the entry
    # branch and checksum but not this, so the validation it runs must catch it
    # and refuse the ROM.
    rom = ROM.new(title: "BAD", code: "BBAD", maker: "01")
    rom.emit(RubyGBA::ASM.loop_forever)
    rom.buffer.setbyte(0xB2, 0x00)

    err = assert_raises(RubyGBA::ROMError) { rom.finalize!(validate: true) }
    assert_match(/0x96/, err.message)
  end

  def test_finalize_validation_can_be_disabled
    rom = RubyGBA.build("SKIP", code: "BSKP", maker: "01", validate: false) do
      entry { loop_forever }
    end
    assert_kind_of ROM, rom
  end

  private

  def finalized_rom
    rom = ROM.new(title: "BAD", code: "BBAD", maker: "01")
    rom.finalize!(validate: false)
    rom
  end
end
