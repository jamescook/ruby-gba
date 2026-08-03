# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Evaluating value nodes (arithmetic, comparisons, data, input reads).
        module Expressions
          include Constants

          # Emit code that leaves the value of +node+ in the accumulator (r0).
          def eval_value(node)
            case node.kind
            when :int then emit(ASM.load_immediate(ACC, Int32.wrap(node[:value])))
            when :var_ref then load_var(ACC, node[:name])
            when :neg
              eval_value(node[:operand])
              emit(ASM.rsb_imm(ACC, ACC, 0))
            when :binop then eval_binop(node)
            when :held then eval_held(node[:button])
            when :pressed then eval_pressed(node[:button])
            # A chance is "the random draw is below the threshold" — evaluate it as
            # exactly that comparison.
            when :chance then eval_value(Build.binop(:<, node[:draw], Build.int(node[:percent])))
            when :pixels_overlap then eval_pixels_overlap(node)
            when :data_byte then eval_data_byte(node)
            when :table_get then eval_table_get(node)
            when :list_get then eval_list_get(node)
            when :list_len then eval_list_len(node)
            when :read_scanline then eval_read_scanline
            when :timer_ticks then eval_timer_ticks(node)
            else
              raise LoweringError, "the GBA backend cannot evaluate #{node.kind.inspect}"
            end
          end

          # Read VCOUNT — the scanline being drawn right now (0..227) — into the
          # accumulator. A halfword load straight from the display's scanline register.
          def eval_read_scanline
            emit(ASM.load_immediate(TMP, REG_VCOUNT))
            emit(ASM.load_halfword(ACC, TMP))
          end

          # Read one byte of a named blob: point the address register at the blob,
          # then load the byte at its fixed index into the accumulator.
          def eval_data_byte(node)
            emit_load_data_address(ADDR, node[:name])
            emit(ASM.ldrb_offset(ACC, ADDR, node[:index]))
          end

          # Read table[index] into the accumulator: evaluate the index, make it safe
          # (wrap a power-of-two table with a mask, clamp any other size), scale it to a
          # byte offset, add the table's base address, and load the element — with a
          # signed load when the table is signed, so the sign is restored.
          def eval_table_get(node)
            info = @tables.fetch(node[:name]) do
              raise LoweringError, "read of undefined table #{node[:name].inspect}"
            end
            eval_value(node[:index])                               # r0 = index
            if info[:pow2]
              emit_and_const(ACC, ACC, info[:count] - 1, TMP)      # wrap: index & (count - 1)
            else
              emit_clamp_acc(0, info[:count] - 1)                  # clamp: 0..count-1
            end
            shift = { 1 => 0, 2 => 1, 4 => 2 }.fetch(info[:elem_bytes])
            emit(ASM.lsl_imm(ACC, ACC, shift)) unless shift.zero?  # r0 = index * elem_bytes
            emit_load_data_address(TMP, node[:name])               # r1 = table base
            emit(ASM.add_reg(ADDR, TMP, ACC))                      # r12 = &table[index]
            emit_table_load(info)                                  # r0 = element
          end

          # Load the element at ADDR into the accumulator, picking the load that matches
          # the element width and signedness. The signed loads (ldrsb/ldrsh) sign-extend
          # into the whole register; a word already fills it.
          def emit_table_load(info)
            case [info[:elem_bytes], info[:signed]]
            when [1, false] then emit(ASM.ldrb_offset(ACC, ADDR, 0))
            when [1, true]  then emit(ASM.ldrsb(ACC, ADDR))
            when [2, false] then emit(ASM.load_halfword(ACC, ADDR))
            when [2, true]  then emit(ASM.ldrsh(ACC, ADDR))
            else emit(ASM.ldr(ACC, ADDR))
            end
          end

          # Clamp the accumulator into [low, high] in place — the branch-per-bound way
          # emit_clamp uses for a variable, but on r0.
          def emit_clamp_acc(low, high)
            keep_low = gensym
            emit(ASM.load_immediate(TMP, low))
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, keep_low, cond: :ge)
            emit(ASM.mov_reg(ACC, TMP))
            place_label(keep_low)

            keep_high = gensym
            emit(ASM.load_immediate(TMP, high))
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, keep_high, cond: :le)
            emit(ASM.mov_reg(ACC, TMP))
            place_label(keep_high)
          end

          # Evaluate lhs and rhs, holding lhs on the stack while rhs is computed, then
          # combine. Using the stack for the intermediate keeps arbitrarily nested
          # expressions correct without a register allocator.
          def eval_binop(node)
            eval_value(node[:lhs])
            emit(ASM.push(ACC))
            eval_value(node[:rhs])
            emit(ASM.pop(TMP))             # r1 = lhs, r0 = rhs

            op = node[:op]
            case op
            when :+ then emit(ASM.add_reg(ACC, TMP, ACC))
            when :- then emit(ASM.sub_reg(ACC, TMP, ACC))
            when :* then emit(ASM.mul(ACC, TMP, ACC))
            # Condition composition: both sides are already 0/1, so a bitwise
            # and/or gives the combined 0/1 the branch tests for.
            when :and then emit(ASM.and_reg(ACC, TMP, ACC))
            when :or then emit(ASM.orr_reg(ACC, TMP, ACC))
            when :/ then emit_division
            else emit_comparison(op)
            end
          end

          # Divide through the BIOS Div routine — the ARM7TDMI has no divide
          # instruction, so a division traps into the BIOS. It wants the numerator
          # in r0 and the denominator in r1; after the binop setup r1 already holds
          # lhs (numerator) and r0 holds rhs (denominator), so swap them (via r2)
          # and trap. The quotient comes back in r0, our accumulator — right where
          # an expression's result belongs. (r1 gets the remainder, r3 is clobbered;
          # neither survives a statement here, so that's fine.)
          def emit_division
            emit(ASM.mov_reg(2, ACC))   # r2 = denominator (rhs)
            emit(ASM.mov_reg(ACC, TMP)) # r0 = numerator (lhs)
            emit(ASM.mov_reg(TMP, 2))   # r1 = denominator
            emit(ASM.swi(0x06 << 16))   # BIOS Div: r0 = r0 / r1
          end

          # A comparison yields 1 or 0. Compare, default the result to 0, and set it
          # to 1 only when the comparison holds.
          def emit_comparison(op)
            _true_cond, false_cond = COMPARISONS.fetch(op) do
              raise LoweringError, "unknown operator #{op.inspect}"
            end
            emit(ASM.cmp_reg(TMP, ACC))          # lhs - rhs
            done = gensym
            emit(ASM.load_immediate(ACC, 0))
            emit_branch(:bcond, done, cond: false_cond)
            emit(ASM.load_immediate(ACC, 1))
            place_label(done)
          end

          # `held` reads the key register and tests the button's bit. The register is
          # active-low, so the bit reads 0 while the button is down: TST sets the zero
          # flag exactly then, and we turn that into 1 (held) or 0 (not).
          def eval_held(button)
            mask = BUTTON_BIT.fetch(button) do
              raise LoweringError, "unknown button #{button.inspect}"
            end
            emit(ASM.load_immediate(TMP, REG_KEYINPUT))
            emit(ASM.load_halfword(ACC, TMP))
            emit(ASM.tst_imm(ACC, mask))         # zero flag set => button down
            done = gensym
            emit(ASM.load_immediate(ACC, 0))
            emit_branch(:bcond, done, cond: :ne) # bit not zero => not held => leave 0
            emit(ASM.load_immediate(ACC, 1))
            place_label(done)
          end

          # `pressed` is the down-edge: down this frame, up last frame. The snapshots
          # are active-high, so newly-pressed buttons = CUR_KEYS AND NOT PREV_KEYS;
          # test the button's bit in that.
          def eval_pressed(button)
            mask = BUTTON_BIT.fetch(button) do
              raise LoweringError, "unknown button #{button.inspect}"
            end
            load_var(ACC, CUR_KEYS)
            load_var(TMP, PREV_KEYS)
            emit(ASM.mvn_reg(TMP, TMP))          # ~prev
            emit(ASM.and_reg(ACC, ACC, TMP))     # cur & ~prev = buttons newly down
            emit(ASM.tst_imm(ACC, mask))
            done = gensym
            emit(ASM.load_immediate(ACC, 0))
            emit_branch(:bcond, done, cond: :eq) # bit zero => not a fresh press => 0
            emit(ASM.load_immediate(ACC, 1))
            place_label(done)
          end

          # Start both snapshots empty (no button pressed) before the game runs.
          def emit_input_init
            emit(ASM.load_immediate(ACC, 0))
            store_var(ACC, CUR_KEYS)
            store_var(ACC, PREV_KEYS)
          end

          # Once per frame: shift this frame's "current" into "previous", then latch
          # the live key state as the new "current". The key register is active-low,
          # so invert it and keep the ten button bits to get an active-high set.
          def snapshot_keys
            load_var(ACC, CUR_KEYS)
            store_var(ACC, PREV_KEYS)              # previous = last frame's current
            emit(ASM.load_immediate(TMP, REG_KEYINPUT))
            emit(ASM.load_halfword(ACC, TMP))
            emit(ASM.mvn_reg(ACC, ACC))            # invert: 1 bit now means "down"
            emit(ASM.lsl_imm(ACC, ACC, 22))        # drop everything above the
            emit(ASM.lsr_imm(ACC, ACC, 22))        # ten button bits
            store_var(ACC, CUR_KEYS)               # current = this frame's keys
          end
        end
      end
    end
  end
end
