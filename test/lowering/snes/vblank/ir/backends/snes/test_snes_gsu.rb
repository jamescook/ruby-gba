# frozen_string_literal: true

require "test_helper"

# The Super FX's instructions as bytes. Every expected byte is copied from the opcode table in
# fullsnes ("SNES Cart GSU-n CPU Opcodes"), never worked out the way the encoder works it out.
class TestSNESGSU < Minitest::Test
  GSU = VBlank::IR::Backends::SNES::GSU

  private def bytes_of(&block)
    gsu = GSU.new("test")
    gsu.instance_eval(&block)
    gsu.section.bytes.unpack("C*")
  end

  def test_the_one_byte_instructions
    # STOP is followed by a NOP: the chip has fetched the byte after it, and runs it first next time.
    assert_equal [0x00, 0x01, 0x01, 0x02, 0x03, 0x04, 0x3C, 0x4C, 0x4D, 0x4E, 0x4F, 0x70, 0x90, 0x95, 0x96, 0x97, 0x9E,
                  0x9F, 0xC0, 0xDF, 0xEF],
                 bytes_of { stop; nop; cache; lsr; rol; loop; plot; swap; color; not_; merge; sbk; sex; asr; ror; lob; fmult; hib; getc; getb }
  end

  def test_the_prefixed_instructions
    assert_equal [0x3D, 0x4C, 0x3D, 0x4E, 0x3D, 0x96, 0x3D, 0x9F, 0x3E, 0xDF, 0x3F, 0xDF, 0x3D, 0xEF, 0x3E, 0xEF,
                  0x3F, 0xEF],
                 bytes_of { rpix; cmode; div2; lmult; ramb; romb; getbh; getbl; getbs }
  end

  def test_from_to_and_with_name_registers
    assert_equal [0xB3, 0x1C, 0x25], bytes_of { from 3; to 12; with 5 }
    # MOVE R4,R7 is WITH R7 then TO R4; MOVES R4,R7 is WITH R4 then FROM R7.
    assert_equal [0x27, 0x14, 0x24, 0xB7], bytes_of { move 4, 7; moves 4, 7 }
  end

  def test_the_sums_in_their_four_forms
    assert_equal [0x53, 0x3D, 0x53, 0x3E, 0x53, 0x3F, 0x53], bytes_of { add 3; adc 3; add imm(3); adc imm(3) }
    assert_equal [0x62, 0x3D, 0x62, 0x3E, 0x62, 0x3F, 0x62], bytes_of { sub 2; sbc 2; sub imm(2); cmp 2 }
    assert_equal [0x71, 0x3D, 0x71, 0x3E, 0x7F, 0x3F, 0x7F], bytes_of { and_ 1; bic 1; and_ imm(15); bic imm(15) }
    assert_equal [0x86, 0x3D, 0x86, 0x3E, 0x86, 0x3F, 0x86], bytes_of { mult 6; umult 6; mult imm(6); umult imm(6) }
    assert_equal [0xC9, 0x3D, 0xC9, 0x3E, 0xC9, 0x3F, 0xC9], bytes_of { or_ 9; xor 9; or_ imm(9); xor imm(9) }
  end

  def test_loads_stores_and_counting
    assert_equal [0x31, 0x3D, 0x31, 0x4B, 0x3D, 0x4B], bytes_of { stw 1; stb 1; ldw 11; ldb 11 }
    assert_equal [0xD0, 0xDE, 0xE0, 0xEE], bytes_of { inc 0; inc 14; dec 0; dec 14 }
  end

  def test_numbers_and_ram_addresses
    assert_equal [0xA0, 0x5A, 0xA3, 0xFF], bytes_of { ibt 0, 0x5A; ibt 3, -1 }
    assert_equal [0xF1, 0x34, 0x12], bytes_of { iwt 1, 0x1234 }
    assert_equal [0x3D, 0xF2, 0x00, 0x20, 0x3E, 0xF2, 0x00, 0x20], bytes_of { lm 2, 0x2000; sm 0x2000, 2 }
    # LMS and SMS take the address halved: $0104 is $82.
    assert_equal [0x3D, 0xA2, 0x82, 0x3E, 0xA2, 0x82], bytes_of { lms 2, 0x0104; sms 0x0104, 2 }
  end

  def test_jumps_and_links
    assert_equal [0x91, 0x94, 0x98, 0x9D, 0x3D, 0x9B], bytes_of { link 1; link 4; jmp 8; jmp 13; ljmp 11 }
  end

  def test_a_branch_counts_from_the_byte_after_it
    gsu = GSU.new("branches")
    gsu.instance_eval do
      label "top"
      nop
      bne "top"
      nop
    end
    linked = VBlank::IR::Backends::SNES::Linker.new([gsu.section]).link
    assert_equal [0x01, 0x08, 0xFD, 0x01], linked.bytes[0, 4].unpack("C*"), "BNE back three bytes"
    assert_equal [0x05, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F],
                 bytes_of { label "x"; bra "x"; bpl "x"; bmi "x"; bcc "x"; bcs "x"; bvc "x"; bvs "x" }.each_slice(2).map(&:first)
  end

  def test_what_the_gsu_does_not_have_is_refused
    assert_raises(GSU::Error) { bytes_of { stw 12 } }
    assert_raises(GSU::Error) { bytes_of { jmp 7 } }
    assert_raises(GSU::Error) { bytes_of { inc 15 } }
    assert_raises(GSU::Error) { bytes_of { and_ 0 } }
    assert_raises(GSU::Error) { bytes_of { sbc imm(1) } }
    assert_raises(GSU::Error) { bytes_of { and_ imm(0) } }
    assert_raises(GSU::Error) { bytes_of { xor imm(0) } }
    assert_raises(GSU::Error) { bytes_of { ibt 0, 200 } }
  end
end
