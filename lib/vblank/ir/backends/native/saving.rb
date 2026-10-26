# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # THE GAME'S SAVE MEMORY, written as calls into runtime/rg_save.h — mixed into Lowering
        # the way Picture and Sound are.
        #
        # Nearly all of saving is the game's own: the routines that lay a record out, write it a
        # piece each pass and say whether a copy is good are built by the Builder out of ordinary
        # statements, and are written as C with the rest of the game. What is left for a backend
        # is the handful of ways into save memory itself — read, write, total, wipe — and the two
        # statements `save_var` is made of. Each is written here the way the interpreter runs it
        # (the Reference method is named beside each), against bytes laid out as IR::SaveLayout
        # says, so the game as C keeps the same bytes the interpreter's IR::SaveImage does.
        module Saving
          # The kinds that reach save memory, and whether a program names any (IR::SaveLayout).
          KINDS = SaveLayout::KINDS

          def self.named_by?(program) = SaveLayout.named_by?(program)

          private

          # The save memory the game has, as the runtime reads it (see rg_game_save_memory in
          # runtime/rg_save.h). Its rules are written here, from IR::SaveLayout and
          # IR::SaveImage, rather than copied into the C. A game that can never reach save
          # memory is given none, so it reads and writes no file.
          def save_memory_table
            memory = SaveLayout.memory_of(@program)
            reached = @reachable.any? { |node| KINDS.include?(node.kind) }
            C::ConstArray.new(name: @names.own("save_memory"), type: "int32_t", exported: true,
                              values: [reached ? memory.size : 0, memory.flash? ? memory.block : 0,
                                       SaveImage::FRESH_BYTE, SaveImage::BUSY_BYTE])
          end

          # Reference#exec_save_init: every `save_var` takes its saved number when save memory
          # carries the game's marker, and the number it was declared with when it does not.
          # Each is written back, and the marker after them, in that order — so a power cut
          # lands on the same byte it lands on in the interpreter.
          def lower_save_init(node)
            saved = local_name("saved")
            word = C::Int.new(Reference::SAVE_WIDTHS.fetch(:word))
            marker_at = C::Int.new(SaveLayout::SAVE_VAR_MARKER_AT)
            marker = C::Int.new(Int32.wrap(node.magic))
            loads = node.vars.flat_map do |kept|
              at = C::Int.new(SaveLayout.save_var_at(kept.slot))
              [C::If.new(condition: saved, body: [assign(kept.name, call("rg_save_read", at, word))],
                         otherwise: [assign(kept.name, C::Int.new(Int32.wrap(kept.default)))]),
               eval_call("rg_save_write", at, variable(kept.name), word)]
            end
            [C::Block.new([C::Local.new(name: saved, value: call("rg_eq", call("rg_save_read", marker_at, word), marker)),
                           *loads, eval_call("rg_save_write", marker_at, marker, word)])]
          end

          # Reference#exec_save_store: one `save_var`'s number into its place.
          def lower_save_store(node)
            at = C::Int.new(SaveLayout.save_var_at(node.slot))
            [eval_call("rg_save_write", at, variable(node.var), C::Int.new(Reference::SAVE_WIDTHS.fetch(:word)))]
          end

          # Reference#exec_save_write. The place is worked out first and kept, and the value
          # after it, as the interpreter works them out: C does not say which of a call's
          # arguments it works out first, and a value read from save memory can end a wipe.
          def lower_save_write(node)
            at = local_name("at")
            [C::Block.new([C::Local.new(name: at, value: value(node.at)),
                           eval_call("rg_save_write", at, value(node.value), save_width(node))])]
          end

          # Reference#exec_save_erase: the wipe is waited for unless the node says not to.
          def lower_save_erase(node)
            [eval_call("rg_save_erase", value(node.at), C::Int.new(node.wait == false ? 0 : 1))]
          end

          def value_of_save_read(node) = call("rg_save_read", value(node.at), save_width(node))
          def value_of_save_sum(node) = call("rg_save_sum", value(node.at), value(node.length))

          def save_width(node) = C::Int.new(Reference::SAVE_WIDTHS.fetch(node.width))
        end
      end
    end
  end
end
