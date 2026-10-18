# frozen_string_literal: true

require "test_helper"

# A Game Boy Color cartridge's header is what the console reads before it will start one: the
# logo it compares byte for byte, the flag saying the game is for the Color, the memory bank
# controller and the sizes, and the checksum the start-up program refuses a cartridge without.
class TestGBCROM < Minitest::Test
  GBCROM = RubyGBA::Cartridge::GBCROM
  H = RubyGBA::Console::GBCHardware

  private def banks(count) = Array.new(count) { ("\x00".b * 0x4000) }

  def test_the_header_holds_the_logo_the_title_and_a_checksum_the_console_accepts
    rom = GBCROM.new(banks(2), title: "Pong")

    assert rom.valid_header?
    assert_equal "PONG", rom.title
    assert_equal H::CGB_ONLY, rom.bytes.getbyte(H::CGB_FLAG_AT)
  end

  def test_a_title_past_eleven_letters_is_cut_and_lower_case_letters_are_raised
    assert_equal "PAC MAN AND", GBCROM.new(banks(2), title: "pac-man and friends").title
  end

  def test_a_cartridge_with_no_save_has_an_mbc5_and_no_memory_of_its_own
    rom = GBCROM.new(banks(2), title: "X")

    assert_equal 0x19, rom.bytes.getbyte(H::CARTRIDGE_TYPE_AT)
    assert_equal 0x00, rom.bytes.getbyte(H::RAM_SIZE_AT)
  end

  def test_a_cartridge_that_saves_has_32k_of_battery_backed_memory
    rom = GBCROM.new(banks(2), title: "X", save_bytes: 0x8000)

    assert_equal H::MBC5_RAM_BATTERY, rom.bytes.getbyte(H::CARTRIDGE_TYPE_AT)
    assert_equal 0x03, rom.bytes.getbyte(H::RAM_SIZE_AT)
  end

  def test_the_size_is_a_power_of_two_banks_and_the_header_says_it
    rom = GBCROM.new(banks(5), title: "X")

    assert_equal 8 * 0x4000, rom.size
    assert_equal 2, rom.bytes.getbyte(H::ROM_SIZE_AT) # 32K × 2^2
  end

  def test_the_global_checksum_is_every_other_byte_added
    rom = GBCROM.new(banks(2), title: "X")
    sum = rom.bytes.bytes.sum - rom.bytes.getbyte(H::GLOBAL_CHECKSUM_AT) - rom.bytes.getbyte(H::GLOBAL_CHECKSUM_AT + 1)

    assert_equal sum & 0xFFFF, (rom.bytes.getbyte(H::GLOBAL_CHECKSUM_AT) << 8) | rom.bytes.getbyte(H::GLOBAL_CHECKSUM_AT + 1)
  end

  def test_a_save_memory_of_another_size_is_refused
    assert_raises(ArgumentError) { GBCROM.new(banks(2), title: "X", save_bytes: 0x10000) }
  end
end
