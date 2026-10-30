# frozen_string_literal: true

require "test_helper"

# The sound processor's instructions as bytes. Every expected byte is copied from the opcode tables
# in fullsnes ("SNES APU SPC700 CPU Load/Store Commands", "ALU Commands", "Jump/Control Commands"),
# never worked out the way the encoder works it out.
class TestSNESSPC700 < Minitest::Test
  SPC700 = VBlank::IR::Backends::SNES::SPC700

  private def bytes_of(origin: 0x0200, &block)
    spc = SPC700.new(origin: origin)
    spc.instance_eval(&block)
    spc.assembled.unpack("C*")
  end

  def test_moves_between_registers
    assert_equal [0xE8, 0x12, 0xCD, 0x34, 0x8D, 0x56], bytes_of { mov :a, imm(0x12); mov :x, imm(0x34); mov :y, imm(0x56) }
    assert_equal [0x7D, 0x5D, 0xDD, 0xFD, 0x9D, 0xBD], bytes_of { mov :a, :x; mov :x, :a; mov :a, :y; mov :y, :a; mov :x, :sp; mov :sp, :x }
  end

  def test_loads
    assert_equal [0xE4, 0x10, 0xF4, 0x10, 0xE5, 0x34, 0x12, 0xF5, 0x34, 0x12, 0xF6, 0x34, 0x12],
                 bytes_of { mov :a, direct(0x10); mov :a, direct_x(0x10); mov :a, abs(0x1234); mov :a, abs_x(0x1234); mov :a, abs_y(0x1234) }
    assert_equal [0xE6, 0xBF, 0xF7, 0x20, 0xE7, 0x20], bytes_of { mov :a, x_ind; mov :a, x_ind_inc; mov :a, direct_ind_y(0x20); mov :a, direct_x_ind(0x20) }
    assert_equal [0xF8, 0x10, 0xF9, 0x10, 0xE9, 0x34, 0x12], bytes_of { mov :x, direct(0x10); mov :x, direct_y(0x10); mov :x, abs(0x1234) }
    assert_equal [0xEB, 0x10, 0xFB, 0x10, 0xEC, 0x34, 0x12], bytes_of { mov :y, direct(0x10); mov :y, direct_x(0x10); mov :y, abs(0x1234) }
    assert_equal [0xBA, 0x10], bytes_of { movw :ya, direct(0x10) }
  end

  def test_stores_put_a_number_and_a_source_before_the_place
    # MOV aa,#nn is 8F nn aa, and MOV aa,bb is FA bb aa: the second operand's byte comes first.
    assert_equal [0x8F, 0x77, 0xF2, 0xFA, 0x11, 0xF3], bytes_of { mov direct(0xF2), imm(0x77); mov direct(0xF3), direct(0x11) }
    assert_equal [0xC4, 0x10, 0xD8, 0x10, 0xCB, 0x10, 0xD4, 0x10, 0xDB, 0x10, 0xD9, 0x10],
                 bytes_of { mov direct(0x10), :a; mov direct(0x10), :x; mov direct(0x10), :y; mov direct_x(0x10), :a; mov direct_x(0x10), :y; mov direct_y(0x10), :x }
    assert_equal [0xC5, 0x34, 0x12, 0xC9, 0x34, 0x12, 0xCC, 0x34, 0x12, 0xD5, 0x34, 0x12, 0xD6, 0x34, 0x12],
                 bytes_of { mov abs(0x1234), :a; mov abs(0x1234), :x; mov abs(0x1234), :y; mov abs_x(0x1234), :a; mov abs_y(0x1234), :a }
    assert_equal [0xAF, 0xC6, 0xD7, 0x20, 0xC7, 0x20, 0xDA, 0x10],
                 bytes_of { mov x_ind_inc, :a; mov x_ind, :a; mov direct_ind_y(0x20), :a; mov direct_x_ind(0x20), :a; movw direct(0x10), :ya }
  end

  def test_pushes_and_pops
    assert_equal [0x2D, 0x4D, 0x6D, 0x0D, 0xAE, 0xCE, 0xEE, 0x8E], bytes_of { push :a; push :x; push :y; push :psw; pop :a; pop :x; pop :y; pop :psw }
  end

  def test_each_sum_in_each_of_its_forms
    # OR's row: x+08 nn, x+06, x+04 aa, x+14 aa, x+05 aaaa, x+15, x+16, x+17 aa, x+07 aa, x+09 bb aa, x+18 nn aa, x+19.
    assert_equal [0x08, 0x01, 0x06, 0x04, 0x10, 0x14, 0x10, 0x05, 0x34, 0x12, 0x15, 0x34, 0x12, 0x16, 0x34, 0x12,
                  0x17, 0x20, 0x07, 0x20, 0x09, 0x11, 0x10, 0x18, 0x01, 0x10, 0x19],
                 bytes_of {
                   or_ :a, imm(1); or_ :a, x_ind; or_ :a, direct(0x10); or_ :a, direct_x(0x10); or_ :a, abs(0x1234)
                   or_ :a, abs_x(0x1234); or_ :a, abs_y(0x1234); or_ :a, direct_ind_y(0x20); or_ :a, direct_x_ind(0x20)
                   or_ direct(0x10), direct(0x11); or_ direct(0x10), imm(1); or_ x_ind, y_ind
                 }
    assert_equal [0x28, 0x01, 0x48, 0x01, 0x68, 0x01, 0x88, 0x01, 0xA8, 0x01],
                 bytes_of { and_ :a, imm(1); eor :a, imm(1); cmp :a, imm(1); adc :a, imm(1); sbc :a, imm(1) }
    assert_equal [0xB9, 0x89, 0x11, 0x10, 0x98, 0x05, 0x10], bytes_of { sbc x_ind, y_ind; adc direct(0x10), direct(0x11); adc direct(0x10), imm(5) }
  end

  def test_compares_with_x_and_y
    assert_equal [0xC8, 0x05, 0x3E, 0x10, 0x1E, 0x34, 0x12, 0xAD, 0x05, 0x7E, 0x10, 0x5E, 0x34, 0x12],
                 bytes_of { cmp :x, imm(5); cmp :x, direct(0x10); cmp :x, abs(0x1234); cmp :y, imm(5); cmp :y, direct(0x10); cmp :y, abs(0x1234) }
  end

  def test_shifts_and_counts
    assert_equal [0x1C, 0x3C, 0x5C, 0x7C, 0x9C, 0xBC], bytes_of { asl :a; rol :a; lsr :a; ror :a; dec :a; inc :a }
    assert_equal [0x1D, 0x3D, 0xDC, 0xFC], bytes_of { dec :x; inc :x; dec :y; inc :y }
    assert_equal [0x0B, 0x10, 0x1B, 0x10, 0x0C, 0x34, 0x12, 0xAB, 0x10, 0xBB, 0x10, 0xAC, 0x34, 0x12],
                 bytes_of { asl direct(0x10); asl direct_x(0x10); asl abs(0x1234); inc direct(0x10); inc direct_x(0x10); inc abs(0x1234) }
  end

  def test_sixteen_bit_sums_and_the_multiply_and_divide
    assert_equal [0x7A, 0x10, 0x9A, 0x10, 0x5A, 0x10, 0x3A, 0x10, 0x1A, 0x10, 0x9E, 0xCF],
                 bytes_of { addw :ya, direct(0x10); subw :ya, direct(0x10); cmpw :ya, direct(0x10); incw direct(0x10); decw direct(0x10); div :ya, :x; mul :ya }
  end

  def test_single_bits
    # SET1 aa.b is b*20+02, CLR1 aa.b b*20+12; a bit of the first 8K is the address with the bit in its top three bits.
    assert_equal [0x02, 0x10, 0xE2, 0x10, 0x12, 0x10, 0xF2, 0x10], bytes_of { set1 direct_bit(0x10, 0); set1 direct_bit(0x10, 7); clr1 direct_bit(0x10, 0); clr1 direct_bit(0x10, 7) }
    assert_equal [0xEA, 0x34, 0x12, 0xCA, 0x34, 0x52, 0xAA, 0x34, 0xF2],
                 bytes_of { not1 mem_bit(0x1234, 0); mov1 mem_bit(0x1234, 2), :c; mov1 :c, mem_bit(0x1234, 7) }
    assert_equal [0x0A, 0x01, 0x20, 0x2A, 0x01, 0x20, 0x4A, 0x01, 0x20, 0x6A, 0x01, 0x20, 0x8A, 0x01, 0x20],
                 bytes_of {
                   or1 :c, mem_bit(1, 1); or1 :c, not_bit(1, 1); and1 :c, mem_bit(1, 1); and1 :c, not_bit(1, 1)
                   eor1 :c, mem_bit(1, 1)
                 }
    assert_equal [0x4E, 0x34, 0x12, 0x0E, 0x34, 0x12], bytes_of { tclr1 abs(0x1234); tset1 abs(0x1234) }
  end

  def test_the_one_byte_instructions
    assert_equal [0x60, 0x80, 0xED, 0xE0, 0xDF, 0xBE, 0x9F, 0x00, 0xEF, 0xFF, 0x20, 0x40, 0xA0, 0xC0, 0x6F, 0x7F, 0x0F],
                 bytes_of { clrc; setc; notc; clrv; daa :a; das :a; xcn :a; nop; sleep; stop; clrp; setp; ei; di; ret; reti; brk }
  end

  def test_every_branch
    assert_equal [0x10, 0xFE, 0x30, 0xFC, 0x50, 0xFA, 0x70, 0xF8, 0x90, 0xF6, 0xB0, 0xF4, 0xD0, 0xF2, 0xF0, 0xF0],
                 bytes_of { label "top"; bpl "top"; bmi "top"; bvc "top"; bvs "top"; bcc "top"; bcs "top"; bne "top"; beq "top" }
    # BBS aa.b,dest is b*20+03 aa rr; BBC b*20+13; CBNE 2E aa rr and DE aa rr; DBNZ Y FE rr, DBNZ aa 6E aa rr.
    assert_equal [0x03, 0x10, 0xFD, 0xF3, 0x10, 0xFA, 0x2E, 0x10, 0xF7, 0xDE, 0x10, 0xF4, 0xFE, 0xF2, 0x6E, 0x10, 0xEF],
                 bytes_of {
                   label "top"; bbs direct_bit(0x10, 0), "top"; bbc direct_bit(0x10, 7), "top"; cbne direct(0x10), "top"
                   cbne direct_x(0x10), "top"; dbnz :y, "top"; dbnz direct(0x10), "top"
                 }
  end

  def test_jumps_and_calls
    assert_equal [0x1F, 0x34, 0x12, 0x5F, 0x34, 0x12, 0x3F, 0x34, 0x12, 0x01, 0xF1, 0x4F, 0x80],
                 bytes_of { jmp abs_x_ind(0x1234); jmp 0x1234; call 0x1234; tcall 0; tcall 15; pcall 0x80 }
  end

  # An operand of the wrong kind is a mistake in the code that wrote it, never a quietly different
  # instruction.
  def test_an_operand_the_instruction_does_not_take_is_refused
    [-> { jmp abs_x(0x1234) }, -> { call direct(0x10) }, -> { mul :a }, -> { daa :y }, -> { not1 mem_bit("place", 0) },
     -> { data_bytes 256 }, -> { data_words 0x10000 }, -> { mov :a, imm(0x100) }, -> { set1 direct_bit(0x10, 8) }].each do |wrong|
      spc = SPC700.new(origin: 0x0200)
      assert_raises(SPC700::Error) { spc.instance_exec(&wrong) }
    end
  end

  def test_data_is_kept_as_written
    assert_equal [0x01, 0xFF, 0x34, 0x12], bytes_of { data_bytes 1, -1; data_words 0x1234 }
  end

  def test_a_branch_too_far_is_refused
    spc = SPC700.new(origin: 0x0200)
    spc.label "far"
    130.times { spc.nop }
    spc.bra "far"

    assert_raises(SPC700::Error) { spc.assembled }
  end

  def test_a_branch_counts_from_the_byte_after_it
    # BNE back to itself is D0 FE; BRA over one NOP is 2F 01.
    assert_equal [0xD0, 0xFE, 0x2F, 0x01, 0x00], bytes_of { label "spin"; bne "spin"; bra "over"; nop; label "over" }
  end

  def test_a_jump_names_where_the_label_lands_in_sound_memory
    assert_equal [0x00, 0x5F, 0x01, 0x04, 0x3F, 0x01, 0x04], bytes_of(origin: 0x0400) { nop; label "here"; jmp "here"; call "here" }
  end
end
