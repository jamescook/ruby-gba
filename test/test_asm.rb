# frozen_string_literal: true

require "test_helper"

class TestASM < Minitest::Test
  A = RubyGBA::ASM

  # Helper: decode a load_immediate sequence back to the value it loads.
  # Simulates ARM execution of MOV/ORR with rotated immediates.
  def decode_load_immediate(bytes)
    instructions = bytes.unpack("V*")
    result = 0

    instructions.each do |inst|
      imm8 = inst & 0xFF
      rot4 = (inst >> 8) & 0xF
      rotated = rotate_right(imm8, rot4 * 2)

      opcode = (inst >> 21) & 0xF
      case opcode
      when 0xD  # MOV
        result = rotated
      when 0xC  # ORR
        result |= rotated
      else
        flunk "unexpected opcode: 0x#{opcode.to_s(16)}"
      end
    end

    result
  end

  def rotate_right(value, amount)
    amount &= 31
    ((value >> amount) | (value << (32 - amount))) & 0xFFFFFFFF
  end

  # Extract fields from a single-instruction encoding
  def unpack(bytes)
    bytes.unpack1("V")
  end

  def rd(inst)  = (inst >> 12) & 0xF
  def rn(inst)  = (inst >> 16) & 0xF
  def rm(inst)  = inst & 0xF
  def cond(inst) = (inst >> 28) & 0xF
  def imm12(inst) = inst & 0xFFF
  def decode_imm(inst)
    rotate_right(inst & 0xFF, ((inst >> 8) & 0xF) * 2)
  end

  # ========================================================================
  # Existing tests (load_immediate, loop_forever, nop)
  # ========================================================================

  def test_load_immediate_zero
    assert_equal 0, decode_load_immediate(A.load_immediate(0, 0))
  end

  def test_load_immediate_small
    assert_equal 0x03, decode_load_immediate(A.load_immediate(0, 0x03))
  end

  def test_load_immediate_0x0403
    assert_equal 0x0403, decode_load_immediate(A.load_immediate(0, 0x0403))
  end

  def test_load_immediate_vram_address
    assert_equal 0x06000000, decode_load_immediate(A.load_immediate(1, 0x06000000))
  end

  def test_load_immediate_io_address
    assert_equal 0x04000000, decode_load_immediate(A.load_immediate(1, 0x04000000))
  end

  def test_load_immediate_arbitrary_address
    addr = 0x06000000 + (80 * 240 + 120) * 2
    assert_equal addr, decode_load_immediate(A.load_immediate(1, addr))
  end

  def test_load_immediate_all_bytes_set
    assert_equal 0xDEADBEEF, decode_load_immediate(A.load_immediate(0, 0xDEADBEEF))
  end

  def test_load_immediate_0xFF
    assert_equal 0xFF, decode_load_immediate(A.load_immediate(0, 0xFF))
  end

  def test_load_immediate_0x100
    assert_equal 0x100, decode_load_immediate(A.load_immediate(0, 0x100))
  end

  def test_load_immediate_uses_different_registers
    rd_val = rd(unpack(A.load_immediate(0, 42)))
    assert_equal 0, rd_val

    rd_val = rd(unpack(A.load_immediate(5, 42)))
    assert_equal 5, rd_val
  end

  def test_loop_forever
    assert_equal 0xEAFFFFFE, unpack(A.loop_forever)
  end

  def test_nop
    assert_equal 0xE1A00000, unpack(A.nop)
  end

  # ========================================================================
  # ADD
  # ========================================================================

  def test_add_imm
    inst = unpack(A.add_imm(0, 1, 5))
    assert_equal 0xE, cond(inst), "should be AL condition"
    assert_equal 0, rd(inst)
    assert_equal 1, rn(inst)
    assert_equal 5, decode_imm(inst)
    # Opcode field for ADD = 0100
    assert_equal 0x4, (inst >> 21) & 0xF
  end

  def test_add_imm_large
    # ADD r3, r3, #0x100
    inst = unpack(A.add_imm(3, 3, 0x100))
    assert_equal 3, rd(inst)
    assert_equal 3, rn(inst)
    assert_equal 0x100, decode_imm(inst)
  end

  def test_add_reg
    inst = unpack(A.add_reg(2, 3, 4))
    assert_equal 2, rd(inst)
    assert_equal 3, rn(inst)
    assert_equal 4, rm(inst)
    assert_equal 0x4, (inst >> 21) & 0xF
  end

  def test_add_imm_unencodable
    assert_raises(ArgumentError) { A.add_imm(0, 0, 0x1FF) }
  end

  # ========================================================================
  # SUB
  # ========================================================================

  def test_sub_imm
    inst = unpack(A.sub_imm(0, 1, 10))
    assert_equal 0, rd(inst)
    assert_equal 1, rn(inst)
    assert_equal 10, decode_imm(inst)
    assert_equal 0x2, (inst >> 21) & 0xF  # SUB opcode
  end

  def test_sub_reg
    inst = unpack(A.sub_reg(5, 6, 7))
    assert_equal 5, rd(inst)
    assert_equal 6, rn(inst)
    assert_equal 7, rm(inst)
    assert_equal 0x2, (inst >> 21) & 0xF
  end

  # ========================================================================
  # CMP
  # ========================================================================

  def test_cmp_imm
    inst = unpack(A.cmp_imm(3, 5))
    assert_equal 3, rn(inst)
    assert_equal 5, decode_imm(inst)
    # CMP sets S bit (bit 20) and uses opcode 1010
    assert_equal 0xA, (inst >> 21) & 0xF
    assert_equal 1, (inst >> 20) & 1, "S bit should be set"
  end

  def test_cmp_reg
    inst = unpack(A.cmp_reg(4, 5))
    assert_equal 4, rn(inst)
    assert_equal 5, rm(inst)
  end

  # ========================================================================
  # AND
  # ========================================================================

  def test_and_imm
    inst = unpack(A.and_imm(0, 1, 0xFF))
    assert_equal 0, rd(inst)
    assert_equal 1, rn(inst)
    assert_equal 0xFF, decode_imm(inst)
    assert_equal 0x0, (inst >> 21) & 0xF  # AND opcode
  end

  def test_and_reg
    inst = unpack(A.and_reg(2, 3, 4))
    assert_equal 2, rd(inst)
    assert_equal 3, rn(inst)
    assert_equal 4, rm(inst)
  end

  # ========================================================================
  # ORR
  # ========================================================================

  def test_orr_imm
    inst = unpack(A.orr_imm(0, 1, 0x80))
    assert_equal 0, rd(inst)
    assert_equal 1, rn(inst)
    assert_equal 0x80, decode_imm(inst)
    assert_equal 0xC, (inst >> 21) & 0xF  # ORR opcode
  end

  def test_orr_reg
    inst = unpack(A.orr_reg(5, 6, 7))
    assert_equal 5, rd(inst)
    assert_equal 6, rn(inst)
    assert_equal 7, rm(inst)
  end

  # ========================================================================
  # MVN, RSB
  # ========================================================================

  def test_mvn_imm
    inst = unpack(A.mvn_imm(0, 0))
    assert_equal 0, rd(inst)
    # MVN opcode = 1111
    assert_equal 0xF, (inst >> 21) & 0xF
    # MVN #0 → r0 = 0xFFFFFFFF
  end

  def test_rsb_imm_negation
    # RSB r0, r1, #0 → r0 = 0 - r1 (negation)
    inst = unpack(A.rsb_imm(0, 1, 0))
    assert_equal 0, rd(inst)
    assert_equal 1, rn(inst)
    assert_equal 0, decode_imm(inst)
    assert_equal 0x3, (inst >> 21) & 0xF  # RSB opcode
  end

  # ========================================================================
  # MUL
  # ========================================================================

  def test_mul
    inst = unpack(A.mul(2, 3, 4))
    assert_equal 2, (inst >> 16) & 0xF  # Rd for MUL is bits 19:16
    assert_equal 3, inst & 0xF           # Rm is bits 3:0
    assert_equal 4, (inst >> 8) & 0xF    # Rs is bits 11:8
    assert_equal 0x9, (inst >> 4) & 0xF  # MUL signature: 1001
  end

  # ========================================================================
  # Shifts
  # ========================================================================

  def test_lsl_imm
    inst = unpack(A.lsl_imm(0, 1, 3))
    assert_equal 0, rd(inst)
    assert_equal 1, rm(inst)
    assert_equal 3, (inst >> 7) & 0x1F  # shift amount
    assert_equal 0, (inst >> 5) & 0x3   # LSL type = 00
  end

  def test_lsl_imm_zero_is_mov
    # LSL #0 is equivalent to MOV rd, rm
    inst = unpack(A.lsl_imm(2, 3, 0))
    assert_equal 2, rd(inst)
    assert_equal 3, rm(inst)
  end

  def test_lsr_imm
    inst = unpack(A.lsr_imm(0, 1, 4))
    assert_equal 0, rd(inst)
    assert_equal 1, rm(inst)
    assert_equal 4, (inst >> 7) & 0x1F
    assert_equal 1, (inst >> 5) & 0x3   # LSR type = 01
  end

  def test_lsr_imm_32
    # LSR #32 is encoded as shift=0 with LSR type
    inst = unpack(A.lsr_imm(0, 0, 32))
    assert_equal 0, (inst >> 7) & 0x1F
    assert_equal 1, (inst >> 5) & 0x3
  end

  def test_asr_imm
    inst = unpack(A.asr_imm(0, 1, 8))
    assert_equal 0, rd(inst)
    assert_equal 1, rm(inst)
    assert_equal 8, (inst >> 7) & 0x1F
    assert_equal 2, (inst >> 5) & 0x3   # ASR type = 10
  end

  def test_shift_bounds
    assert_raises(ArgumentError) { A.lsl_imm(0, 0, 32) }
    assert_raises(ArgumentError) { A.lsl_imm(0, 0, -1) }
    assert_raises(ArgumentError) { A.lsr_imm(0, 0, 0) }
    assert_raises(ArgumentError) { A.lsr_imm(0, 0, 33) }
    assert_raises(ArgumentError) { A.asr_imm(0, 0, 0) }
  end

  # ========================================================================
  # LDR / STR
  # ========================================================================

  def test_ldr
    inst = unpack(A.ldr(3, 5))
    assert_equal 3, rd(inst)
    assert_equal 5, rn(inst)
    # Bit 20 = L (load) = 1
    assert_equal 1, (inst >> 20) & 1
  end

  def test_ldr_offset_positive
    inst = unpack(A.ldr_offset(0, 1, 16))
    assert_equal 0, rd(inst)
    assert_equal 1, rn(inst)
    assert_equal 16, imm12(inst)
    assert_equal 1, (inst >> 23) & 1  # U bit = 1 (add offset)
  end

  def test_ldr_offset_negative
    inst = unpack(A.ldr_offset(0, 1, -8))
    assert_equal 0, rd(inst)
    assert_equal 1, rn(inst)
    assert_equal 8, imm12(inst)
    assert_equal 0, (inst >> 23) & 1  # U bit = 0 (subtract offset)
  end

  def test_str
    inst = unpack(A.str(2, 4))
    assert_equal 2, rd(inst)
    assert_equal 4, rn(inst)
    # Bit 20 = L (load) = 0 for store
    assert_equal 0, (inst >> 20) & 1
  end

  def test_str_offset
    inst = unpack(A.str_offset(0, 1, 12))
    assert_equal 0, rd(inst)
    assert_equal 1, rn(inst)
    assert_equal 12, imm12(inst)
  end

  def test_load_halfword
    inst = unpack(A.load_halfword(3, 5))
    assert_equal 3, rd(inst)
    assert_equal 5, rn(inst)
    # LDRH has bit 20 = 1 (load) and specific halfword encoding
    assert_equal 1, (inst >> 20) & 1
  end

  def test_store_halfword
    inst = unpack(A.store_halfword(2, 4))
    assert_equal 2, rd(inst)
    assert_equal 4, rn(inst)
    assert_equal 0, (inst >> 20) & 1  # store, not load
  end

  # ========================================================================
  # Branches
  # ========================================================================

  def test_branch
    inst = unpack(A.branch(10))
    assert_equal 0xEA, (inst >> 24) & 0xFF  # unconditional branch
    offset = inst & 0x00FFFFFF
    assert_equal 8, offset  # 10 - 2 = 8
  end

  def test_branch_cond_eq
    inst = unpack(A.branch_cond(:eq, 5))
    assert_equal 0x0, cond(inst)  # EQ
    offset = inst & 0x00FFFFFF
    assert_equal 3, offset  # 5 - 2 = 3
  end

  def test_branch_cond_ne
    inst = unpack(A.branch_cond(:ne, 5))
    assert_equal 0x1, cond(inst)
  end

  def test_branch_cond_gt
    inst = unpack(A.branch_cond(:gt, 5))
    assert_equal 0xC, cond(inst)
  end

  def test_branch_cond_lt
    inst = unpack(A.branch_cond(:lt, 5))
    assert_equal 0xB, cond(inst)
  end

  def test_branch_cond_ge
    inst = unpack(A.branch_cond(:ge, 5))
    assert_equal 0xA, cond(inst)
  end

  def test_branch_cond_le
    inst = unpack(A.branch_cond(:le, 5))
    assert_equal 0xD, cond(inst)
  end

  def test_branch_cond_negative_offset
    # Branch backward
    inst = unpack(A.branch_cond(:eq, -3))
    offset = inst & 0x00FFFFFF
    # -3 - 2 = -5, encoded as 24-bit two's complement
    assert_equal 0x00FFFFFB, offset
  end

  def test_branch_link
    inst = unpack(A.branch_link(20))
    assert_equal 0xEB, (inst >> 24) & 0xFF  # BL
    offset = inst & 0x00FFFFFF
    assert_equal 18, offset  # 20 - 2 = 18
  end

  def test_return
    assert_equal 0xE12FFF1E, unpack(A.return)
  end

  # ========================================================================
  # PUSH / POP
  # ========================================================================

  def test_push_single
    inst = unpack(A.push(4))
    assert_equal 0xE92D0000 | (1 << 4), inst
  end

  def test_push_multiple
    inst = unpack(A.push(0, 1, 14))  # r0, r1, lr
    expected_mask = (1 << 0) | (1 << 1) | (1 << 14)
    assert_equal 0xE92D0000 | expected_mask, inst
  end

  def test_pop_single
    inst = unpack(A.pop(4))
    assert_equal 0xE8BD0000 | (1 << 4), inst
  end

  def test_pop_multiple
    inst = unpack(A.pop(0, 1, 15))  # r0, r1, pc
    expected_mask = (1 << 0) | (1 << 1) | (1 << 15)
    assert_equal 0xE8BD0000 | expected_mask, inst
  end

  # ========================================================================
  # MOV register
  # ========================================================================

  def test_mov_reg
    inst = unpack(A.mov_reg(5, 3))
    assert_equal 5, rd(inst)
    assert_equal 3, rm(inst)
    assert_equal 0xD, (inst >> 21) & 0xF  # MOV opcode
  end

  # A predicated register move: the condition rides in the top nibble, so the move
  # only executes when the condition holds (the branchless-clamp primitive).
  def test_mov_reg_cond_carries_the_condition
    inst = unpack(A.mov_reg_cond(:lt, 1, 3))
    assert_equal 1, rd(inst)
    assert_equal 3, rm(inst)
    assert_equal 0xD, (inst >> 21) & 0xF  # MOV opcode
    assert_equal 0xB, (inst >> 28) & 0xF  # LT, not AL (0xE)
  end

  def test_mov_imm_cond_carries_the_condition_and_immediate
    inst = unpack(A.mov_imm_cond(:gt, 1, 127))
    assert_equal 1, rd(inst)
    assert_equal 127, inst & 0xFF         # imm8 (rotation 0)
    assert_equal 1, (inst >> 25) & 0x1    # immediate form
    assert_equal 0xC, (inst >> 28) & 0xF  # GT
  end

  def test_mov_imm_cond_rejects_an_unencodable_immediate
    assert_raises(ArgumentError) { A.mov_imm_cond(:gt, 1, 0x12345) }
  end

  # ========================================================================
  # Condition code resolution
  # ========================================================================

  def test_resolve_cond_symbols
    assert_equal 0x0, A.resolve_cond(:eq)
    assert_equal 0x1, A.resolve_cond(:ne)
    assert_equal 0xA, A.resolve_cond(:ge)
    assert_equal 0xB, A.resolve_cond(:lt)
    assert_equal 0xC, A.resolve_cond(:gt)
    assert_equal 0xD, A.resolve_cond(:le)
    assert_equal 0xE, A.resolve_cond(:al)
  end

  def test_resolve_cond_integer_passthrough
    assert_equal 0x5, A.resolve_cond(0x5)
  end

  def test_resolve_cond_unknown
    assert_raises(ArgumentError) { A.resolve_cond(:bogus) }
  end
end
