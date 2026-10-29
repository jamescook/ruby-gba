# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # THE GAME BOY COLOR'S PROCESSOR, ONE INSTRUCTION AT A TIME: an assembler for the SM83, the
        # 8-bit processor every Game Boy runs, written so the lowering reads like the assembly a
        # person would write and never spells out an opcode by hand.
        #
        # The SM83 is small. It has seven 8-bit registers — A, the accumulator every sum goes
        # through, and B, C, D, E, H and L, which pair up as BC, DE and HL to hold a 16-bit
        # address or number — a stack pointer, and a program counter. Memory is reached through
        # an address in a register pair (HL above all) or written into the instruction. There is
        # no multiply and no divide, and nothing wider than 16 bits: the game's 32-bit numbers
        # are added a byte at a time, carrying from one byte into the next, by the runtime.
        #
        # An Assembler writes one Section: a run of bytes with names for places in it (labels)
        # and holes still to fill (fixups) where an instruction names a place that may be in
        # another section. The Linker puts the sections in the cartridge and fills the holes.
        #
        # How operands are written:
        #
        #   :a :b :c :d :e :h :l          8-bit registers
        #   :bc :de :hl :sp :af           register pairs
        #   0x12, -3                      a number (a byte or a 16-bit word, as the instruction wants)
        #   "rt_add32"                    a label: a String, so it can never be taken for a register
        #   [:hl] [:bc] [:de]             the byte at that address
        #   [:hli] [:hld]                 the byte at HL, then HL goes up (or down) by one
        #   [0xC000] ["counter"]          the byte at that address
        #
        #   asm.load :a, [:hli]           # LD A,(HL+): A = (HL), then HL += 1
        #   asm.add_a 4                   # ADD A,4
        #   asm.jump :nz, "loop"          # JP NZ: back to "loop" unless the last sum was nought
        #
        # Each method is one instruction, named for what it does where the mnemonic is two letters
        # (`load` for LD, `jump` for JP, `jump_relative` for JR) and by the mnemonic elsewhere.
        class SM83
          # The 8-bit registers as instructions number them: (HL) — the byte at HL — sits where
          # a seventh register would.
          REG8 = { b: 0, c: 1, d: 2, e: 3, h: 4, l: 5, a: 7 }.freeze
          AT_HL = 6

          # Register pairs as LD rr,nn / INC rr / ADD HL,rr number them, and as PUSH / POP do.
          PAIRS = { bc: 0, de: 1, hl: 2, sp: 3 }.freeze
          STACKED = { bc: 0, de: 1, hl: 2, af: 3 }.freeze

          # The conditions a jump can wait on: the zero flag and the carry flag, each set or clear.
          CONDITIONS = { nz: 0, z: 1, nc: 2, c: 3 }.freeze

          # The eight sums on A, in the order their opcodes go.
          ALU = { add_a: 0, adc_a: 1, sub_a: 2, sbc_a: 3, and_a: 4, xor_a: 5, or_a: 6, cp_a: 7 }.freeze

          # The shifts and turns behind the 0xCB prefix, in the order their opcodes go.
          SHIFTS = { rlc: 0, rrc: 1, rl: 2, rr: 3, sla: 4, sra: 5, swap: 6, srl: 7 }.freeze

          # The one-byte instructions with nothing to say.
          SINGLES = { nop: 0x00, rlca: 0x07, rrca: 0x0F, rla: 0x17, rra: 0x1F, daa: 0x27, cpl: 0x2F,
                      scf: 0x37, ccf: 0x3F, halt: 0x76, di: 0xF3, ei: 0xFB, reti: 0xD9 }.freeze

          # Raised for an instruction the processor does not have — a mistake in the lowering.
          class Error < StandardError; end

          # A place named in an instruction, filled in once everything is placed (Sections::Fixup).
          # Its +kind+ here is :word (its 16-bit address), :near (the same, for a jump or a call,
          # which can only reach the bank in view and the part always in view), :relative (a jump's
          # distance from the next instruction, one signed byte), or :bank (which bank of the
          # cartridge it is in).
          Fixup = Sections::Fixup

          # A named run of bytes (Sections::Section). Its +home+ here is :fixed for the part of the
          # cartridge always in view, :banked for any bank of the rest, or a label, which puts it in
          # the same bank as that label's section.
          Section = Sections::Section
          Holding = Sections::Holding

          attr_reader :bytes

          # +bank_noted_at+ is where #select_rom_bank notes the bank it puts in view, or nil for code
          # that need not note it (see #select_rom_bank); +bank_shown_at+ where every bank switch
          # writes the bank down, or nil (see #select_rom_bank_unnoted).
          def initialize(name, home: :banked, holds: nil, bank_noted_at: nil, bank_shown_at: nil)
            @name = name
            @home = home
            @holds = holds
            @bank_noted_at = bank_noted_at
            @bank_shown_at = bank_shown_at
            @bytes = +"".b
            @labels = {}
            @fixups = []
          end

          # Where the next byte goes, counted from the start of this section.
          def here = @bytes.bytesize

          # Names the next byte. A name is the whole program's: two sections cannot share one.
          def label(name)
            name = name.to_s
            raise Error, "label #{name} is placed twice" if @labels.key?(name)

            @labels[name] = here
            name
          end

          def section
            Section.new(name: @name, bytes: @bytes.dup.freeze, labels: @labels.dup.freeze, fixups: @fixups.dup.freeze,
                        home: @home, holds: @holds)
          end

          # BANK A OF THE CARTRIDGE PUT IN VIEW, in the window at 0x4000 that shows one bank at a time:
          # the cartridge's memory bank controller is told it. The controller cannot be asked which
          # bank it shows. So where the music player can interrupt the code to read a song kept in a
          # bank (Runtime::Music), the code notes each bank it puts in view, at +bank_noted_at+, and
          # the player puts that bank back when it is done. The bank is noted before the controller
          # is told: an interruption between the two puts back the bank about to be shown, which
          # the controller is then told again.
          def select_rom_bank
            load([@bank_noted_at], :a) if @bank_noted_at
            select_rom_bank_unnoted
          end

          # ...without noting it: the music player's own bank, for the length of its reading, and
          # the noted one put back after it. Where a recording is played (Runtime::Clips), whatever
          # bank is put in view is written down at +bank_shown_at+ first, for the timer's interrupt
          # to put back after it reads the recording's bank: the same order, for the same reason.
          def select_rom_bank_unnoted
            load([@bank_shown_at], :a) if @bank_shown_at
            load([Console::GBCHardware::MBC_ROM_BANK_LOW], :a)
          end

          # --- data ---

          def data_bytes(*values)
            values.flatten.each { |value| emit(byte(value)) }
          end

          # 16-bit words, low byte first; a label is its address.
          def data_words(*values)
            values.flatten.each do |value|
              if value.is_a?(String)
                fixup(:word, value)
                emit(0, 0)
              else
                emit(word(value) & 0xFF, word(value) >> 8)
              end
            end
          end

          # The number of the bank +label+ is in, as one byte.
          def data_bank_of(label)
            fixup(:bank, label)
            emit(0)
          end

          # LD r,n with n the number of the bank +label+ is in.
          def load_bank_of(register, label)
            emit(0x06 | (REG8.fetch(register) << 3))
            data_bank_of(label)
          end

          # Raw bytes, a String or an Array of numbers.
          def bytes_of(data)
            @bytes << (data.is_a?(String) ? data.b : data.pack("C*"))
          end

          # --- loads ---

          def load(dst, src)
            case [operand_kind(dst), operand_kind(src)]
            in [:reg8, :reg8] then emit(0x40 | (REG8.fetch(dst) << 3) | REG8.fetch(src))
            in [:reg8, :number] then emit(0x06 | (REG8.fetch(dst) << 3), byte(src))
            in [:pair | :sp, :number | :label] then ld_pair(dst, src)
            in [:sp, :pair] if dst == :sp && src == :hl then emit(0xF9)
            in [:reg8, :at] then ld_from(dst, src)
            in [:at, :reg8 | :number] then ld_to(dst, src)
            else raise Error, "there is no LD #{dst.inspect}, #{src.inspect}"
            end
          end

          # LDH: a byte in the last page of memory (0xFF00 up), where the hardware's registers and
          # the processor's own quick memory are — one byte shorter and quicker than LD.
          def load_high(dst, src)
            if dst == :a
              src == [:c] ? emit(0xF2) : emit(0xF0, high_page(src))
            elsif src == :a
              dst == [:c] ? emit(0xE2) : emit(0xE0, high_page(dst))
            else
              raise Error, "LDH moves A in or out, not #{dst.inspect}, #{src.inspect}"
            end
          end

          # HL = SP + +offset+.
          def load_hl_sp(offset) = emit(0xF8, signed_byte(offset))

          # (nn) = SP.
          def load_at_sp(address)
            emit(0x08)
            address_word(address)
          end

          # --- the stack ---

          def push(pair) = emit(0xC5 | (STACKED.fetch(pair) << 4))
          def pop(pair) = emit(0xC1 | (STACKED.fetch(pair) << 4))

          # SP += +offset+, a signed byte.
          def add_sp(offset) = emit(0xE8, signed_byte(offset))

          # --- sums ---

          # Each of them, written out as source rather than made from a block: a method made from a
          # block carries the block's surroundings, and Ruby will not let another Ractor call one —
          # so a cartridge built on another core stopped at its first sum.
          ALU.each do |name, number|
            class_eval <<~SUM, __FILE__, __LINE__ + 1
              def #{name}(operand) = alu(#{number}, :#{name}, operand)
            SUM
          end

          def alu(number, name, operand)
            case operand_kind(operand)
            when :reg8 then emit(0x80 | (number << 3) | REG8.fetch(operand))
            when :at
              raise Error, "#{name} reads only (HL) from memory" unless operand == [:hl]

              emit(0x80 | (number << 3) | AT_HL)
            when :number then emit(0xC6 | (number << 3), byte(operand))
            else raise Error, "there is no #{name} #{operand.inspect}"
            end
          end

          def inc(operand) = step(operand, 0x04, 0x03)
          def dec(operand) = step(operand, 0x05, 0x0B)

          # HL += +pair+.
          def add_hl(pair) = emit(0x09 | (PAIRS.fetch(pair) << 4))

          SINGLES.each do |name, opcode|
            class_eval <<~SINGLE, __FILE__, __LINE__ + 1
              def #{name} = emit(#{opcode})
            SINGLE
          end

          def stop = emit(0x10, 0x00)

          # --- shifts and bits (the 0xCB instructions) ---

          SHIFTS.each do |name, number|
            class_eval <<~SHIFT, __FILE__, __LINE__ + 1
              def #{name}(operand) = emit(0xCB, #{number << 3} | reg_or_hl(operand))
            SHIFT
          end

          def bit(number, operand) = emit(0xCB, 0x40 | (bit_number(number) << 3) | reg_or_hl(operand))
          def res(number, operand) = emit(0xCB, 0x80 | (bit_number(number) << 3) | reg_or_hl(operand))
          def set(number, operand) = emit(0xCB, 0xC0 | (bit_number(number) << 3) | reg_or_hl(operand))

          # --- jumps ---

          # JP to a label or an address, or to HL (`jp :hl`); with a condition first, only when
          # it holds.
          def jump(*args)
            return emit(0xE9) if args == [:hl]

            condition, target = conditional(args)
            emit(condition ? 0xC2 | (CONDITIONS.fetch(condition) << 3) : 0xC3)
            address_word(target, :near)
          end

          # JR: a jump of up to 127 bytes either way, one byte shorter than JP.
          def jump_relative(*args)
            condition, target = conditional(args)
            emit(condition ? 0x20 | (CONDITIONS.fetch(condition) << 3) : 0x18)
            raise Error, "JR needs a label" unless target.is_a?(String)

            fixup(:relative, target)
            emit(0)
          end

          def call(*args)
            condition, target = conditional(args)
            emit(condition ? 0xC4 | (CONDITIONS.fetch(condition) << 3) : 0xCD)
            address_word(target, :near)
          end

          def ret(condition = nil) = emit(condition ? 0xC0 | (CONDITIONS.fetch(condition) << 3) : 0xC9)

          # RST: a one-byte call to one of eight fixed addresses at the bottom of memory.
          def rst(address)
            raise Error, "RST goes to 0x00, 0x08 ... 0x38, not #{address}" unless (address % 8).zero? && address.between?(0, 0x38)

            emit(0xC7 | address)
          end

          private

          def emit(*values)
            @bytes << values.pack("C*")
          end

          def fixup(kind, label, plus = 0)
            @fixups << Fixup.new(offset: here, kind: kind, label: label.to_s, plus: plus)
          end

          def operand_kind(operand)
            case operand
            when :sp then :sp
            when *REG8.keys then :reg8
            when *PAIRS.keys then :pair
            when Integer then :number
            when String then :label
            when Array then :at
            else :unknown
            end
          end

          def ld_pair(pair, value)
            emit(0x01 | (PAIRS.fetch(pair) << 4))
            address_word(value)
          end

          # A = (BC), (DE), (HL+), (HL-), (nn); any register = (HL).
          def ld_from(dst, (at))
            if at == :hl then emit(0x46 | (REG8.fetch(dst) << 3))
            elsif dst != :a then raise Error, "only A can be loaded from #{at.inspect}"
            elsif at == :bc then emit(0x0A)
            elsif at == :de then emit(0x1A)
            elsif at == :hli then emit(0x2A)
            elsif at == :hld then emit(0x3A)
            else
              emit(0xFA)
              address_word(at)
            end
          end

          # (BC), (DE), (HL+), (HL-), (nn) = A; (HL) = any register or a number.
          def ld_to((at), src)
            if at == :hl
              src.is_a?(Integer) ? emit(0x36, byte(src)) : emit(0x70 | REG8.fetch(src))
            elsif src != :a then raise Error, "only A can be stored at #{at.inspect}"
            elsif at == :bc then emit(0x02)
            elsif at == :de then emit(0x12)
            elsif at == :hli then emit(0x22)
            elsif at == :hld then emit(0x32)
            else
              emit(0xEA)
              address_word(at)
            end
          end

          def step(operand, eight_bit, pair)
            case operand_kind(operand)
            when :reg8 then emit(eight_bit | (REG8.fetch(operand) << 3))
            when :pair, :sp then emit(pair | (PAIRS.fetch(operand) << 4))
            when :at
              raise Error, "INC and DEC reach memory only at (HL)" unless operand == [:hl]

              emit(eight_bit | (AT_HL << 3))
            else raise Error, "there is no INC/DEC #{operand.inspect}"
            end
          end

          def reg_or_hl(operand)
            return AT_HL if operand == [:hl]

            REG8.fetch(operand) { raise Error, "a bit or shift takes a register or (HL), not #{operand.inspect}" }
          end

          def bit_number(number)
            raise Error, "a byte has bits 0 to 7, not #{number}" unless number.between?(0, 7)

            number
          end

          def conditional(args)
            args.length == 2 ? args : [nil, args.first]
          end

          # A 16-bit address: a number written in, or a label filled in later.
          def address_word(target, kind = :word)
            if target.is_a?(String)
              fixup(kind, target)
              emit(0, 0)
            else
              value = word(target)
              emit(value & 0xFF, value >> 8)
            end
          end

          def high_page(address)
            address = address.first if address.is_a?(Array)
            return address & 0xFF if address.between?(0xFF00, 0xFFFF)
            return address if address.between?(0, 0xFF)

            raise Error, "LDH reaches 0xFF00 to 0xFFFF, not #{format('0x%04X', address)}"
          end

          def byte(value)
            raise Error, "#{value.inspect} is not a number that fits a byte" unless value.is_a?(Integer) && value.between?(-128, 255)

            value & 0xFF
          end

          def signed_byte(value)
            raise Error, "#{value} does not fit a signed byte" unless value.between?(-128, 127)

            value & 0xFF
          end

          def word(value)
            raise Error, "#{value.inspect} does not fit 16 bits" unless value.is_a?(Integer) && value.between?(-32_768, 0xFFFF)

            value & 0xFFFF
          end
        end
      end
    end
  end
end
