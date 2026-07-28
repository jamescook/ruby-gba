# frozen_string_literal: true

module RubyGBA
  # Inspects and pretty-prints GBA ROM files.
  # Useful for debugging generated ROMs without reaching for xxd.
  #
  # @example
  #   RubyGBA::Inspector.new("mygame.gba").report
  #
  # @example From a ROM object
  #   RubyGBA::Inspector.from_rom(rom).report
  class Inspector
    include Constants

    attr_reader :buffer

    def initialize(path)
      @buffer = File.binread(path)
      @path = path
    end

    def self.from_rom(rom)
      inst = allocate
      inst.instance_variable_set(:@buffer, rom.buffer.dup)
      inst.instance_variable_set(:@path, "(in-memory)")
      inst
    end

    # Print a full report of the ROM to stdout.
    def report
      puts header_report
      puts
      puts code_report
    end

    # Return a formatted header summary.
    def header_report
      lines = []
      lines << "=== GBA ROM Header ==="
      lines << "  File:     #{@path}"
      lines << "  Size:     #{@buffer.bytesize} bytes (#{(@buffer.bytesize / 1024.0).round(1)} KB)"
      lines << "  Title:    #{title.inspect}"
      lines << "  Code:     #{game_code}"
      lines << "  Maker:    #{maker_code}"
      lines << "  Entry:    0x#{entry_branch.to_s(16).upcase.rjust(8, '0')} → offset 0x#{entry_target.to_s(16).upcase}"
      lines << "  Fixed:    0x#{fixed_byte.to_s(16).upcase} #{fixed_byte == 0x96 ? '(OK)' : '(BAD - should be 0x96)'}"
      lines << "  Checksum: 0x#{checksum.to_s(16).upcase} #{checksum_valid? ? '(OK)' : '(BAD)'}"
      lines.join("\n")
    end

    # Return a disassembly of the code region.
    def code_report(max_instructions: 50)
      lines = []
      lines << "=== Code (offset 0x#{entry_target.to_s(16).upcase}+) ==="

      regs = Array.new(16, 0)
      offset = entry_target
      count = 0

      while offset + 4 <= @buffer.bytesize && count < max_instructions
        inst = @buffer[offset, 4].unpack1("V")
        break if inst == 0 && offset > entry_target + 4

        desc, regs = disassemble(inst, regs)
        lines << "  0x#{offset.to_s(16).upcase.rjust(4, '0')}: #{desc}"

        count += 1
        break if inst == 0xEAFFFFFE  # halt
        offset += 4
      end

      lines << "  ... (#{max_instructions} instruction limit)" if count >= max_instructions
      lines.join("\n")
    end

    def title
      @buffer[HEADER_TITLE, 12].delete("\x00")
    end

    def game_code
      @buffer[HEADER_CODE, 4]
    end

    def maker_code
      @buffer[HEADER_MAKER, 2]
    end

    def entry_branch
      @buffer[0, 4].unpack1("V")
    end

    def entry_target
      offset_field = entry_branch & 0x00FFFFFF
      # Sign-extend 24-bit offset
      offset_field -= 0x1000000 if offset_field >= 0x800000
      (offset_field + 2) * 4
    end

    def fixed_byte
      @buffer.getbyte(HEADER_FIXED)
    end

    def checksum
      @buffer.getbyte(HEADER_CHECKSUM)
    end

    def checksum_valid?
      sum = (HEADER_TITLE..0xBC).sum { |i| @buffer.getbyte(i) }
      expected = (-(sum + 0x19)) & 0xFF
      checksum == expected
    end

    private

    def ror(val, amount)
      amount &= 31
      return val if amount == 0
      ((val >> amount) | (val << (32 - amount))) & 0xFFFFFFFF
    end

    def decode_imm(inst)
      imm8 = inst & 0xFF
      rot4 = (inst >> 8) & 0xF
      ror(imm8, rot4 * 2)
    end

    COND_NAMES = {
      0x0 => "EQ", 0x1 => "NE", 0x2 => "CS", 0x3 => "CC",
      0x4 => "MI", 0x5 => "PL", 0x6 => "VS", 0x7 => "VC",
      0x8 => "HI", 0x9 => "LS", 0xA => "GE", 0xB => "LT",
      0xC => "GT", 0xD => "LE", 0xE => "",
    }.freeze

    REG_NAMES = {
      13 => "sp", 14 => "lr", 15 => "pc",
    }.freeze

    def reg(n)
      REG_NAMES[n] || "r#{n}"
    end

    def disassemble(inst, regs)
      regs = regs.dup
      cond = (inst >> 28) & 0xF
      cc = COND_NAMES[cond] || "?"

      if inst == 0xEAFFFFFE
        return ["HALT  (branch to self)", regs]
      end

      if inst == 0xE1A00000
        return ["NOP   (mov r0, r0)", regs]
      end

      # PUSH/POP (STM/LDM with sp)
      if (inst & 0x0FFF0000) == 0x092D0000  # STMFD sp!, {regs} = PUSH
        mask = inst & 0xFFFF
        rlist = (0..15).select { |r| mask[r] == 1 }.map { |r| reg(r) }
        return ["PUSH  {#{rlist.join(', ')}}", regs]
      end
      if (inst & 0x0FFF0000) == 0x08BD0000  # LDMFD sp!, {regs} = POP
        mask = inst & 0xFFFF
        rlist = (0..15).select { |r| mask[r] == 1 }.map { |r| reg(r) }
        return ["POP   {#{rlist.join(', ')}}", regs]
      end

      # BL (branch with link)
      if (inst & 0x0F000000) == 0x0B000000
        offset = inst & 0x00FFFFFF
        offset -= 0x1000000 if offset >= 0x800000
        return ["BL    ##{(offset + 2) * 4}", regs]
      end

      # Branch (conditional or unconditional)
      if (inst & 0x0F000000) == 0x0A000000
        offset = inst & 0x00FFFFFF
        offset -= 0x1000000 if offset >= 0x800000
        return ["B#{cc.ljust(4)} ##{(offset + 2) * 4}", regs]
      end

      # BX (branch and exchange)
      if (inst & 0x0FFFFFF0) == 0x012FFF10
        rm = inst & 0xF
        return ["BX    #{reg(rm)}", regs]
      end

      # SWI (software interrupt — trap into a BIOS routine; number is in the top byte)
      if (inst & 0x0F000000) == 0x0F000000
        comment = inst & 0x00FFFFFF
        return ["SWI   ##{(comment >> 16) & 0xFF} (0x#{comment.to_s(16)})", regs]
      end

      # MUL rd, rm, rs
      if (inst & 0x0FF000F0) == 0x00000090
        rd = (inst >> 16) & 0xF
        rs = (inst >> 8) & 0xF
        rm = inst & 0xF
        return ["MUL   #{reg(rd)}, #{reg(rm)}, #{reg(rs)}", regs]
      end

      # LDR/STR (immediate offset)
      if (inst & 0x0C000000) == 0x04000000
        rd = (inst >> 12) & 0xF
        rn = (inst >> 16) & 0xF
        offset = inst & 0xFFF
        load = (inst >> 20) & 1 == 1
        up = (inst >> 23) & 1 == 1
        off_str = offset > 0 ? (up ? ", #0x#{offset.to_s(16)}" : ", #-0x#{offset.to_s(16)}") : ""
        op = load ? "LDR" : "STR"
        return ["#{op}   #{reg(rd)}, [#{reg(rn)}#{off_str}]", regs]
      end

      # LDRH rd, [rn] / STRH rd, [rn] (halfword transfer)
      if (inst & 0x0E000090) == 0x00000090 && (inst & 0x60) != 0
        rd = (inst >> 12) & 0xF
        rn = (inst >> 16) & 0xF
        load = (inst >> 20) & 1 == 1
        sh = (inst >> 5) & 0x3  # 01=H, 10=SB, 11=SH
        op = load ? "LDR" : "STR"
        suffix = { 1 => "H", 2 => "SB", 3 => "SH" }[sh] || "?"
        val = regs[rd] & 0xFFFF
        addr = regs[rn]
        extra = load ? "" : "  ; store 0x#{val.to_s(16)} \u2192 [0x#{addr.to_s(16)}]"
        return ["#{op}#{suffix}  #{reg(rd)}, [#{reg(rn)}]#{extra}", regs]
      end

      # Data processing with immediate
      if (inst & 0x0E000000) == 0x02000000
        opcode = (inst >> 21) & 0xF
        rd = (inst >> 12) & 0xF
        rn = (inst >> 16) & 0xF
        imm_val = decode_imm(inst)

        dp_names = {
          0x0 => "AND", 0x1 => "EOR", 0x2 => "SUB", 0x3 => "RSB",
          0x4 => "ADD", 0x5 => "ADC", 0x6 => "SBC", 0x7 => "RSC",
          0x8 => "TST", 0x9 => "TEQ", 0xA => "CMP", 0xB => "CMN",
          0xC => "ORR", 0xD => "MOV", 0xE => "BIC", 0xF => "MVN",
        }
        name = dp_names[opcode] || "???"

        case opcode
        when 0x8, 0x9, 0xA, 0xB  # TST, TEQ, CMP, CMN — no dest
          return ["#{name}   #{reg(rn)}, #0x#{imm_val.to_s(16)}", regs]
        when 0xD, 0xF  # MOV, MVN — no source reg
          regs[rd] = (opcode == 0xD ? imm_val : ~imm_val) & 0xFFFFFFFF
          return ["#{name}   #{reg(rd)}, #0x#{imm_val.to_s(16)}  ; #{reg(rd)} = 0x#{regs[rd].to_s(16)}", regs]
        else
          return ["#{name}   #{reg(rd)}, #{reg(rn)}, #0x#{imm_val.to_s(16)}", regs]
        end
      end

      # Data processing with register (no shift or shift by immediate)
      if (inst & 0x0E000010) == 0x00000000
        opcode = (inst >> 21) & 0xF
        rd = (inst >> 12) & 0xF
        rn = (inst >> 16) & 0xF
        rm = inst & 0xF
        shift_amt = (inst >> 7) & 0x1F
        shift_type = (inst >> 5) & 0x3

        dp_names = {
          0x0 => "AND", 0x1 => "EOR", 0x2 => "SUB", 0x3 => "RSB",
          0x4 => "ADD", 0x5 => "ADC", 0x6 => "SBC", 0x7 => "RSC",
          0x8 => "TST", 0x9 => "TEQ", 0xA => "CMP", 0xB => "CMN",
          0xC => "ORR", 0xD => "MOV", 0xE => "BIC", 0xF => "MVN",
        }
        name = dp_names[opcode] || "???"
        shift_names = %w[LSL LSR ASR ROR]

        shift_str = ""
        if opcode == 0xD && shift_amt > 0
          # MOV with shift = shift instruction
          return ["#{shift_names[shift_type]}   #{reg(rd)}, #{reg(rm)}, ##{shift_amt}", regs]
        elsif shift_amt > 0
          shift_str = ", #{shift_names[shift_type]} ##{shift_amt}"
        end

        case opcode
        when 0x8, 0x9, 0xA, 0xB  # test/compare — no dest
          return ["#{name}   #{reg(rn)}, #{reg(rm)}#{shift_str}", regs]
        when 0xD, 0xF  # MOV/MVN — no source reg
          return ["#{name}   #{reg(rd)}, #{reg(rm)}#{shift_str}", regs]
        else
          return ["#{name}   #{reg(rd)}, #{reg(rn)}, #{reg(rm)}#{shift_str}", regs]
        end
      end

      ["???   0x#{inst.to_s(16).upcase.rjust(8, '0')}", regs]
    end
  end
end
