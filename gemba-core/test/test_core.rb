# frozen_string_literal: true

require_relative "test_helper"

# Tests for the native GembaCore::Core surface — the thin libmgba mCore wrapper
# defined in the C extension. These assert the binding itself: dimensions,
# stepping, memory reads, and the module-level helpers/constants. Higher-level
# ergonomics are covered in test_probe.rb.
class TestGembaCoreCore < Minitest::Test
  include GembaCoreTestSupport

  def test_loads_a_gba_rom_and_reports_its_shape
    core = GembaCore::Core.new(red_rom)
    assert_equal 240, core.width
    assert_equal 160, core.height
    assert_equal "GBA", core.platform
  ensure
    core&.destroy
  end

  def test_title_and_maker_round_trip_from_the_header
    core = GembaCore::Core.new(build_rom("HELLO", code: "THEL", maker: "42") do
      screen :bitmap
      clear_screen :blue
      game_loop { wait_vblank }
    end)
    assert_equal "HELLO", core.title
    assert_equal "42", core.maker_code
  ensure
    core&.destroy
  end

  def test_run_frame_produces_a_full_video_buffer
    core = GembaCore::Core.new(red_rom)
    core.run_frame
    px = core.video_buffer
    assert_equal 240 * 160 * 4, px.bytesize, "one XBGR8 word per pixel"
    core.destroy
  end

  def test_bus_reads_see_the_display_control_register
    core = GembaCore::Core.new(red_rom)
    6.times { core.run_frame }
    # DISPCNT at 0x04000000: Mode 3 (0x3) with BG2 enabled (0x400) = 0x403.
    dispcnt = core.bus_read16(0x04000000)
    assert_equal 0x403, dispcnt, "expected Mode 3 + BG2 on, got 0x#{dispcnt.to_s(16)}"

    # The three read widths agree on the low bytes of the same address.
    assert_equal core.bus_read8(0x04000000), dispcnt & 0xFF
    assert_equal dispcnt, core.bus_read32(0x04000000) & 0xFFFF
    core.destroy
  end

  def test_set_keys_accepts_a_bitmask_without_raising
    core = GembaCore::Core.new(red_rom)
    core.set_keys(GembaCore::KEY_RIGHT | GembaCore::KEY_A)
    core.run_frame
    core.set_keys(0)
    core.run_frame
    core.destroy
  end

  def test_destroy_is_final
    core = GembaCore::Core.new(red_rom)
    refute_predicate core, :destroyed?
    core.destroy
    assert_predicate core, :destroyed?
    assert_raises(RuntimeError) { core.run_frame }
  end

  def test_key_constants_are_distinct_bits
    bits = %i[KEY_A KEY_B KEY_SELECT KEY_START KEY_RIGHT KEY_LEFT KEY_UP KEY_DOWN KEY_R KEY_L]
           .map { |k| GembaCore.const_get(k) }
    assert_equal bits.length, bits.uniq.length, "each key is a unique bit"
    assert(bits.all? { |b| (b & (b - 1)).zero? }, "each key is a single set bit")
  end

  def test_button_name_hash_is_frozen_and_complete
    map = GembaCore::GBA_BTN_BITS
    assert_predicate map, :frozen?
    assert_equal GembaCore::KEY_RIGHT, map[:right]
    assert_equal GembaCore::KEY_START, map[:start]
    assert_equal 10, map.size
  end

  def test_xor_delta_and_changed_pixel_count
    a = ["00000000", "FFFFFFFF", "00000000"].pack("H8H8H8")
    b = ["00000000", "00000000", "0000FF00"].pack("H8H8H8")
    delta = GembaCore.xor_delta(a, b)
    # Two of the three 4-byte pixels differ.
    assert_equal 2, GembaCore.count_changed_pixels(delta)
  end

  def test_xor_delta_rejects_mismatched_lengths
    assert_raises(ArgumentError) { GembaCore.xor_delta("abcd", "abc") }
  end

  def test_bios_checksum_helper_and_constants_exist
    assert_kind_of Integer, GembaCore::GBA_BIOS_CHECKSUM
    assert_kind_of Integer, GembaCore::GBA_DS_BIOS_CHECKSUM
    # Checksumming 16 zero bytes is well-defined and non-raising.
    assert_kind_of Integer, GembaCore.gba_bios_checksum("\x00".b * 16)
  end

  # rcheevos is compiled out by default — this documents the strip. If the ext
  # is ever built with GEMBA_CORE_RCHEEVOS, flip this expectation.
  def test_rcheevos_is_absent_by_default
    refute GembaCore.const_defined?(:RARuntime),
           "RARuntime should be compiled out unless GEMBA_CORE_RCHEEVOS is set"
  end
end
