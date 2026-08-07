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

          # Room reserved in fast internal memory for the routine, which is copied there
          # at boot. The build fails if the routine ever outgrows it.
          DIVIDE_ROUTINE_IWRAM_MAX = 1024

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

          SIGN_BIT = 1 << 31

          # Does this program divide by anything it works out as it runs? A divisor
          # written into the program is handled at build time and needs none of this;
          # 1, -1 and 0 are written down but still come here, which is why they count.
          def needs_divide_routine?(program)
            program.walk.any? do |node|
              next false unless node.kind == :binop && %i[/ %].include?(node[:op])

              divisor = const_int(node[:rhs])
              divisor.nil? || divisor.abs <= 1
            end
          end

          # Reserve the internal memory the routine is copied into, before anything else
          # is given a home there. That puts it at the very start of internal memory,
          # whose address happens to be one the chip can name in a single instruction —
          # which is worth a little because every division names it.
          def reserve_divide_routine
            @divide_routine_iwram = @next_var
            @next_var += DIVIDE_ROUTINE_IWRAM_MAX
          end

          # Copy the routine from ROM into fast internal memory once, at boot. Internal
          # memory has no wait states and this chip has no instruction cache to flush, so
          # the copied code simply runs faster. Copies whole words from the routine's
          # start label up to its end.
          def emit_copy_divide_routine_to_iwram
            emit_load_label_address(0, :__divide_routine)     # r0 = the routine, in ROM
            emit_load_label_address(1, :__divide_routine_end)
            emit(ASM.load_immediate(2, @divide_routine_iwram))
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
            emit(ASM.load_immediate(ADDR, @divide_routine_iwram))
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
            guard_divide_routine_size(pos - start)
          end

          private

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

          def guard_divide_routine_size(size)
            return unless size > DIVIDE_ROUTINE_IWRAM_MAX

            raise LoweringError,
                  "the divide routine is #{size} bytes but only #{DIVIDE_ROUTINE_IWRAM_MAX} are " \
                  "reserved in internal memory (raise DIVIDE_ROUTINE_IWRAM_MAX)"
          end
        end
      end
    end
  end
end
