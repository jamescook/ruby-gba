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
            when :save_init then emit_save_init(node)
            when :save_store then emit_save_store(node)
            when :if then emit_if(node)
            when :loop then emit_loop(node)
            when :repeat then emit_repeat(node)
            when :every then emit_every(node)
            when :after then emit_after(node)
            when :list_new then emit_list_new(node)
            when :list_push then emit_list_push(node)
            when :list_drop then emit_list_drop(node)
            when :list_set then emit_list_set(node)
            when :call then emit_call_func(node[:target])
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
            when :scroll_rows then nil # a standing declaration — its body runs per line, from the dispatcher
            when :camera then emit_camera(node)
            when :fade then emit_fade(node)
            when :present_objects then emit_present_objects(node)
            when :save_region then emit_save_region(node)
            when :restore_region then emit_restore_region(node)
            when :enable_sound then emit_enable_sound
            when :define_sound, :song, :data, :bitmap, :backing_buffer, :object, :table then nil # definitions: collected, nothing to emit
            when :beep then emit_beep(node)
            when :noise then emit_noise(node)
            when :wave then emit_wave(node)
            when :stop_wave then emit_stop_wave
            when :play_song then emit_play_song(node)
            when :stop_music then emit_stop_music
            when :timer_start then emit_timer_start(node)
            when :timer_stop then emit_timer_stop(node)
            when :on_timer then nil # a handler definition — its body is emitted in the interrupt dispatcher
            when :sample then nil # a definition — its PCM data is embedded, nothing to emit here
            when :play_sample then emit_play_sample(node)
            when :stop_sample then emit_stop_sample(node)
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
          #
          # A bound the program works out as it runs is evaluated first and the value
          # being clamped waits on the stack, the same way a binary operation holds one
          # side while it computes the other. A bound that is a plain number skips all
          # that and loads straight into a register, so a program with fixed bounds
          # emits exactly what it always did.
          def emit_clamp(node)
            load_var(ACC, node[:var])
            clamp_acc_to(node[:min], cond: :ge) # below the floor? take the floor
            clamp_acc_to(node[:max], cond: :le) # above the ceiling? take the ceiling
            store_var(ACC, node[:var])
          end

          # Replace r0 with +bound+ unless the comparison against it already holds.
          def clamp_acc_to(bound, cond:)
            if (fixed = const_int(bound))
              emit(ASM.load_immediate(TMP, fixed))
            else
              emit(ASM.push(ACC))         # hold the value being clamped
              eval_value(bound)           # r0 = the bound
              emit(ASM.mov_reg(TMP, ACC)) # r1 = the bound
              emit(ASM.pop(ACC))          # r0 = the value again
            end

            keep = gensym
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, keep, cond: cond)
            emit(ASM.mov_reg(ACC, TMP))
            place_label(keep)
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
          #
          # The body is usually the busiest code in the whole program, so it is the first
          # thing worth keeping in the console's quick memory. When it has been chosen for
          # that (see {Placement}) the loop becomes a call into it and the body is emitted
          # with the other moved routines; otherwise it stays inline, exactly as it was.
          def emit_loop(node)
            top = gensym
            place_label(top)
            if @fast_funcs.include?(Placement::FRAME_ROUTINE)
              emit_call_func(Placement::FRAME_ROUTINE)
            else
              start = pos
              node.children.each { |stmt| emit_statement(stmt) }
              # Remember how big it came out: the measuring pass reads this to decide
              # whether moving it would fit.
              @func_ranges[Placement::FRAME_ROUTINE] = (start...pos)
            end
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
