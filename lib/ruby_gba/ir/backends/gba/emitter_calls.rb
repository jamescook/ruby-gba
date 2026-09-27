# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # The calls the drawing code makes on nearly every line — emit an instruction, make
        # a label, read or write a variable — under their bare names, so a file that writes
        # code reads as the code it writes rather than as a chain of receivers.
        #
        # A class that includes this keeps the emitter in +@emitter+, the shared low-level
        # helpers in +@primitives+ and, if it divides, the divide routine in +@divide+.
        module EmitterCalls
          private

          def emit(bytes) = @emitter.emit(bytes)
          def pos = @emitter.pos
          def place_label(name) = @emitter.place_label(name)
          def gensym = @emitter.gensym
          def emit_branch(kind, target, cond: nil) = @emitter.emit_branch(kind, target, cond: cond)
          def emit_load_data_address(reg, name) = @emitter.emit_load_data_address(reg, name)
          def emit_load_label_address(reg, label) = @emitter.emit_load_label_address(reg, label)
          def write_reg16(address, value) = @emitter.write_reg16(address, value)
          def var_addr(name) = @primitives.var_addr(name)
          def load_var(reg, name) = @primitives.load_var(reg, name)
          def store_var(reg, name) = @primitives.store_var(reg, name)
          def store_word_acc(address) = @primitives.store_word_acc(address)
          def store_halfword_acc(address) = @primitives.store_halfword_acc(address)
          def store_word_immediate(value, address) = @primitives.store_word_immediate(value, address)
          def const_int(node) = @primitives.const_int(node)
          def constant_ints!(node, **sides) = @primitives.constant_ints!(node, **sides)
          def emit_row_loop(counter, &block) = @primitives.emit_row_loop(counter, &block)
          def emit_add_const(rd, rn, imm, scratch) = @primitives.emit_add_const(rd, rn, imm, scratch)
          def emit_call_divide_routine = @divide.emit_call_divide_routine

          # Store the low halfword of +reg+ to a fixed address (a sibling of
          # store_halfword_acc for when the value isn't in the accumulator).
          def store_halfword_reg(reg, address)
            emit(ASM.load_immediate(TMP, address))
            emit(ASM.store_halfword(reg, TMP))
          end
        end
      end
    end
  end
end
