# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # THE SUPER NINTENDO'S PROCESSOR, ONE INSTRUCTION AT A TIME: an assembler for the 65816
        # (the WDC W65C816, the Ricoh 5A22 inside the console runs it), written so the lowering
        # reads like the assembly a person would write and never spells out an opcode by hand.
        #
        # The 65816 is the 6502 grown to 16 bits. It has three registers a program works with: A,
        # the accumulator every sum goes through, and X and Y, which count and index. Each is 8
        # or 16 bits wide, as two flags say: M for A and X for X and Y. REP clears flags and SEP
        # sets them, so `rep 0x30` makes all three 16 bits wide and `sep 0x20` makes A 8 bits.
        # How wide A is decides how many bytes an instruction's number takes (LDA #5 is two bytes
        # with an 8-bit A and three with a 16-bit one), so the assembler follows REP and SEP as it
        # writes, and `widths` says what they are at a label code jumps to from elsewhere.
        #
        # Memory is reached with a 24-bit address: a bank (the top byte) and 64K inside it. An
        # instruction can name all 24 bits (long), 16 of them in the data bank (absolute), or 8 of
        # them on the direct page (a 256-byte window the lowering keeps its working numbers in).
        # There is no multiply or divide instruction: the console has small multiply and divide
        # units of its own, and the runtime uses them (Runtime::Int32).
        #
        # An Assembler writes one Section: a run of bytes with names for places in it (labels) and
        # holes still to fill (fixups) where an instruction names a place that may be in another
        # section. The Linker puts the sections in the cartridge and fills the holes. A section is
        # always placed whole inside one bank of the cartridge, so a branch or a JMP inside it
        # never has to leave the bank, which the processor cannot do without a long jump.
        #
        # How operands are written (each is an Operand, made by the helpers below):
        #
        #   5, -1, imm(5)                    a number: #5
        #   imm("table")                     the low 16 bits of where "table" is: #<table
        #   bank_of("table")                 the bank "table" is in: #^table
        #   dp(0x10)  dp_x(0x10)             $10, $10,X  on the direct page
        #   abs(0x0100)  abs_x  abs_y        $0100, $0100,X  in the data bank
        #   long("table")  long_x("table")   the 24-bit address of "table", and that plus X
        #   ind(0x10)  ind_y  ind_x          ($10), ($10),Y, ($10,X)
        #   ind_long(0x10)  ind_long_y       [$10], [$10],Y  (a 24-bit pointer on the direct page)
        #   stack(3)  stack_ind_y(3)         $03,S and ($03,S),Y
        #   :a                               the accumulator itself (ASL A, INC A)
        #
        # A label is a String (+plus+ adds to its address), so it can never be taken for a number.
        #
        #   asm.lda abs(0x0100)              # LDA $0100
        #   asm.adc 4                        # ADC #4
        #   asm.bne "loop"                   # back to "loop" unless the last result was nought
        class W65816
          Operand = Data.define(:mode, :value, :plus)

          # Raised for an instruction the processor does not have — a mistake in the lowering.
          class Error < StandardError; end

          # The eight sums on A, by mnemonic, and the opcode of each with a direct page operand
          # less five: every other way of naming the operand is a fixed step from it (the 65816's
          # opcode table, which keeps these eight in its odd columns).
          ALU = { ora: 0x00, and_a: 0x20, eor: 0x40, adc: 0x60, sta: 0x80, lda: 0xA0, cmp: 0xC0, sbc: 0xE0 }.freeze
          ALU_MODES = { ind_x: 0x01, stack: 0x03, dp: 0x05, ind_long: 0x07, imm: 0x09, abs: 0x0D, long: 0x0F,
                        ind_y: 0x11, ind: 0x12, stack_ind_y: 0x13, dp_x: 0x15, ind_long_y: 0x17, abs_y: 0x19,
                        abs_x: 0x1D, long_x: 0x1F }.freeze

          # The shifts and turns, and the steps from each one's opcode to its other forms.
          SHIFTS = { asl: 0x00, rol: 0x20, lsr: 0x40, ror: 0x60 }.freeze
          SHIFT_MODES = { dp: 0x06, a: 0x0A, abs: 0x0E, dp_x: 0x16, abs_x: 0x1E }.freeze

          # Every other instruction that takes an operand, by mnemonic and way of naming it.
          OPERATED = {
            inc: { a: 0x1A, dp: 0xE6, abs: 0xEE, dp_x: 0xF6, abs_x: 0xFE },
            dec: { a: 0x3A, dp: 0xC6, abs: 0xCE, dp_x: 0xD6, abs_x: 0xDE },
            ldx: { imm: 0xA2, dp: 0xA6, abs: 0xAE, dp_y: 0xB6, abs_y: 0xBE },
            ldy: { imm: 0xA0, dp: 0xA4, abs: 0xAC, dp_x: 0xB4, abs_x: 0xBC },
            stx: { dp: 0x86, abs: 0x8E, dp_y: 0x96 },
            sty: { dp: 0x84, abs: 0x8C, dp_x: 0x94 },
            stz: { dp: 0x64, dp_x: 0x74, abs: 0x9C, abs_x: 0x9E },
            cpx: { imm: 0xE0, dp: 0xE4, abs: 0xEC },
            cpy: { imm: 0xC0, dp: 0xC4, abs: 0xCC },
            bit: { imm: 0x89, dp: 0x24, abs: 0x2C, dp_x: 0x34, abs_x: 0x3C },
            tsb: { dp: 0x04, abs: 0x0C },
            trb: { dp: 0x14, abs: 0x1C },
            jmp: { abs: 0x4C, ind_abs: 0x6C, ind_abs_x: 0x7C },
            jml: { long: 0x5C, ind_long_abs: 0xDC },
            jsr: { abs: 0x20, ind_abs_x: 0xFC },
            jsl: { long: 0x22 },
            pei: { dp: 0xD4 },
            pea: { abs: 0xF4 }
          }.freeze

          # The instructions whose immediate number is as wide as A, and those as wide as X and Y.
          A_WIDE = (ALU.keys + [:bit]).freeze
          X_WIDE = %i[ldx ldy cpx cpy].freeze

          # The branches: one signed byte from the next instruction.
          BRANCHES = { bpl: 0x10, bmi: 0x30, bvc: 0x50, bvs: 0x70, bcc: 0x90, bcs: 0xB0, bne: 0xD0, beq: 0xF0,
                       bra: 0x80 }.freeze

          # Each conditional branch's opposite, for a branch too far for one byte (#branch_long).
          OPPOSITES = { bpl: :bmi, bmi: :bpl, bvc: :bvs, bvs: :bvc, bcc: :bcs, bcs: :bcc, bne: :beq, beq: :bne }.freeze

          # The one-byte instructions with nothing to say.
          SINGLES = {
            clc: 0x18, sec: 0x38, cli: 0x58, sei: 0x78, cld: 0xD8, sed: 0xF8, clv: 0xB8,
            tax: 0xAA, tay: 0xA8, txa: 0x8A, tya: 0x98, tsx: 0xBA, txs: 0x9A, txy: 0x9B, tyx: 0xBB,
            tcd: 0x5B, tdc: 0x7B, tcs: 0x1B, tsc: 0x3B, xba: 0xEB, xce: 0xFB,
            pha: 0x48, pla: 0x68, phx: 0xDA, plx: 0xFA, phy: 0x5A, ply: 0x7A, php: 0x08, plp: 0x28,
            phb: 0x8B, plb: 0xAB, phd: 0x0B, pld: 0x2B, phk: 0x4B,
            inx: 0xE8, iny: 0xC8, dex: 0xCA, dey: 0x88,
            rts: 0x60, rtl: 0x6B, rti: 0x40, nop: 0xEA, wai: 0xCB, stp: 0xDB
          }.freeze

          # A place named in an instruction, filled in once everything is placed. +kind+ is :abs
          # (the low 16 bits of its address), :long (all 24), :bank (the top 8), :relative (a
          # branch's distance from the next instruction, one signed byte) or :relative_long (BRL's
          # and PER's, two).
          Fixup = Data.define(:offset, :kind, :label, :plus)

          # A named run of bytes, with the labels it defines and the holes it leaves. +home+ says
          # where it must go: :first for the cartridge's first bank, where the processor starts
          # and its interrupts land, or :any. +holds+ is what of the GAME's it keeps (a Holding),
          # so a cartridge too full can say which of the game's parts is too big; nil for the
          # framework's own code.
          Section = Data.define(:name, :bytes, :labels, :fixups, :home, :holds) do
            def size = bytes.bytesize
          end

          # One of the game's parts, in words the author knows: +what+ it is ("the game's songs")
          # and +fix+, what the author can do to make it smaller.
          Holding = Data.define(:what, :fix)

          attr_reader :bytes

          def initialize(name, home: :any, holds: nil)
            @name = name
            @home = home
            @holds = holds
            @bytes = +"".b
            @labels = {}
            @fixups = []
            @wide_a = true
            @wide_x = true
          end

          # --- operands ---

          def imm(value, plus = 0) = Operand.new(:imm, value, plus)
          def bank_of(label) = Operand.new(:imm_bank, label, 0)
          def dp(value) = Operand.new(:dp, value, 0)
          def dp_x(value) = Operand.new(:dp_x, value, 0)
          def dp_y(value) = Operand.new(:dp_y, value, 0)
          def abs(value, plus = 0) = Operand.new(:abs, value, plus)
          def abs_x(value, plus = 0) = Operand.new(:abs_x, value, plus)
          def abs_y(value, plus = 0) = Operand.new(:abs_y, value, plus)
          def long(value, plus = 0) = Operand.new(:long, value, plus)
          def long_x(value, plus = 0) = Operand.new(:long_x, value, plus)
          def ind(value) = Operand.new(:ind, value, 0)
          def ind_x(value) = Operand.new(:ind_x, value, 0)
          def ind_y(value) = Operand.new(:ind_y, value, 0)
          def ind_long(value) = Operand.new(:ind_long, value, 0)
          def ind_long_y(value) = Operand.new(:ind_long_y, value, 0)
          def stack(value) = Operand.new(:stack, value, 0)
          def stack_ind_y(value) = Operand.new(:stack_ind_y, value, 0)
          def ind_abs(value, plus = 0) = Operand.new(:ind_abs, value, plus)
          def ind_abs_x(value, plus = 0) = Operand.new(:ind_abs_x, value, plus)
          def ind_long_abs(value, plus = 0) = Operand.new(:ind_long_abs, value, plus)

          # --- the section ---

          # Where the next byte goes, counted from the start of this section.
          def here = @bytes.bytesize

          # Names the next byte. A name is the whole program's: two sections cannot share one.
          def label(name)
            name = name.to_s
            raise Error, "label #{name} is placed twice" if @labels.key?(name)

            @labels[name] = here
            name
          end

          # What the code at the next label finds A, X and Y to be: +a16+ and +xy16+ say whether
          # they are 16 bits wide. Code jumped to from elsewhere says so, since the assembler
          # follows REP and SEP only as it writes them in order.
          def widths(a16:, xy16:)
            @wide_a = a16
            @wide_x = xy16
          end

          def wide_a? = @wide_a
          def wide_xy? = @wide_x

          def section
            Section.new(name: @name, bytes: @bytes.dup.freeze, labels: @labels.dup.freeze, fixups: @fixups.dup.freeze,
                        home: @home, holds: @holds)
          end

          # --- data ---

          def data_bytes(*values) = values.flatten.each { |value| emit(byte(value)) }

          # 16-bit words, low byte first; a label is the low 16 bits of its address.
          def data_words(*values)
            values.flatten.each do |value|
              if value.is_a?(String)
                fixup(:abs, value)
                emit(0, 0)
              else
                emit(value & 0xFF, (value >> 8) & 0xFF)
              end
            end
          end

          # 24-bit addresses, low byte first: where each label is.
          def data_longs(*labels)
            labels.flatten.each do |label|
              fixup(:long, label)
              emit(0, 0, 0)
            end
          end

          # --- instructions ---

          ALU.each do |name, base|
            define_method(name) do |operand|
              mode = mode_of(name, operand)
              refuse_mode!(name, operand) if name == :sta && mode == :imm # its place is BIT #'s
              emit_operated(name, operand, base + ALU_MODES.fetch(mode))
            end
          end

          SHIFTS.each do |name, base|
            define_method(name) do |operand = :a|
              emit_operated(name, operand, base + SHIFT_MODES.fetch(mode_of(name, operand)))
            end
          end

          OPERATED.each do |name, modes|
            define_method(name) do |operand = :a|
              emit_operated(name, operand, modes.fetch(mode_of(name, operand)) { refuse_mode!(name, operand) })
            end
          end

          SINGLES.each { |name, opcode| define_method(name) { emit(opcode) } }

          BRANCHES.each do |name, opcode|
            define_method(name) do |target|
              emit(opcode)
              fixup(:relative, target)
              emit(0)
            end
          end

          # BRL: anywhere in the bank, two signed bytes from the next instruction.
          def brl(target)
            emit(0x82)
            fixup(:relative_long, target)
            emit(0, 0)
          end

          # A conditional branch to anywhere in the bank: the opposite branch over a BRL.
          def branch_long(condition, target)
            emit(BRANCHES.fetch(OPPOSITES.fetch(condition)), 3)
            brl(target)
          end

          # REP and SEP clear and set the processor's flags; the widths of A and of X and Y follow.
          def rep(flags)
            emit(0xC2, flags & 0xFF)
            @wide_a = true if flags.anybits?(0x20)
            @wide_x = true if flags.anybits?(0x10)
          end

          def sep(flags)
            emit(0xE2, flags & 0xFF)
            @wide_a = false if flags.anybits?(0x20)
            @wide_x = false if flags.anybits?(0x10)
          end

          # MVN and MVP copy a block: X from, Y to, A+1 bytes, between the two banks named.
          def mvn(to_bank, from_bank) = emit(0x54, to_bank, from_bank)
          def mvp(to_bank, from_bank) = emit(0x44, to_bank, from_bank)

          private

          def mode_of(name, operand)
            return :imm if operand.is_a?(Integer)
            return :a if operand == :a
            raise Error, "#{name} takes an Operand, not #{operand.inspect}" unless operand.is_a?(Operand)

            operand.mode == :imm_bank ? :imm : operand.mode
          end

          def refuse_mode!(name, operand)
            raise Error, "the 65816 has no #{name.to_s.upcase} with #{mode_of(name, operand)}"
          end

          def emit_operated(name, operand, opcode)
            operand = Operand.new(:imm, operand, 0) if operand.is_a?(Integer)
            return emit(opcode) if operand == :a

            emit(opcode)
            case operand.mode
            when :imm then emit_immediate(name, operand)
            when :imm_bank
              fixup(:bank, operand.value)
              emit(0)
              emit(0) if wide_immediate?(name)
            when :dp, :dp_x, :dp_y, :ind, :ind_x, :ind_y, :ind_long, :ind_long_y, :stack, :stack_ind_y
              emit(byte(operand.value))
            when :abs, :abs_x, :abs_y, :ind_abs, :ind_abs_x, :ind_long_abs then emit_address(operand, :abs, 2)
            when :long, :long_x then emit_address(operand, :long, 3)
            else refuse_mode!(name, operand)
            end
          end

          def wide_immediate?(name)
            return @wide_a if A_WIDE.include?(name)
            return @wide_x if X_WIDE.include?(name)

            raise Error, "#{name} has no immediate form"
          end

          def emit_immediate(name, operand)
            if operand.value.is_a?(String)
              raise Error, "#{name} ##{operand.value} needs a 16-bit register" unless wide_immediate?(name)

              fixup(:abs, operand.value, operand.plus)
              return emit(0, 0)
            end
            value = operand.value + operand.plus
            wide_immediate?(name) ? emit(value & 0xFF, (value >> 8) & 0xFF) : emit(byte(value))
          end

          def emit_address(operand, kind, size)
            if operand.value.is_a?(String)
              fixup(kind, operand.value, operand.plus)
              return emit(*Array.new(size, 0))
            end
            value = operand.value + operand.plus
            emit(*Array.new(size) { |i| (value >> (8 * i)) & 0xFF })
          end

          def byte(value)
            raise Error, "#{value} does not fit in a byte" unless value.between?(-128, 255)

            value & 0xFF
          end

          def fixup(kind, label, plus = 0) = @fixups << Fixup.new(offset: here, kind: kind, label: label.to_s, plus: plus)

          def emit(*values) = @bytes << values.pack("C*")
        end
      end
    end
  end
end
