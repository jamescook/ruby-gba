# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Dividing by a number the game works out, without the console's divide routine.
        #
        # The chip has no divide instruction. A divisor written into the program never
        # needs one — the build turns it into a shift or a multiply (see Reciprocal) —
        # but a divisor the game works out has nothing to precompute, so it has to be
        # divided out as the program runs.
        #
        # The console's own routine does that, and it is slower the bigger the answer is:
        # measured, about 88 cycles plus 11 more for every bit of the answer, so a small
        # answer costs about 100 cycles and a large one about 475. That spread is the
        # real problem. A game cannot budget a frame around an operation whose cost
        # swings five-fold on the numbers it happens to be holding.
        #
        # This does the same long division and keeps the same answers, but each step
        # costs a third as much, so the same work is about 95 cycles plus 4 a bit — a
        # large answer drops from 475 cycles to 219, and the swing across the whole range
        # narrows from five-fold to two.
        #
        # Two things make a step that cheap. The number of steps is found without
        # looping: five compares scale the divisor up under the numerator, halving the
        # search each time, and count how far it moved. And the steps are written out one
        # after another rather than as a loop, with that count used to JUMP INTO the run
        # at the right place — so a small answer runs a few steps and stops, and no step
        # pays for a branch. A step is then just a compare, a subtract that only happens
        # if it fits, and a doubling that slides the compare's yes-or-no into the answer.
        module Divide
          include Constants

          # Room reserved in fast internal memory for each routine, which is copied there
          # at boot. The build fails if one ever outgrows its room.
          DIVIDE_ROUTINE_IWRAM_MAX = 1024
          DIVIDE_FIX_ROUTINE_IWRAM_MAX = 1280

          # The widest answer there is: a 32-bit division can need 32 steps.
          LADDER_STEPS = 32

          # How the scaling search narrows down. Each compare either shifts the divisor
          # up by this much and remembers it, or leaves it alone.
          SCALE_STEPS = [16, 8, 4, 2, 1].freeze

          # The routine's registers. It is called from inside an expression, so it may use
          # every scratch register there is, and it puts its answer where an expression's
          # answer belongs.
          DIV_NUM = 1   # in: the numerator; out: what was left over
          DIV_DEN = 0   # in: the divisor, scaled up as it goes; out: the quotient
          DIV_ANS = 2   # the answer, built one bit at a time
          DIV_COUNT = 3 # how far the divisor was scaled up
          DIV_SIGNS = 12

          # The widened-numerator routine's own registers. It takes a third thing in —
          # how far to widen — and needs two registers for a numerator that no longer
          # fits in one.
          FIX_BITS = 2  # in: how far to widen the numerator
          FIX_WIDE = 3  # the other end of that widening (32 - bits)
          FIX_LOW = 4   # the low half of the widened numerator; then the answer
          FIX_HIGH = 5  # the high half; then what is left over as the division walks

          SIGN_BIT = 1 << 31
          INT32_MAX = (1 << 31) - 1

          # Does this program divide by anything it works out as it runs? A divisor
          # written into the program is handled at build time and needs none of this;
          # 1, -1 and 0 are written down but still come here, which is why they count.
          def needs_divide_routine?(program)
            program.walk.any? do |node|
              case node.kind
              when :binop then %i[/ %].include?(node[:op]) && divisor_needs_routine?(node[:rhs])
              when :div_fix then folds_to_plain_divide?(node) && divisor_needs_routine?(node[:rhs])
              else false
              end
            end
          end

          # And does it divide one number holding a fraction by another? Only the ones
          # that cannot be folded into a plain division count (see #folds_to_plain_divide?).
          def needs_divide_fix_routine?(program)
            program.walk.any? { |node| node.kind == :div_fix && !folds_to_plain_divide?(node) }
          end

          # Whether a division by this operand still has to be worked out as the program
          # runs. Anything else the build has already turned into shifts or a multiply.
          def divisor_needs_routine?(operand)
            divisor = const_int(operand)
            divisor.nil? || divisor.abs <= 1
          end

          # A fraction divide whose numerator is written into the program can be widened
          # at build time — and then it is an ordinary division, with all of that path's
          # own shortcuts available to it. `WALL_HEIGHT / distance` is exactly this
          # shape, and it is the common one. It only works while the widened numerator
          # still fits a register; past that the routine has to do the widening itself.
          #
          # The most negative number is left out even though it fits, because it is the
          # one numerator whose answer can still be too big: divided by -1 it needs one
          # more than a register holds. Everything else divides to something that fits,
          # so the ordinary path's wrapping and this one's holding-at-the-end agree.
          #
          # CostModel::Pricing#div_fix_weight decides the same thing for the estimate; if
          # this moves, that must too.
          def folds_to_plain_divide?(node)
            numerator = const_int(node[:lhs])
            return false unless numerator

            widened = numerator << node[:fraction_bits]
            widened > Int32::MIN && widened <= Int32::MAX
          end

          # Where in internal memory the routines are copied to: the far end of it, out of
          # the way of the variables, which grow from the near end toward them.
          #
          # It matters which end. Variables start at the very beginning of internal
          # memory, and that address is one the chip can name in a single instruction —
          # a rare piece of luck worth keeping, because a program names a variable
          # thousands of times and names a divide routine a handful. Putting a routine
          # there instead pushed every variable past the single-instruction address and
          # cost one game an extra 5,700 bytes of code, all of it in variable reads.
          ROUTINES_TOP = IWRAM_START + IWRAM_SIZE - 0x1000 # below the stack the BIOS uses

          def reserve_divide_routine
            @divide_routine_iwram = ROUTINES_TOP
          end

          def reserve_divide_fix_routine
            @divide_fix_routine_iwram = ROUTINES_TOP + DIVIDE_ROUTINE_IWRAM_MAX
          end

          # The variables grow toward the routines, so a program with a great many of
          # them has to be told rather than quietly overwriting one.
          def guard_variables_clear_of_routines
            return unless @divide_routine_iwram && @next_var > ROUTINES_TOP

            raise LoweringError,
                  "this program uses more internal memory for its variables than there is " \
                  "room for alongside the divide routine"
          end

          # Copy the routine from ROM into fast internal memory once, at boot. Internal
          # memory has no wait states and this chip has no instruction cache to flush, so
          # the copied code simply runs faster. Copies whole words from the routine's
          # start label up to its end.
          def emit_copy_divide_routines_to_iwram
            if @divide_routine_iwram
              copy_routine(:__divide_routine, :__divide_routine_end, @divide_routine_iwram)
            end
            return unless @divide_fix_routine_iwram

            copy_routine(:__divide_fix_routine, :__divide_fix_routine_end,
                         @divide_fix_routine_iwram)
          end

          def copy_routine(from, to, destination)
            emit_load_label_address(0, from) # r0 = the routine, in ROM
            emit_load_label_address(1, to)
            emit(ASM.load_immediate(2, destination))
            copy = gensym
            place_label(copy)
            emit(ASM.ldr(3, 0))
            emit(ASM.str(3, 2))
            emit(ASM.add_imm(0, 0, 4))
            emit(ASM.add_imm(2, 2, 4))
            emit(ASM.cmp_reg(0, 1))
            emit_branch(:bcond, copy, cond: :lt)
          end

          # Call the routine. It takes the numerator in r1 and the divisor in r0, which is
          # exactly where evaluating a two-sided expression already leaves them, so there
          # is nothing to shuffle first. It hands back the quotient in r0 and the leftover
          # in r1.
          #
          # This chip cannot branch-and-link to an address held in a register, so the
          # return address is set by hand — pc reads as two instructions ahead, which is
          # the instruction after the branch — and the jump is a BX. The routine returns
          # with BX LR.
          def emit_call_divide_routine
            emit_call_routine_at(@divide_routine_iwram)
          end

          # Call the widened-numerator routine. Same shape, plus how far to widen in r2.
          # It hands back only a quotient; there is no leftover to speak of, since the
          # numerator it divided was not the one the program wrote.
          def emit_call_divide_fix_routine(bits)
            emit(ASM.load_immediate(FIX_BITS, bits))
            emit_call_routine_at(@divide_fix_routine_iwram)
          end

          def emit_call_routine_at(address)
            emit(ASM.load_immediate(ADDR, address))
            emit(ASM.mov_reg(14, 15)) # lr = where to come back to
            emit(ASM.bx(ADDR))
          end

          # The routine, emitted once into ROM and copied into internal memory at boot. It
          # is position-independent — relative branches, immediates built by hand, no
          # PC-relative loads — so it runs the same wherever it is put.
          def emit_divide_routine
            return unless @divide_routine_iwram

            emit(ASM.loop_forever) # the routine is only ever entered by the call above
            place_label(:__divide_routine)
            start = pos
            by_zero = gensym

            emit(ASM.cmp_imm(DIV_DEN, 0))
            emit_branch(:bcond, by_zero, cond: :eq)

            emit_divide_signs_aside
            emit_divide_ladder
            emit_divide_signs_back
            place_label(by_zero)
            emit_divide_by_zero
            place_label(:__divide_routine_end)
            guard_routine_size("divide", pos - start, DIVIDE_ROUTINE_IWRAM_MAX)
          end

          # The other routine: dividing one number that holds a fraction by another.
          #
          # Two numbers multiplied up by the same amount divide that amount straight back
          # out, so the numerator has to be multiplied up AGAIN before anything is
          # divided — and once it is, it no longer fits in a register (see Int32.div_fix).
          # So this one divides a numerator held across TWO registers, which is why it
          # cannot share the routine above.
          #
          # It is a plain long division of that double-width numerator, thirty-two steps
          # of it, because unlike the routine above there is no cheap way to know in
          # advance how many of them matter. A step walks the numerator along one place
          # (the two halves shift together, the bit falling out of the low one carried
          # into the high one) and takes the divisor out of the top if it fits, and the
          # bit that frees up at the bottom is where the answer accumulates.
          #
          #   in:  r1 = the numerator, r0 = the divisor, r2 = how far to widen (0..32)
          #   out: r0 = the answer
          def emit_divide_fix_routine
            return unless @divide_fix_routine_iwram

            emit(ASM.loop_forever) # the routine is only ever entered by the call above
            place_label(:__divide_fix_routine)
            start = pos
            by_zero = gensym
            too_big = gensym

            emit(ASM.cmp_imm(DIV_DEN, 0))
            emit_branch(:bcond, by_zero, cond: :eq)

            emit(ASM.eor_reg(DIV_SIGNS, DIV_NUM, DIV_DEN)) # bit 31 = the answer's sign
            emit(ASM.cmp_imm(DIV_NUM, 0))
            emit(ASM.rsb_imm_cond(:lt, DIV_NUM, DIV_NUM, 0))
            emit(ASM.cmp_imm(DIV_DEN, 0))
            emit(ASM.rsb_imm_cond(:lt, DIV_DEN, DIV_DEN, 0))

            # Widen the numerator across two registers. The shift is held in a register
            # rather than written into the instruction, which is what lets it be a whole
            # word: widening by 32 leaves nothing in the low half and the number itself
            # in the high one, and widening by nothing does the reverse.
            emit(ASM.rsb_imm(FIX_WIDE, FIX_BITS, 32))
            emit(ASM.mov_reg_lsl_reg(FIX_LOW, DIV_NUM, FIX_BITS))
            emit(ASM.mov_reg_lsr_reg(FIX_HIGH, DIV_NUM, FIX_WIDE))

            # If the top half already reaches the divisor, the answer is wider than a
            # number can hold before a single step has run.
            emit(ASM.cmp_reg(FIX_HIGH, DIV_DEN))
            emit_branch(:bcond, too_big, cond: :hs)

            LADDER_STEPS.times do
              emit(ASM.adds_reg(FIX_LOW, FIX_LOW, FIX_LOW))   # walk the numerator along...
              emit(ASM.adcs_reg(FIX_HIGH, FIX_HIGH, FIX_HIGH)) # ...carrying between halves
              emit(ASM.sub_reg_cond(:hs, FIX_HIGH, FIX_HIGH, DIV_DEN)) # past a whole word: it fits
              emit(ASM.orr_imm_cond(:hs, FIX_LOW, FIX_LOW, 1))
              emit(ASM.cmp_reg(FIX_HIGH, DIV_DEN))            # otherwise ask outright
              emit(ASM.sub_reg_cond(:hs, FIX_HIGH, FIX_HIGH, DIV_DEN))
              emit(ASM.orr_imm_cond(:hs, FIX_LOW, FIX_LOW, 1))
            end

            # The answer is built without a sign, so its top bit being set means it has
            # outgrown a signed number.
            emit(ASM.cmp_imm(FIX_LOW, 0))
            emit_branch(:bcond, too_big, cond: :lt)
            emit(ASM.mov_reg(DIV_DEN, FIX_LOW))
            emit(ASM.cmp_imm(DIV_SIGNS, 0))
            emit(ASM.rsb_imm_cond(:lt, DIV_DEN, DIV_DEN, 0))
            emit(ASM.return)

            place_label(too_big)
            emit_divide_fix_saturate
            place_label(by_zero)
            emit_divide_by_zero
            place_label(:__divide_fix_routine_end)
            guard_routine_size("fraction divide", pos - start, DIVIDE_FIX_ROUTINE_IWRAM_MAX)
          end

          private

          # An answer with no room left is held at the end of the range rather than
          # wrapped (see Int32.div_fix for why that is the useful wrong answer).
          def emit_divide_fix_saturate
            emit(ASM.mvn_imm(DIV_DEN, SIGN_BIT))               # the largest there is
            emit(ASM.cmp_imm(DIV_SIGNS, 0))
            emit(ASM.mov_imm_cond(:lt, DIV_DEN, SIGN_BIT))     # or the smallest
            emit(ASM.return)
          end

          # Divide sizes and put the signs back afterwards, because long division has no
          # notion of a negative number. Two facts have to survive: the quotient is
          # negative when the two signs differ (one exclusive-or the other, top bit), and
          # the leftover follows the numerator. Both are packed into one register — the
          # numerator's sign where it already sits, the quotient's in the bottom bit —
          # rather than stacked, so nothing touches memory.
          def emit_divide_signs_aside
            emit(ASM.and_imm(DIV_SIGNS, DIV_NUM, SIGN_BIT))
            emit(ASM.eor_reg(DIV_COUNT, DIV_NUM, DIV_DEN))
            emit(ASM.orr_reg_lsr(DIV_SIGNS, DIV_SIGNS, DIV_COUNT, 31))
            emit(ASM.cmp_imm(DIV_NUM, 0))
            emit(ASM.rsb_imm_cond(:lt, DIV_NUM, DIV_NUM, 0))
            emit(ASM.cmp_imm(DIV_DEN, 0))
            emit(ASM.rsb_imm_cond(:lt, DIV_DEN, DIV_DEN, 0))
          end

          # Scale the divisor up under the numerator, then run that many division steps.
          #
          # The scaling is a search, not a loop: "is the divisor at most a 65536th of the
          # numerator?" shifts it up 16 places if so, then the same question about 256,
          # 16, 4 and 2. Five compares settle it whatever the numbers are, and the count
          # of how far it moved is one less than the number of steps the answer needs.
          # Entering the written-out run of steps that far from its end runs exactly that
          # many of them.
          def emit_divide_ladder
            emit(ASM.load_immediate(DIV_ANS, 0))
            emit(ASM.load_immediate(DIV_COUNT, 0))
            SCALE_STEPS.each do |step|
              emit(ASM.cmp_reg_lsr(DIV_DEN, DIV_NUM, step))
              emit(ASM.mov_reg_lsl_cond(:ls, DIV_DEN, DIV_DEN, step))
              emit(ASM.add_imm_cond(:ls, DIV_COUNT, DIV_COUNT, step))
            end

            emit(ASM.rsb_imm(DIV_COUNT, DIV_COUNT, LADDER_STEPS - 1)) # steps to skip
            emit(ASM.add_pc_reg_lsl(DIV_COUNT, 4))                   # four instructions each
            emit(ASM.nop)                                            # pc reads two ahead
            LADDER_STEPS.times do
              emit(ASM.cmp_reg(DIV_NUM, DIV_DEN))                    # does the divisor fit?
              emit(ASM.sub_reg_cond(:hs, DIV_NUM, DIV_NUM, DIV_DEN)) # take it out when it does
              emit(ASM.adc_reg(DIV_ANS, DIV_ANS, DIV_ANS))           # double, sliding that in
              emit(ASM.lsr_imm(DIV_DEN, DIV_DEN, 1))                 # halve it for the next place
            end
          end

          # Put the signs back and leave the answers where a caller expects them: the
          # quotient in r0, the leftover in r1 (where it already is).
          def emit_divide_signs_back
            emit(ASM.mov_reg(DIV_DEN, DIV_ANS))
            emit(ASM.tst_imm(DIV_SIGNS, 1))
            emit(ASM.rsb_imm_cond(:ne, DIV_DEN, DIV_DEN, 0)) # the two signs differed
            emit(ASM.cmp_imm(DIV_SIGNS, 0))
            emit(ASM.rsb_imm_cond(:lt, DIV_NUM, DIV_NUM, 0)) # the numerator was negative
            emit(ASM.return)
          end

          # Dividing by zero has no answer, and this gives back what the console's own
          # routine gave: 1 or -1 following the numerator's sign, with the numerator
          # itself left over. A program that does this has a fault in it either way; what
          # matters is that it behaves as it always did and does not hang.
          def emit_divide_by_zero
            emit(ASM.load_immediate(DIV_DEN, 1))
            emit(ASM.cmp_imm(DIV_NUM, 0))
            emit(ASM.rsb_imm_cond(:lt, DIV_DEN, DIV_DEN, 0))
            emit(ASM.return)
          end

          def guard_routine_size(what, size, room)
            return unless size > room

            raise LoweringError,
                  "the #{what} routine is #{size} bytes but only #{room} are reserved in " \
                  "internal memory"
          end
        end
      end
    end
  end
end
