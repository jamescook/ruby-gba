# frozen_string_literal: true

require "test_helper"

# The Super Nintendo cartridge's header and checksum, checked against the layout every cartridge
# of the console carries (fullsnes, "SNES Cartridge ROM Header"): the header at $FFC0 of the first
# bank — offset $7FC0 of a LoROM file — and the vectors after it.
class TestSNESROM < Minitest::Test
  SNESROM = VBlank::Cartridge::SNESROM

  private def rom(size: 100, **options)
    SNESROM.new(["\xEA".b * size], title: "Pong", vectors: { reset: 0x8000, nmi: 0x8010 }, **options)
  end

  private def word_at(bytes, at) = bytes.byteslice(at, 2).unpack1("v")

  def test_the_header_says_a_fast_lorom_cartridge_for_north_america
    bytes = rom.bytes
    assert_equal "PONG".ljust(21, " "), bytes.byteslice(0x7FC0, 21)
    assert_equal 0x30, bytes.getbyte(0x7FD5), "map mode: LoROM, fast"
    assert_equal 0x00, bytes.getbyte(0x7FD6), "cartridge type: ROM alone"
    assert_equal 0x05, bytes.getbyte(0x7FD7), "32K is 2^5 kilobytes"
    assert_equal 0x00, bytes.getbyte(0x7FD8), "no RAM"
    assert_equal 0x01, bytes.getbyte(0x7FD9), "North America"
  end

  def test_a_save_has_battery_backed_ram
    bytes = rom(save_bytes: 0x2000).bytes
    assert_equal 0x02, bytes.getbyte(0x7FD6), "ROM, RAM and battery"
    assert_equal 0x03, bytes.getbyte(0x7FD8), "8K is 2^3 kilobytes"
  end

  def test_the_vectors_point_where_they_were_told
    bytes = rom.bytes
    assert_equal 0x8000, word_at(bytes, 0x7FFC), "reset"
    assert_equal 0x8010, word_at(bytes, 0x7FEA), "the native vertical blank interrupt"
  end

  def test_the_checksum_is_every_byte_added_and_its_complement_beside_it
    bytes = rom.bytes
    checksum = word_at(bytes, 0x7FDE)
    complement = word_at(bytes, 0x7FDC)
    assert_equal 0xFFFF, checksum ^ complement
    assert_equal checksum, bytes.sum(16)
  end

  def test_a_cartridge_is_a_power_of_two_in_size
    assert_equal 0x8000, rom.size
    big = SNESROM.new(["\xEA".b * 0x8000] * 3, title: "BIG", vectors: { reset: 0x8000 })
    assert_equal 0x20000, big.size
    assert_equal 0x07, big.bytes.getbyte(0x7FD7), "128K is 2^7 kilobytes"
  end

  def test_a_cartridge_says_whose_it_is
    assert_equal :snes, rom.console
    assert SNESROM.header?(rom.bytes)
    refute SNESROM.header?("\0".b * 0x8000)
    assert_equal "Pong".upcase, rom.title
  end
end
