# frozen_string_literal: true

require "test_helper"

# The 65816 assembler: each instruction in, its bytes out. The expected bytes are copied from the
# 65816's opcode table (WDC's W65C816S datasheet, table 5-4), never worked out the way the
# assembler works them out.
class TestSNESW65816 < Minitest::Test
  W65816 = VBlank::IR::Backends::SNES::W65816
  Linker = VBlank::IR::Backends::SNES::Linker

  private def bytes_of(&block)
    asm = W65816.new("test")
    asm.instance_eval(&block)
    asm.bytes.unpack("C*")
  end

  def test_loads_and_stores_name_their_operand_every_way
    assert_equal [0xA9, 0x34, 0x12], bytes_of { lda 0x1234 }
    assert_equal [0xA5, 0x10], bytes_of { lda direct(0x10) }
    assert_equal [0xAD, 0x00, 0x01], bytes_of { lda abs(0x0100) }
    assert_equal [0xBD, 0x00, 0x01], bytes_of { lda abs_x(0x0100) }
    assert_equal [0xB9, 0x00, 0x01], bytes_of { lda abs_y(0x0100) }
    assert_equal [0xAF, 0x00, 0x20, 0x7E], bytes_of { lda long(0x7E2000) }
    assert_equal [0xBF, 0x00, 0x20, 0x7E], bytes_of { lda long_x(0x7E2000) }
    assert_equal [0xB7, 0x10], bytes_of { lda ind_long_y(0x10) }
    assert_equal [0xA7, 0x10], bytes_of { lda ind_long(0x10) }
    assert_equal [0xB1, 0x10], bytes_of { lda ind_y(0x10) }
    assert_equal [0xB2, 0x10], bytes_of { lda ind(0x10) }
    assert_equal [0xA3, 0x03], bytes_of { lda stack(3) }
    assert_equal [0xB3, 0x03], bytes_of { lda stack_ind_y(3) }
    assert_equal [0x8D, 0x00, 0x21], bytes_of { sta abs(0x2100) }
    assert_equal [0x9F, 0x00, 0x20, 0x7E], bytes_of { sta long_x(0x7E2000) }
    assert_equal [0x85, 0x04], bytes_of { sta direct(4) }
    assert_equal [0x95, 0x04], bytes_of { sta direct_x(4) }
  end

  def test_sums_on_the_accumulator
    assert_equal [0x69, 0x01, 0x00], bytes_of { adc 1 }
    assert_equal [0x65, 0x04], bytes_of { adc direct(4) }
    assert_equal [0xE5, 0x04], bytes_of { sbc direct(4) }
    assert_equal [0x29, 0xFF, 0x00], bytes_of { and_a 0xFF }
    assert_equal [0x05, 0x02], bytes_of { ora direct(2) }
    assert_equal [0x49, 0xFF, 0xFF], bytes_of { eor 0xFFFF }
    assert_equal [0xC9, 0x00, 0x80], bytes_of { cmp 0x8000 }
    assert_equal [0xCD, 0x00, 0x01], bytes_of { cmp abs(0x0100) }
  end

  def test_an_immediate_is_as_wide_as_its_register
    assert_equal [0xE2, 0x20, 0xA9, 0x80, 0xC2, 0x20, 0xA9, 0x80, 0x00],
                 bytes_of { sep 0x20; lda 0x80; rep 0x20; lda 0x80 }
    assert_equal [0xE2, 0x10, 0xA2, 0x05, 0xA9, 0x05, 0x00], bytes_of { sep 0x10; ldx 5; lda 5 }
    assert_equal [0xA0, 0x05, 0x00, 0xE0, 0x05, 0x00, 0xC0, 0x05, 0x00], bytes_of { ldy 5; cpx 5; cpy 5 }
    assert_equal [0xA9, 0x05], bytes_of { widths(a16: false, xy16: true); lda 5 }
  end

  def test_shifts_and_counts
    assert_equal [0x0A], bytes_of { asl }
    assert_equal [0x4A], bytes_of { lsr :a }
    assert_equal [0x26, 0x02], bytes_of { rol direct(2) }
    assert_equal [0x66, 0x02], bytes_of { ror direct(2) }
    assert_equal [0x7E, 0x00, 0x01], bytes_of { ror abs_x(0x100) }
    assert_equal [0x1A, 0xE6, 0x10, 0xEE, 0x00, 0x01, 0x3A, 0xC6, 0x10],
                 bytes_of { inc; inc direct(0x10); inc abs(0x100); dec; dec direct(0x10) }
    assert_equal [0xE8, 0xC8, 0xCA, 0x88], bytes_of { inx; iny; dex; dey }
  end

  def test_the_other_operated_instructions
    assert_equal [0xA6, 0x10, 0xBE, 0x00, 0x01], bytes_of { ldx direct(0x10); ldx abs_y(0x100) }
    assert_equal [0xAC, 0x00, 0x01, 0xB4, 0x10], bytes_of { ldy abs(0x100); ldy direct_x(0x10) }
    assert_equal [0x86, 0x10, 0x8E, 0x00, 0x01, 0x84, 0x10, 0x8C, 0x00, 0x01],
                 bytes_of { stx direct(0x10); stx abs(0x100); sty direct(0x10); sty abs(0x100) }
    assert_equal [0x64, 0x10, 0x9C, 0x00, 0x21, 0x9E, 0x00, 0x01, 0x74, 0x10],
                 bytes_of { stz direct(0x10); stz abs(0x2100); stz abs_x(0x100); stz direct_x(0x10) }
    assert_equal [0x89, 0x01, 0x00, 0x2C, 0x00, 0x01], bytes_of { bit 1; bit abs(0x100) }
    assert_equal [0x04, 0x10, 0x1C, 0x00, 0x01], bytes_of { tsb direct(0x10); trb abs(0x100) }
    assert_equal [0xD4, 0x02, 0xF4, 0x34, 0x12], bytes_of { pei direct(2); pea abs(0x1234) }
  end

  def test_jumps_and_calls
    assert_equal [0x4C, 0x00, 0x90], bytes_of { jmp abs(0x9000) }
    assert_equal [0x7C, 0x00, 0x90], bytes_of { jmp ind_abs_x(0x9000) }
    assert_equal [0x5C, 0x00, 0x80, 0x81], bytes_of { jml long(0x818000) }
    assert_equal [0x22, 0x00, 0x80, 0x81], bytes_of { jsl long(0x818000) }
    assert_equal [0x20, 0x00, 0x90, 0xFC, 0x00, 0x90], bytes_of { jsr abs(0x9000); jsr ind_abs_x(0x9000) }
    assert_equal [0x60, 0x6B, 0x40], bytes_of { rts; rtl; rti }
  end

  def test_the_one_byte_instructions
    assert_equal [0x78, 0x18, 0xFB, 0xD8, 0x38, 0x58], bytes_of { sei; clc; xce; cld; sec; cli }
    assert_equal [0xAA, 0xA8, 0x8A, 0x98, 0xBA, 0x9A, 0x9B, 0xBB, 0x5B, 0x7B, 0x1B, 0x3B, 0xEB],
                 bytes_of { tax; tay; txa; tya; tsx; txs; txy; tyx; tcd; tdc; tcs; tsc; xba }
    assert_equal [0x48, 0x68, 0xDA, 0xFA, 0x5A, 0x7A, 0x08, 0x28, 0x8B, 0xAB, 0x0B, 0x2B, 0x4B],
                 bytes_of { pha; pla; phx; plx; phy; ply; php; plp; phb; plb; phd; pld; phk }
    assert_equal [0xEA, 0xCB, 0xDB], bytes_of { nop; wai; stp }
    assert_equal [0xC2, 0x30, 0xE2, 0x20], bytes_of { rep 0x30; sep 0x20 }
    assert_equal [0x54, 0x7E, 0x80, 0x44, 0x7F, 0x7E], bytes_of { mvn 0x7E, 0x80; mvp 0x7F, 0x7E }
  end

  def test_an_instruction_the_processor_lacks_is_refused
    assert_raises(W65816::Error) { bytes_of { stx abs_x(0x100) } }
    assert_raises(W65816::Error) { bytes_of { sta 5 } }
  end

  # Branches and labels are filled in by the Linker, so they are read from a linked cartridge: the
  # first section goes at $80:8000.
  private def linked(&block)
    asm = W65816.new("test", home: :first)
    asm.instance_eval(&block)
    Linker.new([asm.section]).link
  end

  def test_a_branch_counts_from_the_instruction_after_it
    bank = linked do
      label "top"
      nop
      bne "top"
      beq "ahead"
      nop
      label "ahead"
      bra "top"
    end.banks.first
    assert_equal [0xEA, 0xD0, 0xFD, 0xF0, 0x01, 0xEA, 0x80, 0xF8], bank.bytes.first(8)
  end

  def test_a_long_branch_and_the_addresses_of_labels
    linked_bank = linked do
      brl "end"
      jsl long("end")
      lda long_x("end", 2)
      lda imm("end")
      data_longs "end"
      label "end"
    end
    end_at = 3 + 4 + 4 + 3 + 3
    assert_equal 0x808000 + end_at, linked_bank.address_of("end")
    assert_equal [0x82, end_at - 3, 0x00, 0x22, end_at, 0x80, 0x80, 0xBF, end_at + 2, 0x80, 0x80, 0xA9, end_at, 0x80,
                  end_at, 0x80, 0x80], linked_bank.banks.first.bytes.first(end_at)
  end

  def test_a_conditional_branch_far_away_goes_over_a_long_one
    bank = linked do
      branch_long :beq, "far"
      300.times { nop }
      label "far"
    end.banks.first
    assert_equal [0xD0, 0x03, 0x82, 0x2C, 0x01], bank.bytes.first(5)
  end
end
