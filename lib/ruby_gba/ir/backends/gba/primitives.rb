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

          def load_var(reg, name)
            emit(ASM.load_immediate(ADDR, var_addr(name)))
            emit(ASM.ldr(reg, ADDR))
          end

          def store_var(reg, name)
            emit(ASM.load_immediate(ADDR, var_addr(name)))
            emit(ASM.str(reg, ADDR))
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
            return Int32.wrap(node[:value]) if node.is_a?(Node) && node.kind == :int

            nil
          end

          def constant_ints!(node, *keys)
            keys.map do |key|
              const_int(node[key]) ||
                raise(LoweringError,
                      "the GBA backend needs a constant #{key} for #{node.kind} " \
                      "(a computed one is the runtime-rect work, tracked separately)")
            end
          end

          def in_bounds?(x, y)
            (0...SCREEN_WIDTH).cover?(x) && (0...SCREEN_HEIGHT).cover?(y)
          end
        end
      end
    end
  end
end
