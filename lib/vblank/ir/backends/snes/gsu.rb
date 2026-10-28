# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # THE SUPER FX, ONE INSTRUCTION AT A TIME: an assembler for the GSU, the processor some
        # Super Nintendo cartridges carry beside the console's own (the Super FX 2 of Yoshi's Island
        # and Doom is the GSU-2). It is a processor of its own, inside the cartridge, with its own
        # instructions and nothing in common with the 65816 but the cartridge it shares:
        #
        #   - sixteen 16-bit registers, R0 to R15. R15 is the program counter; R1 and R2 are where
        #     PLOT puts its next pixel (x and y), R12 and R13 what LOOP counts down and goes back to,
        #     R14 the ROM address GETB reads from, R11 where LINK leaves a return address.
        #   - an instruction is mostly one byte, its register in the low four bits. Which registers
        #     a sum reads and writes is said beforehand by prefixes: FROM Rn names where the next
        #     instruction reads from (the "source"), TO Rn where it writes (the "destination"), and
        #     WITH Rn both. Without them both are R0, and after each instruction both go back to R0.
        #   - ALT1, ALT2 and ALT3 are prefixes too: each turns the next opcode into another
        #     instruction (ADD Rn after ALT1 is ADC Rn, after ALT2 ADD #n, after ALT3 ADC #n).
        #   - it fetches one byte ahead, so the instruction after a branch or a jump always runs,
        #     whether the branch is taken or not. Code here puts a NOP there unless it has a use.
        #   - it reads the cartridge's ROM in banks $00-$5F and its own RAM in banks $70-$71, and
        #     draws into that RAM: PLOT writes one pixel into a picture laid out as the console's
        #     own tiles, so the console can copy it straight into its graphics memory.
        #
        # An instruction's register is a number 0..15; an immediate number is imm(n). A label is a
        # String, as in W65816. The GSU writes a Section the Linker places like any other; its
        # branches are filled in the way a 65816 branch is, one signed byte counted from the byte
        # after it (bsnes, processor/gsu/instructions.cpp, instructionBranch).
        #
        #   gsu.ibt 0, 0x5A        # IBT R0,#$5A
        #   gsu.iwt 1, 0x0000      # IWT R1,#$0000
        #   gsu.stb 1              # STB (R1): the low byte of R0 into RAM at R1
        #   gsu.stop               # STOP, and the NOP the chip has already fetched after it
        #
        # Opcodes: fullsnes, "SNES Cart GSU-n CPU Opcodes" (https://problemkaputt.de/fullsnes.htm),
        # checked against bsnes's processor/gsu/instruction.cpp.
        class GSU
          Imm = Data.define(:value)

          # Raised for an instruction the GSU does not have — a mistake in the code that wrote it.
          class Error < StandardError; end

          ALT1 = 0x3D
          ALT2 = 0x3E
          ALT3 = 0x3F

          BRANCHES = { bra: 0x05, bge: 0x06, blt: 0x07, bne: 0x08, beq: 0x09, bpl: 0x0A, bmi: 0x0B, bcc: 0x0C,
                       bcs: 0x0D, bvc: 0x0E, bvs: 0x0F }.freeze

          SINGLES = { stop: [0x00, 0x01], nop: [0x01], cache: [0x02], lsr: [0x03], rol: [0x04], loop: [0x3C],
                      alt1: [ALT1], alt2: [ALT2], alt3: [ALT3], plot: [0x4C], rpix: [ALT1, 0x4C], swap: [0x4D],
                      color: [0x4E], cmode: [ALT1, 0x4E], not_: [0x4F], merge: [0x70], sbk: [0x90], sex: [0x95],
                      asr: [0x96], div2: [ALT1, 0x96], ror: [0x97], lob: [0x9E], fmult: [0x9F],
                      lmult: [ALT1, 0x9F], hib: [0xC0], getc: [0xDF], ramb: [ALT2, 0xDF], romb: [ALT3, 0xDF],
                      getb: [0xEF], getbh: [ALT1, 0xEF], getbl: [ALT2, 0xEF], getbs: [ALT3, 0xEF] }.freeze

          # The sums with a register or a four-bit number: the base opcode, and the prefix of each of
          # the four forms (register, register after ALT1, number, number after ALT1).
          SUMS = { add: [0x50, nil, ALT2], adc: [0x50, ALT1, ALT3], sub: [0x60, nil, ALT2], sbc: [0x60, ALT1, nil],
                   cmp: [0x60, ALT3, nil], and_: [0x70, nil, ALT2], bic: [0x70, ALT1, ALT3],
                   mult: [0x80, nil, ALT2], umult: [0x80, ALT1, ALT3], or_: [0xC0, nil, ALT2],
                   xor: [0xC0, ALT1, ALT3] }.freeze

          def initialize(name, home: :any, holds: nil)
            @name = name
            @home = home
            @holds = holds
            @bytes = +"".b
            @labels = {}
            @fixups = []
          end

          def imm(value) = Imm.new(value)

          def here = @bytes.bytesize

          def label(name)
            name = name.to_s
            raise Error, "label #{name} is placed twice" if @labels.key?(name)

            @labels[name] = here
            name
          end

          def section
            W65816::Section.new(name: @name, bytes: @bytes.dup.freeze, labels: @labels.dup.freeze,
                                fixups: @fixups.dup.freeze, home: @home, holds: @holds)
          end

          SINGLES.each { |name, opcodes| define_method(name) { emit(*opcodes) } }

          BRANCHES.each do |name, opcode|
            define_method(name) do |target|
              emit(opcode)
              fixup(:relative, target)
              emit(0)
            end
          end

          # A sum on the source and +operand+, a register or imm(0..15), into the destination.
          SUMS.each do |name, (base, register_prefix, number_prefix)|
            define_method(name) do |operand|
              if operand.is_a?(Imm)
                raise Error, "#{name} has no number form" unless number_prefix
                # $70 and $C0 are MERGE and HIB whatever prefix comes before them.
                if operand.value.zero? && %i[and_ bic or_ xor].include?(name)
                  raise Error, "#{name} cannot take #0"
                end

                emit(number_prefix, base | checked_nibble(operand.value, name))
              else
                register = checked_register(operand)
                # MERGE, HIB and the like sit where register 0 of AND and OR would.
                raise Error, "#{name} cannot name R0" if register.zero? && %i[and_ bic or_ xor].include?(name)

                emit(*[register_prefix, base | register].compact)
              end
            end
          end

          # The prefixes that choose the registers of the next instruction.
          def to(register) = emit(0x10 | checked_register(register))
          def with(register) = emit(0x20 | checked_register(register))
          def from(register) = emit(0xB0 | checked_register(register))

          # Rd = Rs, and Rd = Rs with the flags set by it.
          def move(destination, source) = with(source) && to(destination)
          def moves(destination, source) = with(destination) && from(source)

          # 16 bits of the source into RAM at the address in +register+ (0..11), or its low 8 (STB).
          def stw(register) = emit(0x30 | checked_pointer(register))
          def stb(register) = emit(ALT1, 0x30 | checked_pointer(register))
          # 16 bits from RAM at the address in +register+ into the destination, or 8 (LDB).
          def ldw(register) = emit(0x40 | checked_pointer(register))
          def ldb(register) = emit(ALT1, 0x40 | checked_pointer(register))

          # R11 = the address of the instruction +count+ (1..4) bytes after this one, a return address.
          def link(count)
            raise Error, "LINK counts 1 to 4 bytes, not #{count}" unless (1..4).cover?(count)

            emit(0x90 | count)
          end

          # R15 = +register+ (8..13): a jump. LJMP is a jump to another bank: the bank from +register+
          # and the address from the source (bsnes, processor/gsu/instructions.cpp, LJMP).
          def jmp(register) = emit(0x90 | checked_jump_register(register))
          def ljmp(register) = emit(ALT1, 0x90 | checked_jump_register(register))

          def inc(register) = emit(0xD0 | checked_counter(register, :inc))
          def dec(register) = emit(0xE0 | checked_counter(register, :dec))

          # +register+ = a signed byte, sign-extended to 16 bits.
          def ibt(register, value)
            raise Error, "IBT takes -128..127, not #{value}" unless value.between?(-128, 127)

            emit(0xA0 | checked_register(register), value & 0xFF)
          end

          # +register+ = 16 bits: a number, or the low 16 bits of a label's address.
          def iwt(register, value)
            emit(0xF0 | checked_register(register))
            word(value)
          end

          # +register+ = the 16 bits in RAM at +address+, or the other way round (SM). LMS and SMS
          # reach the first 512 bytes in one byte less, at an even address.
          def lm(register, address) = emit(ALT1, 0xF0 | checked_register(register)) && word(address)
          def sm(address, register) = emit(ALT2, 0xF0 | checked_register(register)) && word(address)
          def lms(register, address) = emit(ALT1, 0xA0 | checked_register(register), checked_short_address(address))
          def sms(address, register) = emit(ALT2, 0xA0 | checked_register(register), checked_short_address(address))

          private

          def checked_register(value)
            raise Error, "a GSU register is 0..15, not #{value.inspect}" unless value.is_a?(Integer) && value.between?(0, 15)

            value
          end

          def checked_nibble(value, name)
            raise Error, "#{name} #n takes 0..15, not #{value}" unless value.between?(0, 15)

            value
          end

          def checked_pointer(value)
            raise Error, "a load or store names R0..R11, not R#{value}" unless checked_register(value) <= 11

            value
          end

          def checked_jump_register(value)
            raise Error, "a jump names R8..R13, not R#{value}" unless (8..13).cover?(checked_register(value))

            value
          end

          def checked_counter(value, name)
            raise Error, "#{name.upcase} names R0..R14, not R#{value}" unless checked_register(value) <= 14

            value
          end

          def checked_short_address(address)
            raise Error, "LMS and SMS reach an even address below 512, not #{address}" unless address.even? && address < 512

            address >> 1
          end

          def word(value)
            if value.is_a?(String)
              fixup(:abs, value)
              return emit(0, 0)
            end
            emit(value & 0xFF, (value >> 8) & 0xFF)
          end

          def fixup(kind, label) = @fixups << W65816::Fixup.new(offset: here, kind: kind, label: label.to_s, plus: 0)

          def emit(*values)
            @bytes << values.pack("C*")
            self
          end
        end
      end
    end
  end
end
