# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Evaluating value nodes (arithmetic, comparisons, data, input reads).
        class Expressions
          include Constants

          def initialize(emitter:, primitives:, lowering:, divide:, tables:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @divide = divide
            @tables = tables
          end

          def eval_int(node) = @emitter.emit(ASM.load_immediate(ACC, Int32.wrap(node.value)))
          def eval_var_ref(node) = @primitives.load_var(ACC, node.name)

          def eval_neg(node)
            @lowering.value(node.operand)
            @emitter.emit(ASM.rsb_imm(ACC, ACC, 0))
          end

          # A chance is "the random draw is below the threshold" — evaluate it as
          # exactly that comparison.
          def eval_chance(node) = @lowering.value(Build.binop(:<, node.draw, Build.int(node.percent)))
          def eval_held_node(node) = eval_held(node.button)
          def eval_pressed_node(node) = eval_pressed(node.button)

          # Read VCOUNT — the scanline being drawn right now (0..227) — into the
          # accumulator. A halfword load straight from the display's scanline register.
          def eval_read_scanline(_node = nil)
            @emitter.emit(ASM.load_immediate(TMP, REG_VCOUNT))
            @emitter.emit(ASM.load_halfword(ACC, TMP))
          end

          # Read one byte of a named blob: point the address register at the blob,
          # then load the byte at its fixed index into the accumulator.
          def eval_data_byte(node)
            @emitter.emit_load_data_address(ADDR, node.name)
            @emitter.emit(ASM.ldrb_offset(ACC, ADDR, node.index))
          end

          # Read table[index] into the accumulator: evaluate the index, make it safe
          # (wrap a power-of-two table with a mask, clamp any other size), scale it to a
          # byte offset, add the table's base address, and load the element — with a
          # signed load when the table is signed, so the sign is restored.
          def eval_table_get(node)
            info = @tables.fetch(node.name) do
              raise LoweringError, "read of undefined table #{node.name.inspect}"
            end
            @lowering.value(node.index)                               # r0 = index
            if info.pow2
              @primitives.emit_and_const(ACC, ACC, info.count - 1, TMP) # wrap: index & (count - 1)
            else
              emit_clamp_acc(0, info.count - 1)                    # clamp: 0..count-1
            end
            shift = { 1 => 0, 2 => 1, 4 => 2 }.fetch(info.elem_bytes)
            @emitter.emit(ASM.lsl_imm(ACC, ACC, shift)) unless shift.zero?  # r0 = index * elem_bytes
            @emitter.emit_load_data_address(TMP, node.name)               # r1 = table base
            @emitter.emit(ASM.add_reg(ADDR, TMP, ACC))                      # r12 = &table[index]
            emit_table_load(info)                                  # r0 = element
          end

          # Load the element at ADDR into the accumulator, picking the load that matches
          # the element width and signedness. The signed loads (ldrsb/ldrsh) sign-extend
          # into the whole register; a word already fills it.
          def emit_table_load(info)
            case [info.elem_bytes, info.signed]
            when [1, false] then @emitter.emit(ASM.ldrb_offset(ACC, ADDR, 0))
            when [1, true]  then @emitter.emit(ASM.ldrsb(ACC, ADDR))
            when [2, false] then @emitter.emit(ASM.load_halfword(ACC, ADDR))
            when [2, true]  then @emitter.emit(ASM.ldrsh(ACC, ADDR))
            else @emitter.emit(ASM.ldr(ACC, ADDR))
            end
          end

          # Clamp the accumulator into [low, high] in place — the branch-per-bound way
          # emit_clamp uses for a variable, but on r0.
          def emit_clamp_acc(low, high)
            keep_low = @emitter.gensym
            @emitter.emit(ASM.load_immediate(TMP, low))
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, keep_low, cond: :ge)
            @emitter.emit(ASM.mov_reg(ACC, TMP))
            @emitter.place_label(keep_low)

            keep_high = @emitter.gensym
            @emitter.emit(ASM.load_immediate(TMP, high))
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, keep_high, cond: :le)
            @emitter.emit(ASM.mov_reg(ACC, TMP))
            @emitter.place_label(keep_high)
          end

          # Evaluate lhs and rhs, holding lhs on the stack while rhs is computed, then
          # combine. Using the stack for the intermediate keeps arbitrarily nested
          # expressions correct without a register allocator.
          def eval_binop(node)
            node = number_on_the_right(node)
            return if emit_constant_binop(node)

            @lowering.value(node.lhs)
            @emitter.emit(ASM.push(ACC))
            @lowering.value(node.rhs)
            @emitter.emit(ASM.pop(TMP))             # r1 = lhs, r0 = rhs

            op = node.op
            case op
            when :+ then @emitter.emit(ASM.add_reg(ACC, TMP, ACC))
            when :- then @emitter.emit(ASM.sub_reg(ACC, TMP, ACC))
            when :* then @emitter.emit(ASM.mul(ACC, TMP, ACC))
            # Condition composition: both sides are already 0/1, so a bitwise
            # and/or gives the combined 0/1 the branch tests for.
            when :and then @emitter.emit(ASM.and_reg(ACC, TMP, ACC))
            when :or then @emitter.emit(ASM.orr_reg(ACC, TMP, ACC))
            # The program's own bit operations. The chip does each in one
            # instruction, which is why reading packed data costs what it reads.
            when :& then @emitter.emit(ASM.and_reg(ACC, TMP, ACC))
            when :| then @emitter.emit(ASM.orr_reg(ACC, TMP, ACC))
            when :^ then @emitter.emit(ASM.eor_reg(ACC, TMP, ACC))
            when :<< then emit_shift_by_value(:left)
            when :>> then emit_shift_by_value(:right)
            when :/ then emit_division
            when :% then emit_modulo
            else emit_comparison(op)
            end
          end

          # Shift by a count the game works out. r1 holds the number, r0 the count.
          #
          # The chip shifts by a register directly, and its own rule for a big count is
          # nearly the one the IR promises: it reads the LOW BYTE of the count, so 32 or
          # more empties the number, and a negative count — whose low byte is a large
          # number — empties it too. Nearly, because a count of exactly 256 has a low
          # byte of zero and would shift by nothing at all.
          #
          # Comparing UNSIGNED settles both ends in one stroke. Every count outside
          # 0...32, negative ones included, reads as huge that way and is pinned at 32,
          # which is the count that empties the number. Two instructions, no branch.
          def emit_shift_by_value(direction)
            @emitter.emit(ASM.cmp_imm(ACC, Int32::BITS))
            @emitter.emit(ASM.mov_imm_cond(:hs, ACC, Int32::BITS))
            @emitter.emit(if direction == :left
                            ASM.mov_reg_lsl_reg(ACC, TMP, ACC)
                          else
                            ASM.mov_reg_asr_reg(ACC, TMP, ACC) # down, keeping the sign
                          end)
          end

          # Every bit of a number the other way round — one instruction, which is why
          # this is its own node rather than an exclusive-or with all ones.
          def eval_bit_not(node)
            @lowering.value(node.operand)
            @emitter.emit(ASM.mvn_reg(ACC, ACC))
          end

          # An operation against a number written into the program — the cases the
          # backend can settle at build time instead of leaving to the console. Returns
          # true when it handled the node, false when the general path has to.
          #
          # This is a lowering trick, not an IR one: the tree still says divide, and a
          # backend that would rather not do any of this is free to ignore it. Nothing
          # the author writes mentions a shift or a reciprocal, which is the point — the
          # speed comes from the compiler, not from asking a Ruby programmer to think in
          # bits.
          def emit_constant_binop(node)
            value = @primitives.const_int(node.rhs)
            return false unless value

            case node.op
            when :/ then emit_constant_divide(node.lhs, value)
            when :* then emit_constant_multiply(node.lhs, value)
            when :% then emit_constant_modulo(node.lhs, value)
            when :&, :|, :^ then emit_constant_bitwise(node.lhs, value, node.op)
            when :<< then emit_constant_shift_left(node.lhs, value)
            when :>> then emit_constant_shift_right(node.lhs, value)
            else false
            end
          end

          # `&`, `|` and `^` give the same answer whichever way round they are written,
          # so a number written into the program is moved to the RIGHT, where the
          # constant path below can see it. `0x0F & flags` is a shape people write —
          # Ruby lets a number stand on the left of these three — and this is what makes
          # it cost what `flags & 0x0F` costs instead of putting both sides through the
          # stack. Nothing else here is turned round: dividing and shifting mean
          # different things the other way about.
          COMMUTES = %i[& | ^].freeze

          def number_on_the_right(node)
            return node unless COMMUTES.include?(node.op)
            return node if @primitives.const_int(node.lhs).nil? || @primitives.const_int(node.rhs)

            Build.binop(node.op, node.rhs, node.lhs)
          end

          # A mask, an or, or an exclusive-or against a number written into the program
          # — which is nearly every one a game writes, since the shape of packed data is
          # settled long before the game runs.
          #
          # The number rides inside the instruction when it is small enough and is
          # loaded into a register first when it is not: one instruction or two, against
          # the five the general path spends putting both sides through the stack.
          def emit_constant_bitwise(lhs, value, op)
            @lowering.value(lhs)
            if (0..0xFF).cover?(value)
              @emitter.emit(case op
                            when :& then ASM.and_imm(ACC, ACC, value)
                            when :| then ASM.orr_imm(ACC, ACC, value)
                            else ASM.eor_imm(ACC, ACC, value)
                            end)
            else
              @emitter.emit(ASM.load_immediate(TMP, value))
              @emitter.emit(case op
                            when :& then ASM.and_reg(ACC, ACC, TMP)
                            when :| then ASM.orr_reg(ACC, ACC, TMP)
                            else ASM.eor_reg(ACC, ACC, TMP)
                            end)
            end
            true
          end

          # x << n for an n written into the program: ONE instruction, and none at all
          # for a shift of nothing. A count that empties the number is settled here
          # rather than emitted — going up there is nothing left, so nothing is what
          # gets loaded.
          def emit_constant_shift_left(lhs, count)
            @lowering.value(lhs)
            if Int32.shifts_within_the_number?(count)
              @emitter.emit(ASM.lsl_imm(ACC, ACC, count)) if count.positive?
            else
              @emitter.emit(ASM.load_immediate(ACC, 0))
            end
            true
          end

          # x >> n, likewise one instruction. Going off the end downward leaves the sign
          # filling the whole register, and a shift by 31 is exactly that — 0 for a
          # number that was positive, -1 for one that was negative — so even the count
          # nobody meant to write costs the same single instruction.
          def emit_constant_shift_right(lhs, count)
            @lowering.value(lhs)
            places = Int32.shifts_within_the_number?(count) ? count : Int32::BITS - 1
            @emitter.emit(ASM.asr_imm(ACC, ACC, places)) if places.positive?
            true
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
              @emitter.emit(ASM.rsb_imm(ACC, ACC, 0))
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
            @lowering.value(lhs)
            @emitter.emit(ASM.asr_imm(TMP, ACC, 31))                  # r1 = -1 when negative, else 0
            @emitter.emit(ASM.add_reg_lsr(ACC, ACC, TMP, 32 - bits))  # + (2**bits - 1) when negative
            @emitter.emit(ASM.asr_imm(ACC, ACC, bits))
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
            @lowering.value(lhs)
            @emitter.emit(ASM.mov_reg(SPARE, ACC))                      # r2 = the numerator, kept
            @emitter.emit(ASM.load_immediate(TMP, recipe.multiplier))
            @emitter.emit(ASM.smull(ACC, HIGH, TMP, SPARE))             # r3:r0 = multiplier * numerator
            @emitter.emit(ASM.add_reg(HIGH, HIGH, SPARE)) if recipe.add_numerator
            @emitter.emit(ASM.asr_imm(HIGH, HIGH, recipe.shift)) if recipe.shift.positive?
            @emitter.emit(ASM.add_reg_lsr(ACC, HIGH, HIGH, 31))         # toward zero, not toward minus infinity
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
            @lowering.value(lhs)
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
            @emitter.emit(ASM.load_immediate(TMP, size))
            @emitter.emit(ASM.mul(HIGH, ACC, TMP))         # r3 = quotient * size
            @emitter.emit(ASM.sub_reg(ACC, SPARE, HIGH))   # r0 = numerator - that = the leftover
            @emitter.emit(ASM.asr_imm(SPARE, ACC, 31))     # r2 = -1 when the leftover is negative
            @emitter.emit(ASM.and_reg(SPARE, SPARE, TMP))  # r2 = one size, but only then
            @emitter.emit(ASM.add_reg(ACC, ACC, SPARE))
          end

          # Turn a wrap onto 0...size into a wrap onto -size...0, which is what Ruby's `%`
          # gives for a negative divisor. Every answer but zero moves down by one size;
          # zero stays zero, which is the only reason this needs a branch at all.
          def emit_flip_wrap_negative(size)
            @emitter.emit(ASM.load_immediate(TMP, size))
            done = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, done, cond: :eq)
            @emitter.emit(ASM.sub_reg(ACC, ACC, TMP))
            @emitter.place_label(done)
          end

          # x * 2**bits — one instruction, and exact: the low 32 bits of the product are
          # what a multiply would have left anyway.
          def emit_multiply_by_power_of_two(lhs, bits)
            @lowering.value(lhs)
            @emitter.emit(ASM.lsl_imm(ACC, ACC, bits))
            true
          end

          # AND a register with a mask, loading the mask first when it is too big to ride
          # along inside the instruction (anything past 8 bits).
          def emit_and_mask(reg, mask)
            if mask <= 0xFF
              @emitter.emit(ASM.and_imm(reg, reg, mask))
            else
              @emitter.emit(ASM.load_immediate(TMP, mask))
              @emitter.emit(ASM.and_reg(reg, reg, TMP))
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
            @lowering.value(node.lhs)
            @emitter.emit(ASM.push(ACC))
            @lowering.value(node.rhs)
            @emitter.emit(ASM.pop(TMP))                        # r1 = lhs, r0 = rhs
            @emitter.emit(ASM.smull(SPARE, HIGH, ACC, TMP))    # r3:r2 = lhs * rhs, all 64 bits of it

            case node.fraction_bits
            when 0 then @emitter.emit(ASM.mov_reg(ACC, SPARE)) # nothing to shift off — the low word is the answer
            when 32 then @emitter.emit(ASM.mov_reg(ACC, HIGH)) # shifted right by a whole word — the high one is
            else
              bits = node.fraction_bits
              @emitter.emit(ASM.lsr_imm(ACC, SPARE, bits))                  # r0 = the low word, shifted down
              @emitter.emit(ASM.orr_reg_lsl(ACC, ACC, HIGH, 32 - bits))     # + the high word's bits sliding in
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
            numerator = @primitives.const_int(node.lhs)
            if @divide.folds_to_plain_divide?(node)
              return eval_binop(Build.binop(:/, Build.int(numerator << node.fraction_bits),
                                            node.rhs))
            end

            @lowering.value(node.lhs)
            @emitter.emit(ASM.push(ACC))
            @lowering.value(node.rhs)
            @emitter.emit(ASM.pop(TMP)) # r1 = the numerator, r0 = the divisor
            @divide.emit_call_divide_fix_routine(node.fraction_bits)
          end

          # Divide by a power of two, rounding down (see IR::Int32.shift_right).
          #
          # This is where that operation earns its own node. The chip has no divide
          # instruction at all — an ordinary `/` traps into a BIOS routine — but
          # dropping the low bits of a register is a shift, and ARM does a shift as part
          # of moving the register. So the whole thing is ONE instruction, against a
          # call for the division that would otherwise be written here.
          def eval_shift_right(node)
            @lowering.value(node.operand)
            bits = node.bits
            @emitter.emit(ASM.asr_imm(ACC, ACC, bits)) if bits.positive? # shifting by none is nothing to do
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
            @divide.emit_call_divide_routine # r0 = lhs / rhs, r1 = what is left over
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
            @emitter.emit(ASM.push(ACC))                  # the divisor, needed once the answer is back
            @divide.emit_call_divide_routine
            @emitter.emit(ASM.mov_reg(ACC, TMP))          # r0 = the leftover, signed like the numerator
            @emitter.emit(ASM.pop(SPARE))                 # r2 = the divisor again

            done = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, done, cond: :eq) # nothing left over: no signs to disagree
            @emitter.emit(ASM.eor_reg(HIGH, ACC, SPARE))  # do the two signs differ?
            @emitter.emit(ASM.cmp_imm(HIGH, 0))
            @emitter.emit_branch(:bcond, done, cond: :ge)
            @emitter.emit(ASM.add_reg(ACC, ACC, SPARE))
            @emitter.place_label(done)
          end

          # A comparison yields 1 or 0. Compare, default the result to 0, and set it
          # to 1 only when the comparison holds.
          def emit_comparison(op)
            _true_cond, false_cond = COMPARISONS.fetch(op) do
              raise LoweringError, "unknown operator #{op.inspect}"
            end
            @emitter.emit(ASM.cmp_reg(TMP, ACC))          # lhs - rhs
            done = @emitter.gensym
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @emitter.emit_branch(:bcond, done, cond: false_cond)
            @emitter.emit(ASM.load_immediate(ACC, 1))
            @emitter.place_label(done)
          end

          # `held` reads the key register and tests the button's bit. The register is
          # active-low, so the bit reads 0 while the button is down: TST sets the zero
          # flag exactly then, and we turn that into 1 (held) or 0 (not).
          def eval_held(button)
            mask = BUTTON_BIT.fetch(button) do
              raise LoweringError, "unknown button #{button.inspect}"
            end
            @emitter.emit(ASM.load_immediate(TMP, REG_KEYINPUT))
            @emitter.emit(ASM.load_halfword(ACC, TMP))
            @emitter.emit(ASM.tst_imm(ACC, mask))         # zero flag set => button down
            done = @emitter.gensym
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @emitter.emit_branch(:bcond, done, cond: :ne) # bit not zero => not held => leave 0
            @emitter.emit(ASM.load_immediate(ACC, 1))
            @emitter.place_label(done)
          end

          # `pressed` is the down-edge: down this frame, up last frame. The snapshots
          # are active-high, so newly-pressed buttons = CUR_KEYS AND NOT PREV_KEYS;
          # test the button's bit in that.
          def eval_pressed(button)
            mask = BUTTON_BIT.fetch(button) do
              raise LoweringError, "unknown button #{button.inspect}"
            end
            @primitives.load_var(ACC, CUR_KEYS)
            @primitives.load_var(TMP, PREV_KEYS)
            @emitter.emit(ASM.mvn_reg(TMP, TMP))          # ~prev
            @emitter.emit(ASM.and_reg(ACC, ACC, TMP))     # cur & ~prev = buttons newly down
            @emitter.emit(ASM.tst_imm(ACC, mask))
            done = @emitter.gensym
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @emitter.emit_branch(:bcond, done, cond: :eq) # bit zero => not a fresh press => 0
            @emitter.emit(ASM.load_immediate(ACC, 1))
            @emitter.place_label(done)
          end

          # Start both snapshots empty (no button pressed) before the game runs.
          def emit_input_init
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, CUR_KEYS)
            @primitives.store_var(ACC, PREV_KEYS)
          end

          # Once per frame: shift this frame's "current" into "previous", then latch
          # the live key state as the new "current". The key register is active-low,
          # so invert it and keep the ten button bits to get an active-high set.
          def snapshot_keys
            @primitives.load_var(ACC, CUR_KEYS)
            @primitives.store_var(ACC, PREV_KEYS)              # previous = last frame's current
            @emitter.emit(ASM.load_immediate(TMP, REG_KEYINPUT))
            @emitter.emit(ASM.load_halfword(ACC, TMP))
            @emitter.emit(ASM.mvn_reg(ACC, ACC))            # invert: 1 bit now means "down"
            @emitter.emit(ASM.lsl_imm(ACC, ACC, 22))        # drop everything above the
            @emitter.emit(ASM.lsr_imm(ACC, ACC, 22))        # ten button bits
            @primitives.store_var(ACC, CUR_KEYS)               # current = this frame's keys
          end
        end
      end
    end
  end
end
