# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Small shared primitives: variable addresses, stores, constant folding, bounds.
        module Primitives
          include Constants

          # A variable is 4 bytes in IWRAM, addresses handed out on first mention.
          def var_addr(name)
            @vars[name] ||= begin
              address = @next_var
              @next_var += 4
              address
            end
          end

          # Reading a variable is normally building its address and loading it — three
          # instructions. A variable the code around us is already HOLDING in a register is one
          # move instead, and it is the same number either way because whoever holds it is
          # keeping memory and register in step (see Statements#emit_repeat, the only holder
          # today: a loop's index).
          def load_var(reg, name)
            held = held_register(name)
            return emit(ASM.mov_reg(reg, held)) if held

            emit(ASM.load_immediate(ADDR, var_addr(name)))
            emit(ASM.ldr(reg, ADDR))
          end

          def store_var(reg, name)
            emit(ASM.load_immediate(ADDR, var_addr(name)))
            emit(ASM.str(reg, ADDR))
          end

          # The register a variable is being held in for the moment, or nil. Kept as a plain
          # map rather than an allocator: exactly one thing puts anything in it, and it puts
          # the entry back the way it found it.
          def held_register(name) = (@held_registers ||= {})[name]

          def holding(name, reg)
            @held_registers ||= {}
            was = @held_registers[name]
            @held_registers[name] = reg
            yield
          ensure
            @held_registers[name] = was
            @held_registers.delete(name) if was.nil?
          end

          # Write a 16-bit value to a memory-mapped register / VRAM halfword.
          def write_reg16(address, value)
            emit(ASM.load_immediate(ACC, value))
            emit(ASM.load_immediate(TMP, address))
            emit(ASM.store_halfword(ACC, TMP))
          end

          # Store the full 32-bit word in r0 to a fixed address.
          def store_word_acc(address)
            emit(ASM.load_immediate(TMP, address))
            emit(ASM.str(ACC, TMP))
          end

          # Store the low 16 bits of r0 to a fixed address — for a register that is a
          # halfword wide and holds a value the program worked out as it ran.
          def store_halfword_acc(address)
            emit(ASM.load_immediate(TMP, address))
            emit(ASM.store_halfword(ACC, TMP))
          end

          # Write a full 32-bit word to an address (used for the DMA registers).
          def store_word_immediate(value, address)
            emit(ASM.load_immediate(ACC, value))
            emit(ASM.load_immediate(TMP, address))
            emit(ASM.str(ACC, TMP))
          end

          # The integer value of a constant operand, or nil if it isn't a constant.
          def const_int(node)
            return Int32.wrap(node) if node.is_a?(Integer)
            return Int32.wrap(node.value) if node.is_a?(Node) && node.kind == :int

            nil
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

          def in_bounds?(x, y)
            (0...SCREEN_WIDTH).cover?(x) && (0...SCREEN_HEIGHT).cover?(y)
          end

          # Run +body+ once per row of a rect whose height the program works out as it
          # runs. +counter+ is the register holding how many rows are left; +body+ emits
          # one row and must leave the counter alone.
          #
          # The count is tested BEFORE the first row, which is what makes a height of
          # zero — or a negative one, from a bar that ran past empty — draw nothing
          # instead of wrapping round to four thousand million rows.
          def emit_row_loop(counter)
            top = gensym
            done = gensym
            place_label(top)
            emit(ASM.cmp_imm(counter, 0))
            emit_branch(:bcond, done, cond: :le)
            yield
            emit(ASM.sub_imm(counter, counter, 1))
            emit_branch(:b, top)
            place_label(done)
          end
        end
      end
    end
  end
end
