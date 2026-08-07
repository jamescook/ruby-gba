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
            when :mul_fix then eval_mul_fix(node)
            when :div_fix then eval_div_fix(node)
            when :shift_right then eval_shift_right(node)
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
            return if emit_constant_binop(node)

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
            when :% then emit_modulo
            else emit_comparison(op)
            end
          end

          # Dividing, multiplying or wrapping by a number written into the program — the
          # cases the backend can settle at build time instead of leaving to the console.
          # Returns true when it handled the node, false when the general path has to.
          #
          # This is a lowering trick, not an IR one: the tree still says divide, and a
          # backend that would rather not do any of this is free to ignore it. Nothing
          # the author writes mentions a shift or a reciprocal, which is the point — the
          # speed comes from the compiler, not from asking a Ruby programmer to think in
          # bits.
          def emit_constant_binop(node)
            value = const_int(node[:rhs])
            return false unless value

            case node[:op]
            when :/ then emit_constant_divide(node[:lhs], value)
            when :* then emit_constant_multiply(node[:lhs], value)
            when :% then emit_constant_modulo(node[:lhs], value)
            else false
            end
          end

          # How many bits +value+ is a power of two of, or nil if it isn't one. Only
          # positive powers: 1 has nothing to shift, and a negative number is turned
          # positive before it gets here.
          def power_of_two_bits(value)
            return nil unless value.positive? && (value & (value - 1)).zero? && value > 1

            Math.log2(value).to_i
          end

          # x / d for a d written into the program. A power of two is a shift; a negative
          # divisor is the same division with the answer flipped (truncation is symmetric
          # about zero, so flipping after is the same as dividing by the negative); and
          # anything else multiplies by a reciprocal worked out at build time. Only 1, -1
          # and 0 are left to the console's divide routine — the first two have nothing
          # to gain and the third has to fail the way it always did.
          def emit_constant_divide(lhs, divisor)
            return false if divisor.abs <= 1

            if divisor.negative?
              emit_constant_divide(lhs, divisor.abs)
              emit(ASM.rsb_imm(ACC, ACC, 0))
              return true
            end

            bits = power_of_two_bits(divisor)
            return emit_divide_by_power_of_two(lhs, bits) if bits

            emit_reciprocal_divide(lhs, divisor)
          end

          # x * d — a power of two is a shift, and anything else is already a single
          # multiply instruction, so there is nothing to improve on.
          def emit_constant_multiply(lhs, factor)
            bits = power_of_two_bits(factor)
            return false unless bits

            emit_multiply_by_power_of_two(lhs, bits)
          end

          # x / 2**bits, TRUNCATING TOWARD ZERO — the meaning `/` has everywhere else
          # here, and what the console's BIOS divide would have given.
          #
          # A plain arithmetic shift is not that. It rounds toward minus infinity, so
          # -7 >> 2 is -2 where -7 / 4 is -1. The fix is to nudge a negative numerator up
          # by one less than the divisor before shifting, and the sign of the number is
          # itself available as a shift: shifting right by 31 leaves all ones for a
          # negative and all zeros for anything else. Three instructions, no branch, and
          # no call.
          def emit_divide_by_power_of_two(lhs, bits)
            eval_value(lhs)
            emit(ASM.asr_imm(TMP, ACC, 31))                  # r1 = -1 when negative, else 0
            emit(ASM.add_reg_lsr(ACC, ACC, TMP, 32 - bits))  # + (2**bits - 1) when negative
            emit(ASM.asr_imm(ACC, ACC, bits))
            true
          end

          # x / d by multiplying instead of dividing (see Reciprocal for how the
          # multiplier is found).
          #
          # SMULL multiplies two 32-bit numbers and keeps the whole 64-bit product across
          # a register pair. Multiplying by a number close to 2**k/d and keeping only the
          # high word is a division by 2**32 for free — the low word is simply not read —
          # so what is left is to shift the high word down the rest of the way.
          #
          # The last instruction is the truncation. The shift has rounded toward minus
          # infinity, and `/` rounds toward zero, so a negative answer is one too low:
          # adding its own top bit (0 for a positive answer, 1 for a negative one) puts it
          # right. The numerator stays in r2 the whole way, because it is needed again
          # both for the correction some divisors want and by the wrap below.
          def emit_reciprocal_divide(lhs, divisor)
            recipe = Reciprocal.for(divisor)
            eval_value(lhs)
            emit(ASM.mov_reg(SPARE, ACC))                      # r2 = the numerator, kept
            emit(ASM.load_immediate(TMP, recipe.multiplier))
            emit(ASM.smull(ACC, HIGH, TMP, SPARE))             # r3:r0 = multiplier * numerator
            emit(ASM.add_reg(HIGH, HIGH, SPARE)) if recipe.add_numerator
            emit(ASM.asr_imm(HIGH, HIGH, recipe.shift)) if recipe.shift.positive?
            emit(ASM.add_reg_lsr(ACC, HIGH, HIGH, 31))         # toward zero, not toward minus infinity
            true
          end

          # x % d for a d written into the program, with Ruby's meaning (see
          # IR::Int32.mod): the answer takes the sign of the divisor, so it lands in
          # 0...d for a positive d and in -d...0 for a negative one.
          def emit_constant_modulo(lhs, divisor)
            size = divisor.abs
            return false if size <= 1

            bits = power_of_two_bits(size)
            bits ? emit_wrap_to_power_of_two(lhs, bits) : emit_reciprocal_modulo(lhs, size)
            emit_flip_wrap_negative(size) if divisor.negative?
            true
          end

          # x % 2**bits, with Ruby's meaning. Keeping the low bits of a two's-complement
          # number IS that answer for a positive power of two, sign and all: -1 keeps all
          # its low bits and comes out as the range's top value.
          def emit_wrap_to_power_of_two(lhs, bits)
            eval_value(lhs)
            emit_and_mask(ACC, (1 << bits) - 1)
            true
          end

          # What is left over after dividing by a size written into the program.
          #
          # There is no leftover to collect here — the reciprocal divide never computes
          # one — so it is worked back out: the quotient times the size, taken off the
          # numerator that r2 still holds. That answer carries the sign of the NUMERATOR
          # and Ruby's carries the sign of the divisor, so one size is added back when the
          # numerator was negative. The number's own top bit says whether it was, which
          # makes the correction three instructions and no branch.
          def emit_reciprocal_modulo(lhs, size)
            emit_reciprocal_divide(lhs, size)
            emit(ASM.load_immediate(TMP, size))
            emit(ASM.mul(HIGH, ACC, TMP))         # r3 = quotient * size
            emit(ASM.sub_reg(ACC, SPARE, HIGH))   # r0 = numerator - that = the leftover
            emit(ASM.asr_imm(SPARE, ACC, 31))     # r2 = -1 when the leftover is negative
            emit(ASM.and_reg(SPARE, SPARE, TMP))  # r2 = one size, but only then
            emit(ASM.add_reg(ACC, ACC, SPARE))
          end

          # Turn a wrap onto 0...size into a wrap onto -size...0, which is what Ruby's `%`
          # gives for a negative divisor. Every answer but zero moves down by one size;
          # zero stays zero, which is the only reason this needs a branch at all.
          def emit_flip_wrap_negative(size)
            emit(ASM.load_immediate(TMP, size))
            done = gensym
            emit(ASM.cmp_imm(ACC, 0))
            emit_branch(:bcond, done, cond: :eq)
            emit(ASM.sub_reg(ACC, ACC, TMP))
            place_label(done)
          end

          # x * 2**bits — one instruction, and exact: the low 32 bits of the product are
          # what a multiply would have left anyway.
          def emit_multiply_by_power_of_two(lhs, bits)
            eval_value(lhs)
            emit(ASM.lsl_imm(ACC, ACC, bits))
            true
          end

          # AND a register with a mask, loading the mask first when it is too big to ride
          # along inside the instruction (anything past 8 bits).
          def emit_and_mask(reg, mask)
            if mask <= 0xFF
              emit(ASM.and_imm(reg, reg, mask))
            else
              emit(ASM.load_immediate(TMP, mask))
              emit(ASM.and_reg(reg, reg, TMP))
            end
          end

          # Multiply two numbers carrying the same fraction bits, forming the product
          # at full width so it can't overflow on the way (see IR::Int32.mul_fix).
          #
          # The chip has the instruction for this: SMULL gives the whole 64-bit answer
          # across a pair of registers, where plain MUL keeps only the low half. What's
          # left is to shift that 64-bit value right by the fraction bits and keep the
          # low 32 — which is two more instructions, because ARM can fold a shift into
          # an ORR for free: take the low word shifted down, then OR in the bits that
          # fall out of the bottom of the high word. No software helper, no loop.
          #
          # r2/r3 take the product (they're scratch inside an expression), leaving the
          # answer in the accumulator like every other value.
          def eval_mul_fix(node)
            eval_value(node[:lhs])
            emit(ASM.push(ACC))
            eval_value(node[:rhs])
            emit(ASM.pop(TMP))                        # r1 = lhs, r0 = rhs
            emit(ASM.smull(SPARE, HIGH, ACC, TMP))    # r3:r2 = lhs * rhs, all 64 bits of it

            case node[:fraction_bits]
            when 0 then emit(ASM.mov_reg(ACC, SPARE)) # nothing to shift off — the low word is the answer
            when 32 then emit(ASM.mov_reg(ACC, HIGH)) # shifted right by a whole word — the high one is
            else
              bits = node[:fraction_bits]
              emit(ASM.lsr_imm(ACC, SPARE, bits))                  # r0 = the low word, shifted down
              emit(ASM.orr_reg_lsl(ACC, ACC, HIGH, 32 - bits))     # + the high word's bits sliding in
            end
          end

          # Divide one number holding a fraction by another (see IR::Int32.div_fix).
          #
          # When the numerator is written into the program it can be widened at build
          # time, and then this is an ordinary division — which is the shape a wall
          # height or a scale factor usually has, and it keeps all of that path's own
          # shortcuts. Otherwise the widening has to happen as the program runs, across
          # two registers, which is what the second routine is for.
          def eval_div_fix(node)
            numerator = const_int(node[:lhs])
            if folds_to_plain_divide?(node)
              return eval_binop(Build.binop(:/, Build.int(numerator << node[:fraction_bits]),
                                            node[:rhs]))
            end

            eval_value(node[:lhs])
            emit(ASM.push(ACC))
            eval_value(node[:rhs])
            emit(ASM.pop(TMP)) # r1 = the numerator, r0 = the divisor
            emit_call_divide_fix_routine(node[:fraction_bits])
          end

          # Divide by a power of two, rounding down (see IR::Int32.shift_right).
          #
          # This is where that operation earns its own node. The chip has no divide
          # instruction at all — an ordinary `/` traps into a BIOS routine — but
          # dropping the low bits of a register is a shift, and ARM does a shift as part
          # of moving the register. So the whole thing is ONE instruction, against a
          # call for the division that would otherwise be written here.
          def eval_shift_right(node)
            eval_value(node[:operand])
            bits = node[:bits]
            emit(ASM.asr_imm(ACC, ACC, bits)) if bits.positive? # shifting by none is nothing to do
          end

          # Divide by a value the game works out — the only division left that has to be
          # done as the program runs, since a divisor written into the program has had
          # its reciprocal found at build time.
          #
          # It goes to the shared routine (see Divide), which takes the numerator in r1
          # and the divisor in r0 — exactly where evaluating the two sides has already
          # left them, so there is nothing to shuffle. The quotient comes back in r0, our
          # accumulator, right where an expression's result belongs; the leftover in r1.
          def emit_division
            emit_call_divide_routine # r0 = lhs / rhs, r1 = what is left over
          end

          # What is left over after dividing by a size the game works out.
          #
          # The routine hands the leftover back in r1 alongside the quotient, so the
          # division itself costs nothing extra here. But it gives that leftover the sign
          # of the NUMERATOR, and Ruby's answer takes the sign of the divisor (see
          # IR::Int32.mod). When the two disagree — and only then — one divisor has to be
          # added back. Nothing here knows which sign the divisor has, so the two are
          # compared; where the size IS written into the program that is settled at build
          # time instead. The divisor waits on the stack, since the routine is free to
          # use every scratch register.
          def emit_modulo
            emit(ASM.push(ACC))                  # the divisor, needed once the answer is back
            emit_call_divide_routine
            emit(ASM.mov_reg(ACC, TMP))          # r0 = the leftover, signed like the numerator
            emit(ASM.pop(SPARE))                 # r2 = the divisor again

            done = gensym
            emit(ASM.cmp_imm(ACC, 0))
            emit_branch(:bcond, done, cond: :eq) # nothing left over: no signs to disagree
            emit(ASM.eor_reg(HIGH, ACC, SPARE))  # do the two signs differ?
            emit(ASM.cmp_imm(HIGH, 0))
            emit_branch(:bcond, done, cond: :ge)
            emit(ASM.add_reg(ACC, ACC, SPARE))
            place_label(done)
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
