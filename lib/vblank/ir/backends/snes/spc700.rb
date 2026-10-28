# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # THE SOUND PROCESSOR, ONE INSTRUCTION AT A TIME: an assembler for the SPC700, the 8-bit
        # processor inside the Super Nintendo's sound unit. The sound unit is a small computer of its
        # own beside the console:
        #
        #   - the SPC700, with three 8-bit registers (A, X and Y; Y and A together make the 16-bit
        #     YA), a stack in its memory's second page, and an instruction set that looks like the
        #     6502's with the opcodes numbered differently;
        #   - 64K of memory of its own, which holds its program, the recorded sounds it plays and
        #     everything else it keeps. The console's processor cannot reach into it: at power-on a
        #     small program built into the chip waits for the console to send a program across four
        #     one-byte mailboxes, and afterwards the two talk only through those mailboxes;
        #   - the S-DSP, which mixes eight voices, each playing one recorded sound at its own pitch,
        #     volume and envelope. The SPC700 sets the DSP's 128 registers through two of its own
        #     addresses ($F2 picks the register, $F3 is its value).
        #
        # Its addresses: the first 256 bytes (the "direct page") are reached by a one-byte address,
        # direct(n); the rest by a two-byte one, abs(n). A label is a String, and an address that names a
        # label is filled in when the program is assembled. Unlike the console's code, a program for
        # this processor is not placed by the Linker: it is copied into the sound unit's memory at
        # +origin+, so its labels are worked out from there and #assembled gives back its finished
        # bytes, ready to send.
        #
        #   spc = SPC700.new(origin: 0x0200)
        #   spc.mov :a, imm(0x7F)       # MOV A,#$7F
        #   spc.mov direct(0xF2), imm(0x0C) # MOV $F2,#$0C: pick the DSP's main volume
        #   spc.label "wait"
        #   spc.bra "wait"
        #
        # Operands are written in the order the native syntax writes them, the destination first
        # (mov direct(0x10), :a is MOV $10,A). The bytes after the opcode are NOT always in that order:
        # where both operands have bytes, the source's come first (MOV $F3,#$40 is 8F 40 F3).
        #
        # Opcodes: fullsnes, "SNES APU SPC700 CPU Load/Store Commands", "ALU Commands" and
        # "Jump/Control Commands" (https://problemkaputt.de/fullsnes.htm).
        class SPC700
          # An operand: how it reaches memory (+mode+), its address or number (+value+, an Integer or
          # a label), and for a bit operand which bit.
          Operand = Data.define(:mode, :value, :bit)

          # Raised for an instruction the SPC700 does not have, or a jump too far for its kind — a
          # mistake in the code that wrote it.
          class Error < StandardError; end

          # The forms MOV has: [destination, source] -> opcode.
          MOVES = {
            %i[a imm] => 0xE8, %i[x imm] => 0xCD, %i[y imm] => 0x8D, %i[a x] => 0x7D, %i[x a] => 0x5D,
            %i[a y] => 0xDD, %i[y a] => 0xFD, %i[x sp] => 0x9D, %i[sp x] => 0xBD,
            %i[a direct] => 0xE4, %i[a direct_x] => 0xF4, %i[a abs] => 0xE5, %i[a abs_x] => 0xF5, %i[a abs_y] => 0xF6,
            %i[a x_ind] => 0xE6, %i[a x_ind_inc] => 0xBF, %i[a direct_ind_y] => 0xF7, %i[a direct_x_ind] => 0xE7,
            %i[x direct] => 0xF8, %i[x direct_y] => 0xF9, %i[x abs] => 0xE9, %i[y direct] => 0xEB, %i[y direct_x] => 0xFB,
            %i[y abs] => 0xEC,
            %i[direct imm] => 0x8F, %i[direct direct] => 0xFA, %i[direct a] => 0xC4, %i[direct x] => 0xD8, %i[direct y] => 0xCB,
            %i[direct_x a] => 0xD4, %i[direct_x y] => 0xDB, %i[direct_y x] => 0xD9, %i[abs a] => 0xC5, %i[abs x] => 0xC9,
            %i[abs y] => 0xCC, %i[abs_x a] => 0xD5, %i[abs_y a] => 0xD6, %i[x_ind_inc a] => 0xAF,
            %i[x_ind a] => 0xC6, %i[direct_ind_y a] => 0xD7, %i[direct_x_ind a] => 0xC7
          }.freeze

          # MOVW: YA to and from a word in the direct page.
          WORD_MOVES = { %i[ya direct] => 0xBA, %i[direct ya] => 0xDA }.freeze

          # OR, AND, EOR, CMP, ADC and SBC: each a row of the table, its forms the row's columns.
          SUMS = { or_: 0x00, and_: 0x20, eor: 0x40, cmp: 0x60, adc: 0x80, sbc: 0xA0 }.freeze
          SUM_FORMS = {
            %i[a imm] => 0x08, %i[a x_ind] => 0x06, %i[a direct] => 0x04, %i[a direct_x] => 0x14, %i[a abs] => 0x05,
            %i[a abs_x] => 0x15, %i[a abs_y] => 0x16, %i[a direct_ind_y] => 0x17, %i[a direct_x_ind] => 0x07,
            %i[direct direct] => 0x09, %i[direct imm] => 0x18, %i[x_ind y_ind] => 0x19
          }.freeze
          # CMP's forms with X and Y.
          COMPARES = { %i[x imm] => 0xC8, %i[x direct] => 0x3E, %i[x abs] => 0x1E, %i[y imm] => 0xAD, %i[y direct] => 0x7E,
                       %i[y abs] => 0x5E }.freeze

          # ASL, ROL, LSR, ROR, DEC and INC on one operand.
          STEPS = { asl: 0x00, rol: 0x20, lsr: 0x40, ror: 0x60, dec: 0x80, inc: 0xA0 }.freeze
          STEP_FORMS = { a: 0x1C, direct: 0x0B, direct_x: 0x1B, abs: 0x0C }.freeze
          # Only DEC and INC have X and Y.
          COUNTS = { %i[dec x] => 0x1D, %i[inc x] => 0x3D, %i[dec y] => 0xDC, %i[inc y] => 0xFC }.freeze

          # The 16-bit sums on YA and a word in the direct page, and those on the word alone.
          WORD_SUMS = { addw: 0x7A, subw: 0x9A, cmpw: 0x5A }.freeze
          WORD_STEPS = { incw: 0x3A, decw: 0x1A }.freeze

          # The one-bit sums with the carry, on a bit of the first 8K (mem_bit): opcode, and the
          # opcode of the form that takes the bit turned round (not_bit), where there is one.
          CARRY_BITS = { or1: [0x0A, 0x2A], and1: [0x4A, 0x6A], eor1: [0x8A, nil] }.freeze

          # A bit of the direct page set or cleared, and the branches on one: the opcode of bit 0;
          # each bit after it is $20 on.
          BIT_WRITES = { set1: 0x02, clr1: 0x12 }.freeze
          BIT_BRANCHES = { bbs: 0x03, bbc: 0x13 }.freeze

          # The instructions with no operand.
          SINGLES = { nop: 0x00, brk: 0x0F, clrp: 0x20, setp: 0x40, clrc: 0x60, ret: 0x6F, reti: 0x7F, setc: 0x80,
                      ei: 0xA0, di: 0xC0, clrv: 0xE0, notc: 0xED, sleep: 0xEF, stop: 0xFF }.freeze

          # The instructions on one register alone, which the native syntax names (MUL YA, DAA A).
          ON_A_REGISTER = { mul: [0xCF, :ya], daa: [0xDF, :a], das: [0xBE, :a], xcn: [0x9F, :a] }.freeze

          BRANCHES = { bpl: 0x10, bra: 0x2F, bmi: 0x30, bvc: 0x50, bvs: 0x70, bcc: 0x90, bcs: 0xB0, bne: 0xD0,
                       beq: 0xF0 }.freeze

          PUSHES = { a: 0x2D, x: 0x4D, y: 0x6D, psw: 0x0D }.freeze
          POPS = { a: 0xAE, x: 0xCE, y: 0xEE, psw: 0x8E }.freeze

          REGISTERS = %i[a x y sp ya psw].freeze

          attr_reader :origin

          # +origin+ is where in the sound unit's memory the program will be copied to.
          def initialize(origin:)
            @origin = origin
            @bytes = +"".b
            @labels = {}
            @fixups = []
          end

          # --- operands ---

          def imm(value) = Operand.new(:imm, value, nil)
          def direct(value) = Operand.new(:direct, value, nil)
          def direct_x(value) = Operand.new(:direct_x, value, nil)
          def direct_y(value) = Operand.new(:direct_y, value, nil)
          def abs(value) = Operand.new(:abs, value, nil)
          def abs_x(value) = Operand.new(:abs_x, value, nil)
          def abs_y(value) = Operand.new(:abs_y, value, nil)
          # (X) and (Y): the byte in the direct page X or Y names; (X)+ moves X on after.
          def x_ind = Operand.new(:x_ind, nil, nil)
          def x_ind_inc = Operand.new(:x_ind_inc, nil, nil)
          def y_ind = Operand.new(:y_ind, nil, nil)
          # [aa]+Y: the byte at the address the direct page's word at aa holds, plus Y; [aa+X]: the
          # byte at the address the word at aa+X holds.
          def direct_ind_y(value) = Operand.new(:direct_ind_y, value, nil)
          def direct_x_ind(value) = Operand.new(:direct_x_ind, value, nil)
          # [!aaaa+X]: the jump to the address the word at aaaa+X holds.
          def abs_x_ind(value) = Operand.new(:abs_x_ind, value, nil)
          # Bit +bit+ of a byte of the direct page, and of a byte of the first 8K (13-bit address).
          def direct_bit(value, bit) = Operand.new(:direct_bit, value, bit_number!(bit))
          def mem_bit(value, bit) = Operand.new(:mem_bit, value, bit_number!(bit))
          # The same bit, read turned round (OR1 C,/aaa.b).
          def not_bit(value, bit) = Operand.new(:not_bit, value, bit_number!(bit))

          # --- labels and the finished program ---

          def here = @bytes.bytesize

          def label(name)
            name = name.to_s
            raise Error, "label #{name} is placed twice" if @labels.key?(name)

            @labels[name] = here
            name
          end

          # Where +name+ lands in the sound unit's memory.
          def address_of(name) = @origin + @labels.fetch(name.to_s) { raise Error, "no label #{name}" }

          # The program's bytes, each label's address filled in.
          def assembled
            bytes = @bytes.dup
            @fixups.each do |fixup|
              at = fixup.offset
              target = address_of(fixup.label)
              case fixup.kind
              when :absolute then bytes[at, 2] = [target].pack("v")
              when :relative
                distance = target - (@origin + at + 1)
                unless distance.between?(-128, 127)
                  raise Error, "#{fixup.label} is #{distance} bytes away, too far for a branch"
                end

                bytes.setbyte(at, distance & 0xFF)
              end
            end
            bytes
          end

          def data_bytes(*values) = values.flatten.each { |value| emit(byte!(value)) }
          def data_words(*values) = values.flatten.each { |value| emit(*word!(value)) }

          # --- instructions ---

          def mov(destination, source) = emit_form(MOVES, :mov, destination, source)
          def movw(destination, source) = emit_form(WORD_MOVES, :movw, destination, source)

          SUMS.each do |name, row|
            define_method(name) do |destination, source|
              form = [mode_of(destination), mode_of(source)]
              opcode = (name == :cmp && COMPARES[form]) || (SUM_FORMS[form] && (row + SUM_FORMS[form]))
              raise Error, "#{name} has no form #{form.inspect}" unless opcode

              emit_operands(opcode, destination, source)
            end
          end

          STEPS.each do |name, row|
            define_method(name) do |operand|
              kind = mode_of(operand)
              opcode = COUNTS[[name, kind]] || (STEP_FORMS[kind] && (row + STEP_FORMS[kind]))
              raise Error, "#{name} has no form #{kind.inspect}" unless opcode

              emit_operands(opcode, operand)
            end
          end

          WORD_SUMS.each do |name, opcode|
            define_method(name) do |register, word|
              raise Error, "#{name} sums YA with a word of the direct page" unless register == :ya && mode_of(word) == :direct

              emit_operands(opcode, word)
            end
          end

          WORD_STEPS.each do |name, opcode|
            define_method(name) do |word|
              raise Error, "#{name} counts a word of the direct page" unless mode_of(word) == :direct

              emit_operands(opcode, word)
            end
          end

          # A = YA / X, Y = what is left over.
          def div(register, by)
            raise Error, "div divides YA by X" unless register == :ya && by == :x

            emit(0x9E)
          end

          CARRY_BITS.each do |name, (opcode, turned)|
            define_method(name) do |carry, bit|
              raise Error, "#{name} sums the carry with a bit" unless carry == :c

              chosen = { mem_bit: opcode, not_bit: turned }[mode_of(bit)]
              raise Error, "#{name} has no form #{mode_of(bit).inspect}" unless chosen

              emit_operands(chosen, bit)
            end
          end

          # MOV1: the carry into a bit of the first 8K, or the bit into the carry.
          def mov1(destination, source)
            return emit_operands(0xCA, destination) if source == :c && mode_of(destination) == :mem_bit
            return emit_operands(0xAA, source) if destination == :c && mode_of(source) == :mem_bit

            raise Error, "mov1 moves a bit of the first 8K to or from the carry"
          end

          def not1(bit) = emit_operands(0xEA, refuse_mode_other_than!(bit, :mem_bit, :not1))

          # [aaaa] AND NOT A, and [aaaa] OR A, the flags set as CMP A,[aaaa] sets them first.
          def tclr1(place) = emit_operands(0x4E, refuse_mode_other_than!(place, :abs, :tclr1))
          def tset1(place) = emit_operands(0x0E, refuse_mode_other_than!(place, :abs, :tset1))

          BIT_WRITES.each do |name, opcode|
            define_method(name) do |bit|
              refuse_mode_other_than!(bit, :direct_bit, name)
              emit(opcode + (bit.bit * 0x20), byte!(bit.value))
            end
          end

          BIT_BRANCHES.each do |name, opcode|
            define_method(name) do |bit, target|
              refuse_mode_other_than!(bit, :direct_bit, name)
              emit(opcode + (bit.bit * 0x20), byte!(bit.value))
              emit_relative(target)
            end
          end

          SINGLES.each { |name, opcode| define_method(name) { emit(opcode) } }

          ON_A_REGISTER.each do |name, (opcode, register)|
            define_method(name) do |named|
              raise Error, "#{name} works on #{register.upcase}, not #{named.inspect}" unless named == register

              emit(opcode)
            end
          end

          BRANCHES.each do |name, opcode|
            define_method(name) do |target|
              emit(opcode)
              emit_relative(target)
            end
          end

          # Compare A with a byte of the direct page (or at aa+X), and branch when they differ.
          def cbne(place, target)
            opcode = { direct: 0x2E, direct_x: 0xDE }.fetch(mode_of(place)) { raise Error, "cbne compares A with direct or direct_x" }
            emit(opcode, byte!(place.value))
            emit_relative(target)
          end

          # Count Y, or a byte of the direct page, down by one, and branch unless it reached nought.
          def dbnz(counter, target)
            if counter == :y
              emit(0xFE)
            else
              emit(0x6E, byte!(refuse_mode_other_than!(counter, :direct, :dbnz).value))
            end
            emit_relative(target)
          end

          # A jump to a label or an address, or through a table (abs_x_ind).
          def jmp(target)
            return emit_operands(0x1F, target) if target.is_a?(Operand) && target.mode == :abs_x_ind

            emit(0x5F)
            emit_address(jump_target!(target, :jmp))
          end

          # A call pushes the address after it (not one less, as the 6502 does), and RET goes back there.
          def call(target)
            emit(0x3F)
            emit_address(jump_target!(target, :call))
          end

          # TCALL n: a call to the address in the word at $FFDE - 2n, a table running down from $FFDE.
          def tcall(number)
            raise Error, "tcall takes 0 to 15, not #{number}" unless number.between?(0, 15)

            emit((number << 4) | 0x01)
          end

          # PCALL: a call to $FF00 + +low+.
          def pcall(low) = emit(0x4F, byte!(low))

          def push(register) = emit(PUSHES.fetch(register) { raise Error, "push takes a, x, y or psw" })
          def pop(register) = emit(POPS.fetch(register) { raise Error, "pop takes a, x, y or psw" })

          private

          # How +operand+ reaches what it names: a register's name, or an Operand's mode.
          def mode_of(operand)
            return operand if REGISTERS.include?(operand) || operand == :c
            return operand.mode if operand.is_a?(Operand)

            raise Error, "#{operand.inspect} is not an operand"
          end

          # Refuses +operand+ unless it is in +mode+; gives it back when it is.
          def refuse_mode_other_than!(operand, mode, name)
            raise Error, "#{name} takes #{mode}, not #{mode_of(operand).inspect}" unless mode_of(operand) == mode

            operand
          end

          # +bit+, refused unless it is a bit of a byte (0 to 7).
          def bit_number!(bit)
            raise Error, "a bit is 0 to 7, not #{bit.inspect}" unless bit.is_a?(Integer) && bit.between?(0, 7)

            bit
          end

          def emit_form(table, name, destination, source)
            form = [mode_of(destination), mode_of(source)]
            opcode = table.fetch(form) { raise Error, "#{name} has no form #{form.inspect}" }
            emit_operands(opcode, destination, source)
          end

          # The opcode, then the operands' bytes: the source's before the destination's, which is the
          # order the processor reads them in (MOV aa,#nn is 8F nn aa; MOV aa,bb is FA bb aa).
          def emit_operands(opcode, *operands)
            emit(opcode)
            operands.reverse_each { |operand| emit_operand_bytes(operand) }
          end

          def emit_operand_bytes(operand)
            return unless operand.is_a?(Operand)

            case operand.mode
            when :imm, :direct, :direct_x, :direct_y, :direct_ind_y, :direct_x_ind then emit(byte!(operand.value))
            when :abs, :abs_x, :abs_y, :abs_x_ind then emit_address(operand.value)
            when :mem_bit, :not_bit
              unless operand.value.is_a?(Integer) && operand.value.between?(0, 0x1FFF)
                raise Error, "a bit's byte is a number in the first 8K, not #{operand.value.inspect}"
              end

              emit(*[operand.value | (operand.bit << 13)].pack("v").bytes)
            end
          end

          # A two-byte address, or a label's, filled in by #assembled.
          def emit_address(target)
            target = target.value if target.is_a?(Operand)
            if target.is_a?(Integer)
              emit(*word!(target))
            else
              @fixups << W65816::Fixup.new(offset: here, kind: :absolute, label: target.to_s, plus: 0)
              emit(0, 0)
            end
          end

          # One signed byte, counted from the byte after it, filled in by #assembled.
          def emit_relative(target)
            raise Error, "a branch needs somewhere to go" if target.nil?

            @fixups << W65816::Fixup.new(offset: here, kind: :relative, label: target.to_s, plus: 0)
            emit(0)
          end

          # Where a jump or a call goes: a label, an address, or abs(address); nothing else.
          def jump_target!(target, name)
            return target if target.is_a?(String) || target.is_a?(Integer)
            return target.value if target.is_a?(Operand) && target.mode == :abs

            raise Error, "#{name} goes to a label or an address, not #{mode_of(target).inspect}"
          end

          # +value+ as one byte, refused unless it fits in one.
          def byte!(value)
            raise Error, "#{value.inspect} does not fit in a byte" unless value.is_a?(Integer) && value.between?(-128, 255)

            value & 0xFF
          end

          # +value+ as two bytes, lowest first, refused unless it fits in them.
          def word!(value)
            raise Error, "#{value.inspect} does not fit in two bytes" unless value.is_a?(Integer) && value.between?(-0x8000, 0xFFFF)

            [value & 0xFF, (value >> 8) & 0xFF]
          end

          def emit(*values) = @bytes << values.pack("C*")
        end
      end
    end
  end
end
