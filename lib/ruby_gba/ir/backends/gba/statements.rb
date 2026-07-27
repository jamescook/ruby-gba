# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Statement lowering: the dispatch, variable ops, and control flow.
        module Statements
          include Constants

          def emit_statement(node)
            case node.kind
            when :func then nil # emitted separately, after the main body
            when :set then emit_set(node)
            when :add then emit_accumulate(node, :add_reg)
            when :sub then emit_accumulate(node, :sub_reg)
            when :copy then emit_copy(node)
            when :negate then emit_negate(node)
            when :abs then emit_conditional_negate(node[:var], skip_when: :ge)
            when :negate_abs then emit_conditional_negate(node[:var], skip_when: :le)
            when :clamp then emit_clamp(node)
            when :if then emit_if(node)
            when :loop then emit_loop(node)
            when :repeat then emit_repeat(node)
            when :every then emit_every(node)
            when :after then emit_after(node)
            when :list_new then emit_list_new(node)
            when :list_push then emit_list_push(node)
            when :list_drop then emit_list_drop(node)
            when :list_set then emit_list_set(node)
            when :call then emit_branch(:bl, func_label(node[:target]))
            when :case then emit_case(node)
            when :raw then emit(node[:bytes]) # escape hatch: pre-assembled bytes, verbatim
            when :halt then emit(ASM.loop_forever)
            when :wait_vblank then emit_wait_vblank
            when :screen then emit_screen(node)
            when :pixel then emit_pixel(node)
            when :fill_rect then emit_fill_rect(node)
            when :clear_screen then emit_clear_screen(node)
            when :dma_fill_rect then emit_dma_fill_rect(node)
            when :draw_rect_at then emit_draw_rect_at(node)
            when :draw_text then emit_draw_text(node)
            when :draw_digit then emit_draw_digit(node)
            when :blit then emit_blit(node)
            when :blit_pose then emit_blit_pose(node)
            when :background then emit_background(node)
            when :scroll_background then emit_scroll_background(node)
            when :present_objects then emit_present_objects(node)
            when :save_region then emit_save_region(node)
            when :restore_region then emit_restore_region(node)
            when :enable_sound then emit_enable_sound
            when :define_sound, :song, :data, :bitmap, :backing_buffer, :object then nil # definitions: collected, nothing to emit
            when :beep then emit_beep(node)
            when :play_song then emit_play_song(node)
            when :stop_music then emit_stop_music
            else
              raise LoweringError, "the GBA backend cannot lower #{node.kind.inspect} yet"
            end
          end

          def emit_set(node)
            eval_value(node[:value])
            store_var(ACC, node[:var])
          end

          # add/sub: new value = var (op) operand. Evaluate the operand into the
          # accumulator, load the variable alongside it, combine, store back.
          def emit_accumulate(node, op)
            eval_value(node[:operand])       # r0 = operand
            load_var(TMP, node[:var])        # r1 = current value
            emit(ASM.send(op, ACC, TMP, ACC)) # r0 = r1 (op) r0
            store_var(ACC, node[:var])
          end

          def emit_copy(node)
            load_var(ACC, node[:src])
            store_var(ACC, node[:dest])
          end

          def emit_negate(node)
            load_var(ACC, node[:var])
            emit(ASM.rsb_imm(ACC, ACC, 0))   # r0 = 0 - r0
            store_var(ACC, node[:var])
          end

          # Negate a variable only when it sits on one side of zero — the shared
          # shape of abs (|v|: negate when < 0, so skip when >= 0) and negate_abs
          # (-|v|: negate when > 0, so skip when <= 0). Compare to zero, jump over
          # the negate when the value is already on the wanted side.
          def emit_conditional_negate(var, skip_when:)
            load_var(ACC, var)
            emit(ASM.cmp_imm(ACC, 0))
            done = gensym
            emit_branch(:bcond, done, cond: skip_when)
            emit(ASM.rsb_imm(ACC, ACC, 0))
            place_label(done)
            store_var(ACC, var)
          end

          # Clamp a variable into [min, max] with two compare-and-maybe-replace steps.
          def emit_clamp(node)
            load_var(ACC, node[:var])

            below = gensym
            emit(ASM.load_immediate(TMP, node[:min]))
            emit(ASM.cmp_reg(ACC, TMP))                 # var - min
            emit_branch(:bcond, below, cond: :ge)       # var >= min? leave it
            emit(ASM.mov_reg(ACC, TMP))                 # else clamp up to min
            place_label(below)

            above = gensym
            emit(ASM.load_immediate(TMP, node[:max]))
            emit(ASM.cmp_reg(ACC, TMP))                 # var - max
            emit_branch(:bcond, above, cond: :le)       # var <= max? leave it
            emit(ASM.mov_reg(ACC, TMP))                 # else clamp down to max
            place_label(above)

            store_var(ACC, node[:var])
          end

          # if: run the then-body when the condition is non-zero. With no else, a
          # false condition jumps past the body. With an else, a false condition
          # jumps to the else-body, and the then-body jumps over it to the end.
          def emit_if(node)
            eval_value(node[:cond])
            emit(ASM.cmp_imm(ACC, 0))
            else_node = node[:else]

            if else_node
              else_label = gensym
              end_label = gensym
              emit_branch(:bcond, else_label, cond: :eq) # false => run the else
              node.children.each { |stmt| emit_statement(stmt) }
              emit_branch(:b, end_label)                 # then done => skip the else
              place_label(else_label)
              else_node.children.each { |stmt| emit_statement(stmt) }
              place_label(end_label)
            else
              skip = gensym
              emit_branch(:bcond, skip, cond: :eq) # zero => condition false => skip
              node.children.each { |stmt| emit_statement(stmt) }
              place_label(skip)
            end
          end

          # loop: an endless repeat of the body — a jump back to the top. A `halt`
          # (or the step budget, on the interpreter) is what ends it.
          def emit_loop(node)
            top = gensym
            place_label(top)
            node.children.each { |stmt| emit_statement(stmt) }
            emit_branch(:b, top)
          end

          # repeat: a counted loop. The count is evaluated once into a hidden limit
          # variable (matching the interpreter, which captures the bound up front),
          # a hidden counter runs 0..count-1, and the body runs each pass. Counter
          # and limit live in memory, so the body is free to clobber registers.
          def emit_repeat(node)
            index = node[:index]
            limit = :"#{index}__limit"

            eval_value(node[:count])        # r0 = count
            store_var(ACC, limit)           # limit = count (once)
            emit(ASM.load_immediate(ACC, 0))
            store_var(ACC, index)           # counter = 0

            top = gensym
            done = gensym
            place_label(top)
            load_var(ACC, index)            # r0 = counter
            load_var(TMP, limit)            # r1 = limit
            emit(ASM.cmp_reg(ACC, TMP))     # counter - limit
            emit_branch(:bcond, done, cond: :ge) # counter >= limit => finished

            node.children.each { |stmt| emit_statement(stmt) }

            load_var(ACC, index)
            emit(ASM.add_imm(ACC, ACC, 1))  # counter += 1
            store_var(ACC, index)
            emit_branch(:b, top)
            place_label(done)
          end

          # every: run the body once every `period` frames. Tick the hidden frame
          # counter, and when it reaches the period, reset it and run the body. Built
          # as a small sub-tree and emitted through the shared statement emitters
          # (rather than hand-written instructions), so it reuses the tested add/if
          # lowering.
          def emit_every(node)
            counter = node[:counter]
            reached = Build.binop(:>=, Build.var_ref(counter), Build.int(node[:period]))
            gate = Build.if_(reached, Build.set(counter, Build.int(0)), *node.children)
            emit_statement(Build.add(counter, 1))
            emit_statement(gate)
          end

          # after: run the body exactly once, `frames` frames in. Count up only until
          # the target — so the counter never overflows or fires twice — and run the
          # body on the one frame it lands on. Built as a sub-tree emitted through the
          # shared statement emitters, reusing the tested add/if lowering.
          def emit_after(node)
            counter = node[:counter]
            frames = node[:frames]
            lands = Build.if_(Build.binop(:==, Build.var_ref(counter), Build.int(frames)), *node.children)
            not_yet = Build.if_(Build.binop(:<, Build.var_ref(counter), Build.int(frames)),
                                Build.add(counter, 1), lands)
            emit_statement(not_yet)
          end
        end
      end
    end
  end
end
