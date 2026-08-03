# frozen_string_literal: true

module RubyGBA
  # Encodes ARM (ARMv4T) instructions as raw 32-bit little-endian bytes.
  #
  # Only a small subset is implemented — enough for the DSL to generate
  # working code. Each method returns a binary String of one or more
  # 4-byte ARM instructions.
  #
  # ARM encoding reference: https://developer.arm.com/documentation/ddi0210/c
  module ASM
    module_function

    # --- Condition codes ---
    # Used by conditional branches and (eventually) conditional execution.
    COND_EQ = 0x0  # equal (Z=1)
    COND_NE = 0x1  # not equal (Z=0)
    COND_GE = 0xA  # signed greater or equal (N=V)
    COND_LT = 0xB  # signed less than (N!=V)
    COND_GT = 0xC  # signed greater than (Z=0, N=V)
    COND_LE = 0xD  # signed less or equal (Z=1 or N!=V)
    COND_AL = 0xE  # always (unconditional)

    COND_BY_NAME = {
      eq: COND_EQ, ne: COND_NE,
      ge: COND_GE, lt: COND_LT,
      gt: COND_GT, le: COND_LE,
      al: COND_AL,
    }.freeze

    # --- Basic instructions (already existed) ---

    # Branch to self — infinite loop. Used as a simple halt.
    def loop_forever
      [0xEAFFFFFE].pack("V")
    end

    # No-op (mov r0, r0).
    def nop
      [0xE1A00000].pack("V")
    end

    # Unconditional branch to a word offset relative to current PC.
    # offset is in words (not bytes). CPU adds 2 due to pipeline.
    def branch(word_offset)
      encoded = 0xEA000000 | ((word_offset - 2) & 0x00FFFFFF)
      [encoded].pack("V")
    end

    # Conditional branch. Same as branch but only taken when condition is met.
    # @param cond [Symbol, Integer] condition code (:eq, :ne, :gt, :lt, :ge, :le)
    # @param word_offset [Integer] target in words relative to current PC
    def branch_cond(cond, word_offset)
      cc = resolve_cond(cond)
      encoded = (cc << 28) | 0x0A000000 | ((word_offset - 2) & 0x00FFFFFF)
      [encoded].pack("V")
    end

    # Branch with link — subroutine call. Saves return address in LR (r14).
    # @param word_offset [Integer] target in words relative to current PC
    def branch_link(word_offset)
      encoded = 0xEB000000 | ((word_offset - 2) & 0x00FFFFFF)
      [encoded].pack("V")
    end

    # Return from subroutine: BX LR (branch to address in r14).
    def return
      # BX LR = 0xE12FFF1E
      [0xE12FFF1E].pack("V")
    end

    # --- Data processing: immediate ---

    # Load a 32-bit immediate into a register using MOV + ORR sequence.
    # ARM immediates are limited to 8 bits rotated, so arbitrary 32-bit
    # values need multiple instructions.
    #
    # Emits 1-4 instructions depending on the value.
    # @param reg [Integer] register number (0-15)
    # @param value [Integer] 32-bit value to load
    # @return [String] encoded ARM instructions
    def load_immediate(reg, value)
      value &= 0xFFFFFFFF
      instructions = []

      # Try to encode as a single MOV with rotated immediate
      if (encoding = encode_rotated_immediate(value))
        # MOV reg, #imm
        instructions << (0xE3A00000 | (reg << 12) | encoding)
        return instructions.pack("V*")
      end

      # Build up the value byte-by-byte using MOV + ORR.
      # ARM rotated immediate: imm8 ROR (2 * rot4).
      # To place a byte at bit position i*8, we need:
      #   rot4 = (16 - i*4) & 0xF
      # because imm8 ROR (32 - i*8) = imm8 << (i*8).
      first = true
      4.times do |i|
        byte = (value >> (i * 8)) & 0xFF
        next if byte == 0 && !first

        rotation = (16 - i * 4) & 0xF
        imm12 = (rotation << 8) | byte

        if first
          # MOV reg, #(byte rotated)
          instructions << (0xE3A00000 | (reg << 12) | imm12)
          first = false
        else
          # ORR reg, reg, #(byte rotated)
          instructions << (0xE3800000 | (reg << 16) | (reg << 12) | imm12)
        end
      end

      # Edge case: value is 0
      if instructions.empty?
        instructions << (0xE3A00000 | (reg << 12))  # MOV reg, #0
      end

      instructions.pack("V*")
    end

    # Build a full 32-bit value into reg with a FIXED four-instruction sequence
    # (MOV + three ORRs, no zero-byte skipping), so the encoding is always 16
    # bytes whatever the value. That fixed size is what lets a two-pass fixup
    # reserve the slot up front and patch in the value — e.g. a resolved data
    # address — later, without shifting everything after it.
    def load_immediate_fixed(reg, value)
      value &= 0xFFFFFFFF
      words = []
      4.times do |i|
        byte = (value >> (i * 8)) & 0xFF
        rotation = (16 - i * 4) & 0xF
        imm12 = (rotation << 8) | byte
        words << if i.zero?
                   0xE3A00000 | (reg << 12) | imm12               # MOV reg, #byte0
                 else
                   0xE3800000 | (reg << 16) | (reg << 12) | imm12 # ORR reg, reg, #byteN
                 end
      end
      words.pack("V*")
    end

    # ADD rd, rn, #imm (immediate, must fit in rotated 8-bit)
    # @param rd [Integer] destination register
    # @param rn [Integer] source register
    # @param imm [Integer] immediate value
    def add_imm(rd, rn, imm)
      encoding = encode_rotated_immediate(imm)
      raise ArgumentError, "immediate #{imm} cannot be encoded as rotated 8-bit" unless encoding
      [0xE2800000 | (rn << 16) | (rd << 12) | encoding].pack("V")
    end

    # ADD rd, rn, rm (register)
    def add_reg(rd, rn, rm)
      [0xE0800000 | (rn << 16) | (rd << 12) | rm].pack("V")
    end

    # SUB rd, rn, #imm (immediate)
    def sub_imm(rd, rn, imm)
      encoding = encode_rotated_immediate(imm)
      raise ArgumentError, "immediate #{imm} cannot be encoded as rotated 8-bit" unless encoding
      [0xE2400000 | (rn << 16) | (rd << 12) | encoding].pack("V")
    end

    # SUB rd, rn, rm (register)
    def sub_reg(rd, rn, rm)
      [0xE0400000 | (rn << 16) | (rd << 12) | rm].pack("V")
    end

    # CMP rn, #imm — compare register against immediate, sets flags.
    def cmp_imm(rn, imm)
      encoding = encode_rotated_immediate(imm)
      raise ArgumentError, "immediate #{imm} cannot be encoded as rotated 8-bit" unless encoding
      # CMP = SUBS with rd=0 (result discarded), S bit set
      [0xE3500000 | (rn << 16) | encoding].pack("V")
    end

    # CMP rn, rm — compare two registers, sets flags.
    def cmp_reg(rn, rm)
      [0xE1500000 | (rn << 16) | rm].pack("V")
    end

    # AND rd, rn, #imm
    def and_imm(rd, rn, imm)
      encoding = encode_rotated_immediate(imm)
      raise ArgumentError, "immediate #{imm} cannot be encoded as rotated 8-bit" unless encoding
      [0xE2000000 | (rn << 16) | (rd << 12) | encoding].pack("V")
    end

    # AND rd, rn, rm
    def and_reg(rd, rn, rm)
      [0xE0000000 | (rn << 16) | (rd << 12) | rm].pack("V")
    end

    # ORR rd, rn, #imm (already used internally, now public)
    def orr_imm(rd, rn, imm)
      encoding = encode_rotated_immediate(imm)
      raise ArgumentError, "immediate #{imm} cannot be encoded as rotated 8-bit" unless encoding
      [0xE3800000 | (rn << 16) | (rd << 12) | encoding].pack("V")
    end

    # ORR rd, rn, rm
    def orr_reg(rd, rn, rm)
      [0xE1800000 | (rn << 16) | (rd << 12) | rm].pack("V")
    end

    # EOR rd, rn, rm — exclusive OR
    def eor_reg(rd, rn, rm)
      [0xE0200000 | (rn << 16) | (rd << 12) | rm].pack("V")
    end

    # TST rn, #imm — test bits (AND but discard result, only sets flags)
    def tst_imm(rn, imm)
      encoding = encode_rotated_immediate(imm)
      raise ArgumentError, "immediate #{imm} cannot be encoded as rotated 8-bit" unless encoding
      # TST = ANDS with rd=0 (result discarded), S bit set
      [0xE3100000 | (rn << 16) | encoding].pack("V")
    end

    # MVN rd, rm — move NOT register (bitwise complement)
    def mvn_reg(rd, rm)
      [0xE1E00000 | (rd << 12) | rm].pack("V")
    end

    # MVN rd, #imm — move NOT (bitwise complement of immediate)
    def mvn_imm(rd, imm)
      encoding = encode_rotated_immediate(imm)
      raise ArgumentError, "immediate #{imm} cannot be encoded as rotated 8-bit" unless encoding
      [0xE3E00000 | (rd << 12) | encoding].pack("V")
    end

    # RSB rd, rn, #imm — reverse subtract (imm - rn). Useful for negation: RSB rd, rn, #0
    def rsb_imm(rd, rn, imm)
      encoding = encode_rotated_immediate(imm)
      raise ArgumentError, "immediate #{imm} cannot be encoded as rotated 8-bit" unless encoding
      [0xE2600000 | (rn << 16) | (rd << 12) | encoding].pack("V")
    end

    # --- Multiply ---

    # MUL rd, rm, rs — rd = rm * rs (low 32 bits)
    # Note: ARM7TDMI restriction: rd must not be the same as rm.
    def mul(rd, rm, rs)
      # MUL encoding: cond=AL, 0000000S, Rd, 0000, Rs, 1001, Rm
      [0xE0000090 | (rd << 16) | (rs << 8) | rm].pack("V")
    end

    # --- Shifts (encoded as MOV with shifted register) ---

    # LSL rd, rm, #shift — logical shift left by immediate
    def lsl_imm(rd, rm, shift)
      raise ArgumentError, "shift must be 0-31" unless (0..31).cover?(shift)
      # MOV rd, rm, LSL #shift
      [0xE1A00000 | (rd << 12) | (shift << 7) | rm].pack("V")
    end

    # LSR rd, rm, #shift — logical shift right by immediate
    def lsr_imm(rd, rm, shift)
      raise ArgumentError, "shift must be 1-32" unless (1..32).cover?(shift)
      shift_val = shift == 32 ? 0 : shift  # ARM encodes 32 as 0
      [0xE1A00000 | (rd << 12) | (shift_val << 7) | 0x20 | rm].pack("V")
    end

    # ASR rd, rm, #shift — arithmetic shift right (sign-extending)
    def asr_imm(rd, rm, shift)
      raise ArgumentError, "shift must be 1-32" unless (1..32).cover?(shift)
      shift_val = shift == 32 ? 0 : shift
      [0xE1A00000 | (rd << 12) | (shift_val << 7) | 0x40 | rm].pack("V")
    end

    # --- Memory access ---

    # LDR rd, [rn] — load 32-bit word from address in rn
    def ldr(rd, rn)
      # LDR rd, [rn, #0]  — P=1, U=1, W=0, offset=0
      [0xE5900000 | (rn << 16) | (rd << 12)].pack("V")
    end

    # LDR rd, [rn, #offset] — load with immediate offset
    def ldr_offset(rd, rn, offset)
      if offset >= 0
        [0xE5900000 | (rn << 16) | (rd << 12) | (offset & 0xFFF)].pack("V")
      else
        # U=0 for negative offset
        [0xE5100000 | (rn << 16) | (rd << 12) | ((-offset) & 0xFFF)].pack("V")
      end
    end

    # LDRB rd, [rn, #offset] — load an unsigned byte (0..255) with immediate
    # offset. The B (bit 22) is what makes it a byte load instead of a word.
    def ldrb_offset(rd, rn, offset)
      [0xE5D00000 | (rn << 16) | (rd << 12) | (offset & 0xFFF)].pack("V")
    end

    # STR rd, [rn] — store 32-bit word to address in rn
    def str(rd, rn)
      [0xE5800000 | (rn << 16) | (rd << 12)].pack("V")
    end

    # STRB rd, [rn] — store the low byte of rd to the address in rn (the B, bit 22,
    # is what makes STR a byte store instead of a word store). A general byte write —
    # anything laid out as bytes rather than words.
    def strb(rd, rn)
      [0xE5C00000 | (rn << 16) | (rd << 12)].pack("V")
    end

    # STRB rd, [rn, #offset] — store the low byte of rd at an immediate offset from rn.
    # The offset form of {strb}, symmetric with {ldrb_offset}: it walks the bytes of a
    # word into consecutive addresses (a save slot in the 8-bit save memory) without
    # recomputing the base each time.
    def strb_offset(rd, rn, offset)
      [0xE5C00000 | (rn << 16) | (rd << 12) | (offset & 0xFFF)].pack("V")
    end

    # LDRSB rd, [rn] — load a byte and sign-extend it (so 0x80..0xFF read as -128..-1)
    # into the whole register, versus the zero-extending LDRB. The general way to read a
    # signed 8-bit value. (Signed loads use the extra load/store encoding, hence the
    # different shape from LDR/LDRB.)
    def ldrsb(rd, rn)
      [0xE1D000D0 | (rn << 16) | (rd << 12)].pack("V")
    end

    # STR rd, [rn, #offset] — store with immediate offset
    def str_offset(rd, rn, offset)
      if offset >= 0
        [0xE5800000 | (rn << 16) | (rd << 12) | (offset & 0xFFF)].pack("V")
      else
        [0xE5000000 | (rn << 16) | (rd << 12) | ((-offset) & 0xFFF)].pack("V")
      end
    end

    # LDRH rd, [rn] — load unsigned 16-bit halfword
    def load_halfword(rd, rn)
      # LDRH rd, [rn, #0]
      [0xE1D000B0 | (rn << 16) | (rd << 12)].pack("V")
    end

    # LDRSH rd, [rn] — load signed 16-bit halfword, sign-extended into the whole
    # register (the halfword counterpart of LDRSB; same encoding as LDRH but the
    # signed-halfword selector). The general way to read a signed 16-bit value.
    def ldrsh(rd, rn)
      [0xE1D000F0 | (rn << 16) | (rd << 12)].pack("V")
    end

    # Store a 16-bit value from a register to a memory address held in
    # another register: STRH src, [addr_reg]
    # @param src [Integer] source register
    # @param addr_reg [Integer] register holding the target address
    def store_halfword(src, addr_reg)
      # STRH src, [addr_reg, #0]
      [0xE1C000B0 | (addr_reg << 16) | (src << 12)].pack("V")
    end

    # --- Stack operations (PUSH/POP via STM/LDM) ---

    # PUSH registers onto stack (STMFD sp!, {regs})
    # @param regs [Array<Integer>] register numbers to push
    def push(*regs)
      mask = regs.flatten.sum { |r| 1 << r }
      # STMFD sp!, {regs} = STMDB r13!, {regs}
      [0xE92D0000 | mask].pack("V")
    end

    # POP registers from stack (LDMFD sp!, {regs})
    # @param regs [Array<Integer>] register numbers to pop
    def pop(*regs)
      mask = regs.flatten.sum { |r| 1 << r }
      # LDMFD sp!, {regs} = LDMIA r13!, {regs}
      [0xE8BD0000 | mask].pack("V")
    end

    # --- MOV register to register ---

    # MOV rd, rm
    def mov_reg(rd, rm)
      [0xE1A00000 | (rd << 12) | rm].pack("V")
    end

    # MOV{cond} rd, rm — a register move that only happens when +cond+ holds (ARM
    # predication). Follows a compare, so a value can be clamped with no branch (and
    # no pipeline flush) on a hot inner loop. cond: :gt, :lt, :ge, :le, :eq, :ne.
    def mov_reg_cond(cond, rd, rm)
      [(resolve_cond(cond) << 28) | 0x01A00000 | (rd << 12) | rm].pack("V")
    end

    # MOV{cond} rd, #imm — the immediate form of a predicated move (see #mov_reg_cond).
    def mov_imm_cond(cond, rd, imm)
      imm12 = encode_rotated_immediate(imm) or
        raise ArgumentError, "cannot encode #{imm} as an ARM rotated immediate"
      [(resolve_cond(cond) << 28) | 0x03A00000 | (rd << 12) | imm12].pack("V")
    end

    # --- SWI (software interrupt: trap into a BIOS routine) ---

    # SWI #comment — hand control to the BIOS to run one of its built-in routines
    # (division, decompression, ...). In ARM state the GBA BIOS reads the routine
    # number from the top byte of the 24-bit comment, so Div (routine 6) is
    # swi(0x06 << 16). The routine's inputs/outputs are passed in registers.
    def swi(comment)
      [0xEF000000 | (comment & 0x00FFFFFF)].pack("V")
    end

    # --- Helpers ---

    # Try to encode a 32-bit value as an ARM rotated 8-bit immediate.
    # ARM encoding: result = imm8 ROR (2 * rot4).
    # To find imm8: rotate value LEFT by (2 * rot4) to undo the ROR.
    # Returns the 12-bit imm12 field (rot4 << 8 | imm8) or nil if not possible.
    def encode_rotated_immediate(value)
      value &= 0xFFFFFFFF
      16.times do |rot|
        # Rotate left by rot*2 to undo: imm8 = value ROL (rot*2)
        shift = (rot * 2) & 31
        unrotated = ((value << shift) | (value >> (32 - shift))) & 0xFFFFFFFF
        # Handle shift=0 edge case (value >> 32 is 0 in Ruby for 32-bit values)
        unrotated = value if shift == 0
        if unrotated <= 0xFF
          return (rot << 8) | unrotated
        end
      end
      nil
    end

    # Resolve a condition code symbol to its numeric value.
    def resolve_cond(cond)
      case cond
      when Integer then cond
      when Symbol then COND_BY_NAME.fetch(cond) { raise ArgumentError, "unknown condition: #{cond}" }
      else raise ArgumentError, "expected Symbol or Integer condition, got #{cond.class}"
      end
    end
  end
end
