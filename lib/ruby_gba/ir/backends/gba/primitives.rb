# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Small shared primitives: variable addresses, stores, constant folding.
        class Primitives
          include Constants

          def initialize(emitter:, memory:)
            @emitter = emitter
            @memory = memory
            @vars = {}             # variable name -> IWRAM address
            @held_registers = {}
          end

          # Every variable's allocated address (name => address) — read by GBA#var_addresses.
          attr_reader :vars

          # A variable is 4 bytes in IWRAM, addresses handed out on first mention — and
          # handed out at the near end, which is what keeps them inside the window the
          # note below is about. See {Memory}.
          def var_addr(name)
            @vars[name] ||= @memory.alloc_near_base(4)
          end

          # HOW FAR FROM THE BASE A VARIABLE CAN SIT and still be reached by naming the two
          # together. The instruction keeps twelve bits for the distance, so a thousand
          # variables. Past that the address is built in full, as everything used to be.
          FURTHEST_FROM_BASE = 0xFFF

          # READING A VARIABLE IS TWO INSTRUCTIONS, AND OFTEN ONE: put the base of the variable
          # memory in a register, then load from that register plus this variable's distance
          # along — and skip the first of those when the base is still sitting there from the
          # last access.
          #
          # It used to be the whole address and then a load, and the whole address is the
          # expensive part. This console can name a number in one instruction only when the
          # number has eight significant bits in the right places, which an address does not,
          # except by luck: the FIRST variable sits at the base itself and costs one, the next
          # sixty-three cost two, and everything past that costs three. So the hundredth variable
          # a program declares was read in four instructions and the first in two, for no reason
          # the program could see — it was the order the backend happened to emit things in.
          #
          # The base is a number this console CAN name in one instruction, and the distance rides
          # inside the load. So every variable is two, and the hundredth costs what the first
          # does. And since the base never changes for the life of the program, a run of accesses
          # with nothing between them that could disturb the register needs it made only once —
          # which is most of a run of arithmetic, where the whole of the work between two
          # variables is an add or a compare. What knows when it is still there is
          # {AddressRegister}, which is careful about it, because being wrong writes to the
          # wrong address rather than failing.
          #
          # A variable the code around us is already HOLDING in a register is one move instead,
          # and it is the same number either way because whoever holds it is keeping memory and
          # register in step (see Statements#emit_repeat, the only holder today: a loop's index).
          def load_var(reg, name)
            held = held_register(name)
            return @emitter.emit(ASM.mov_reg(reg, held)) if held

            offset = var_offset(name)
            return @emitter.emit(ASM.ldr_offset(reg, ADDR, offset)) if emit_var_base(offset)

            @emitter.emit(ASM.ldr(reg, ADDR))
          end

          def store_var(reg, name)
            offset = var_offset(name)
            return @emitter.emit(ASM.str_offset(reg, ADDR, offset)) if emit_var_base(offset)

            @emitter.emit(ASM.str(reg, ADDR))
          end

          def var_offset(name) = var_addr(name) - IWRAM_START

          # The register a variable is being held in for the moment, or nil. Kept as a plain
          # map rather than an allocator: exactly one thing puts anything in it, and it puts
          # the entry back the way it found it.
          def held_register(name) = @held_registers[name]

          # For a moment, read this variable from its memory rather than from the register that
          # was holding it — because the register is about to be lent to something else and put
          # back afterwards (see Statements#emit_bracketed).
          def not_holding(name, &block) = holding(name, nil, &block)

          def holding(name, reg)
            was = @held_registers[name]
            @held_registers[name] = reg
            yield
          ensure
            @held_registers[name] = was
            @held_registers.delete(name) if was.nil?
          end

          # Store the full 32-bit word in r0 to a fixed address.
          def store_word_acc(address)
            @emitter.emit(ASM.load_immediate(TMP, address))
            @emitter.emit(ASM.str(ACC, TMP))
          end

          # Store the low 16 bits of r0 to a fixed address — for a register that is a
          # halfword wide and holds a value the program worked out as it ran.
          def store_halfword_acc(address)
            @emitter.emit(ASM.load_immediate(TMP, address))
            @emitter.emit(ASM.store_halfword(ACC, TMP))
          end

          # Write a full 32-bit word to an address (used for the DMA registers).
          def store_word_immediate(value, address)
            @emitter.emit(ASM.load_immediate(ACC, value))
            @emitter.emit(ASM.load_immediate(TMP, address))
            @emitter.emit(ASM.str(ACC, TMP))
          end

          # The value of an operand the author fixed, or nil if the game works it out. The
          # same question the surface asks, so the two cannot disagree about what counts as
          # fixed; what this adds is the console's own arithmetic, where a number is signed
          # and thirty-two bits wide.
          def const_int(node)
            fixed = Value.fixed_number(node)
            Int32.wrap(fixed) if fixed
          end

          # Each named operand as a number settled while building, in the order given. The
          # caller passes the values along with what to call them, because the name is only
          # wanted for the message if one of them turns out to be worked out as the game runs.
          def constant_ints!(node, **sides)
            sides.map do |name, value|
              const_int(value) ||
                raise(LoweringError,
                      "the GBA backend needs a constant #{name} for #{node.kind} " \
                      "(a computed one is the runtime-rect work, tracked separately)")
            end
          end

          # Run +body+ once per row of a rect whose height the program works out as it
          # runs. +counter+ is the register holding how many rows are left; +body+ emits
          # one row and must leave the counter alone.
          #
          # The count is tested BEFORE the first row, which is what makes a height of
          # zero — or a negative one, from a bar that ran past empty — draw nothing
          # instead of wrapping round to four thousand million rows.
          def emit_row_loop(counter)
            top = @emitter.gensym
            done = @emitter.gensym
            @emitter.place_label(top)
            @emitter.emit(ASM.cmp_imm(counter, 0))
            @emitter.emit_branch(:bcond, done, cond: :le)
            yield
            @emitter.emit(ASM.sub_imm(counter, counter, 1))
            @emitter.emit_branch(:b, top)
            @emitter.place_label(done)
          end

          # rd = rn + imm. A small immediate rides directly in the ADD; a larger one
          # (a wide bitmap's row offset, say) is loaded into +scratch+ first, since
          # ARM can only fold an 8-bit rotated immediate into the instruction.
          def emit_add_const(rd, rn, imm, scratch)
            if imm.zero?
              @emitter.emit(ASM.mov_reg(rd, rn)) unless rd == rn
            elsif ASM.encode_rotated_immediate(imm)
              @emitter.emit(ASM.add_imm(rd, rn, imm))
            else
              @emitter.emit(ASM.load_immediate(scratch, imm))
              @emitter.emit(ASM.add_reg(rd, rn, scratch))
            end
          end

          # rd = rn & imm — the ring-wrap mask. A mask that fits an 8-bit rotated
          # immediate (capacity up to 256) rides directly in the AND; a wider one is
          # loaded into +scratch+ first, since ARM can't fold it into the instruction.
          def emit_and_const(rd, rn, imm, scratch)
            if ASM.encode_rotated_immediate(imm)
              @emitter.emit(ASM.and_imm(rd, rn, imm))
            else
              @emitter.emit(ASM.load_immediate(scratch, imm))
              @emitter.emit(ASM.and_reg(rd, rn, scratch))
            end
          end

          private

          # Put what the load will be read from into the address register: the base of the
          # variable memory when the variable is near enough to it, and the variable's own
          # address when it is not. Answers whether the distance still has to be named.
          #
          # A variable too far from the base leaves its own address behind rather than the
          # base, so nothing after it can lean on the register — and it is not worth
          # remembering either, since the next variable would want a different address.
          def emit_var_base(offset)
            near = offset.between?(0, FURTHEST_FROM_BASE)
            held = @emitter.address_register
            return near if near && held.holds?(IWRAM_START)

            @emitter.emit(ASM.load_immediate(ADDR, near ? IWRAM_START : IWRAM_START + offset))
            held.now_holds(IWRAM_START) if near
            near
          end
        end
      end
    end
  end
end
