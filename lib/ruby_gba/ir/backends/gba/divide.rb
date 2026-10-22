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
        class Divide
          include Console::Hardware

          # What each routine comes to, in bytes, and so the room {TopOfQuickMemory} holds for it in
          # the quick memory, where it is copied at boot. Each is the same code in every game, so
          # these are counts of what it is, not guesses; the build stops (see
          # #refuse_oversized_routine!) if a change ever makes one bigger.
          ROUTINE_BYTES = 668
          FIX_ROUTINE_BYTES = 556

          # What the two routines are called. This chip cannot divide, so every division in a
          # program goes through one of them — which makes them routines a measured profile has
          # to be able to name, and the name has to be settled in one place for the report to
          # say it without keeping a second copy (see Messages::PlainWords::ROUTINES).
          ROUTINE = :__divide_routine
          FIX_ROUTINE = :__divide_fix_routine

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
          # Once the numerator is widened, the registers that brought it in are free again.
          FIX_NEG_DEN = DIV_NUM # minus the divisor, which a step adds to take it out
          FIX_SKIP = FIX_BITS   # how far into the written-out steps to jump, in bytes
          # What is left over once the steps have run. A divide made whole reads it after the
          # routine returns, with minus the divisor still in FIX_NEG_DEN; both mean something
          # only when the routine neither divided by nought nor ran out of room.
          FIX_LEFT_OVER = FIX_HIGH

          # Where a divide made whole settles its rounding, once the routine has returned and
          # these are free again.
          WHOLE_LIMIT = FIX_WIDE
          WHOLE_TEST = FIX_LOW
          WHOLE_SPARE = FIX_BITS

          # How many fraction bits a divide made whole can drop: the rounding's own sums stay
          # inside a register from two to thirty, and the half added needs at least one below it.
          WHOLE_DROPS = (2..30)

          # How many places at a time the fraction divide asks whether it can skip, and what
          # one of its steps comes to in bytes (three instructions).
          FIX_SKIPS = [16, 8].freeze
          FIX_STEP_BYTES = 12

          SIGN_BIT = 1 << 31
          INT32_MAX = (1 << 31) - 1

          # +scales_objects+ answers, for one :object node, whether it needs a divide —
          # the one thing #needs_divide_routine? asks about that isn't its own to know
          # (a sprite's own size is core object/sprite layout, not division).
          def initialize(emitter:, memory:, primitives:, scales_objects:)
            @emitter = emitter
            @memory = memory
            @primitives = primitives
            @scales_objects = scales_objects
            @divide_routine_iwram = nil
            @divide_fix_routine_iwram = nil
          end

          # Does this program divide by anything it works out as it runs? A divisor
          # written into the program is handled at build time and needs none of this;
          # 1, -1 and 0 are written down but still come here, which is why they count.
          #
          # A sprite that changes size counts too, even though the program never wrote a
          # division: drawing at a size means dividing BY it, and the framework does that
          # for the author every frame (see SpriteDrawing#emit_object_scale_reciprocal).
          def needs_divide_routine?(program)
            program.walk.any? do |node|
              case node.kind
              when :binop then %i[/ %].include?(node.op) && divisor_needs_routine?(node.rhs)
              when :div_fix then folds_to_plain_divide?(node) && divisor_needs_routine?(node.rhs)
              when :object then @scales_objects.call(node)
              # A stretched column divides the picture's height by the height asked for, and
              # that height is only known as the game runs.
              when :draw_column_at then true
              # An affine background always works out one over its current size (see
              # BackgroundDrawing#emit_bg_affine_scale_reciprocal), even the frame it only turns —
              # rotate and scale share one pair of variables, so there's no "never resizes"
              # case to skip the divide the way a sprite's does.
              when :affine_background then true
              else false
              end
            end
          end

          # And does it divide one number holding a fraction by another? Only the ones
          # that cannot be folded into a plain division count (see #folds_to_plain_divide?).
          def needs_divide_fix_routine?(program)
            program.walk.any? { |node| node.kind == :div_fix && !folds_to_plain_divide?(node) }
          end

          # Whether a division by this divisor still has to be worked out as the program
          # runs. Anything else the build has already turned into shifts or a multiply.
          # +divisor+ is the number written into the program, or nil where the game works
          # one out. 1, -1 and 0 are written down and still come here.
          #
          # A class method because the estimate asks it too — it prices the three tiers of
          # divide apart and this is what puts a division in the dearest one.
          def self.needs_routine?(divisor)
            divisor.nil? || divisor.abs <= 1
          end

          def divisor_needs_routine?(operand)
            Divide.needs_routine?(@primitives.const_int(operand))
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
          # A class method for the same reason #needs_routine? is one: the estimate prices
          # the folded case as an ordinary division and has to make the same call.
          # +numerator+ is nil where the game works it out.
          def self.folds_to_plain_divide?(numerator, fraction_bits)
            return false unless numerator

            widened = numerator << fraction_bits
            widened > Int32::MIN && widened <= Int32::MAX
          end

          def folds_to_plain_divide?(node)
            Divide.folds_to_plain_divide?(@primitives.const_int(node.lhs), node.fraction_bits)
          end

          # Each routine's place in the quick memory, which {TopOfQuickMemory} keeps for it.
          def reserve_divide_routine(at:)
            @divide_routine_iwram = at
          end

          def reserve_divide_fix_routine(at:)
            @divide_fix_routine_iwram = at
          end

          # WHERE THE DIVIDE ROUTINES RUN, for a profile of the finished game to report against.
          #
          # These are not routines anybody wrote, and they are not among the ones the build
          # chooses to keep in the quick memory either — they are copied there unconditionally,
          # above everything else, because this chip cannot divide and every division in the
          # program comes here. So nothing else in the build knows their spans, and without
          # them a profile files every division under "somewhere we have no name for": measured
          # on examples/raycaster.rb that is a sixth of the frame, and on examples/breakout.rb a
          # fifth. Named, it is the most useful line in the report, because a hot divide is
          # something an author can act on — a table instead of a sum.
          #
          # Each is copied whole from its start label to its end label, so its length in the
          # cartridge is its length up there.
          def divide_routine_addresses
            { ROUTINE => @divide_routine_iwram,
              FIX_ROUTINE => @divide_fix_routine_iwram }.filter_map do |name, base|
              next unless base

              size = @emitter.labels.fetch(:"#{name}_end") - @emitter.labels.fetch(name)
              [name, base...(base + size)]
            end.to_h
          end

          # The variables grow up from the base and the lists and buffers grow down from
          # the routines, so a program with a great many of either has to be told rather
          # than quietly overwriting the other.
          def refuse_variables_overlapping_divide!
            return unless @divide_routine_iwram && @memory.overrun.positive?

            raise LoweringError,
                  "this program uses more internal memory for its variables than there is " \
                  "room for alongside the divide routine"
          end

          # Copy the routine from ROM into fast internal memory once, at boot. Internal
          # memory has no wait states and this chip has no instruction cache to flush, so
          # the copied code simply runs faster. Copies whole words from the routine's
          # start label up to its end. A no-op when neither routine was reserved.
          def emit_copy_divide_routines_to_iwram
            if @divide_routine_iwram
              copy_routine(:__divide_routine, :__divide_routine_end, @divide_routine_iwram)
            end
            return unless @divide_fix_routine_iwram

            copy_routine(:__divide_fix_routine, :__divide_fix_routine_end,
                         @divide_fix_routine_iwram)
          end

          def copy_routine(from, to, destination)
            @emitter.emit_load_label_address(0, from) # r0 = the routine, in ROM
            @emitter.emit_load_label_address(1, to)
            @emitter.emit(ASM.load_immediate(2, destination))
            copy = @emitter.gensym
            @emitter.place_label(copy)
            @emitter.emit(ASM.ldr(3, 0))
            @emitter.emit(ASM.str(3, 2))
            @emitter.emit(ASM.add_imm(0, 0, 4))
            @emitter.emit(ASM.add_imm(2, 2, 4))
            @emitter.emit(ASM.cmp_reg(0, 1))
            @emitter.emit_branch(:bcond, copy, cond: :lt)
          end

          # Call the routine. It takes the numerator in r1 and the divisor in r0, which is
          # exactly where evaluating a two-sided expression already leaves them, so there
          # is nothing to shuffle first. It hands back the quotient in r0 and the leftover
          # in r1. The routine lives in the quick memory, too far for a relative branch, so
          # the call goes through a register — see Emit#emit_call_through.
          def emit_call_divide_routine
            emit_call_routine_at(@divide_routine_iwram)
          end

          # Call the widened-numerator routine. Same shape, plus how far to widen in r2.
          # It hands back the quotient. What it leaves over is not the program's leftover,
          # since the numerator it divided was not the one the program wrote, but a divide
          # made whole reads it (see #emit_call_divide_fix_whole).
          def emit_call_divide_fix_routine(bits)
            @emitter.emit(ASM.load_immediate(FIX_BITS, bits))
            emit_call_routine_at(@divide_fix_routine_iwram)
          end

          # A FRACTION DIVIDE MADE WHOLE STRAIGHT AWAY, `(a / b).to_i` or `(a / b + 0.5).to_i`,
          # wants only the answer's whole part, so the routine is asked to widen the numerator
          # by +drop+ fewer places and its answer comes out whole: an answer a little over a
          # hundred runs eight steps rather than twenty-four.
          #
          # What the fraction bits it did not work out would have decided is then settled from
          # what was left over, because the answer has to be the one the whole fraction divide
          # gives once it is made whole, to the bit (see Int32.div_fix and Int32.shift_right),
          # and in three places that is not a whole-number divide's:
          #
          # - Making whole rounds DOWN and the divide rounds toward nought, so a negative answer
          #   with anything in its fraction is one further down. "Anything in its fraction"
          #   means anything in the bits the divide would have kept, not anything left over
          #   at all: -1/65536 over 3 comes to nought in sixteen fraction bits and stays it.
          #   The fraction is something exactly when the leftover is more than the divisor's
          #   own top bits, the divisor moved down +drop+ places.
          # - An answer with no room is held at the end of the range before it is made whole,
          #   so it comes out as the biggest or smallest whole number the fraction could
          #   hold, and the half added to the biggest wraps it to the smallest.
          # - Dividing by nought gives a bare 1 or -1, which made whole is 0 or -1, and 0 with
          #   the half. That is settled here before the routine is called.
          #
          #   in:  r1 = the numerator, r0 = the divisor
          #   out: r0 = the whole part
          def emit_call_divide_fix_whole(widen:, drop:, rounding:)
            by_zero = @emitter.gensym
            done = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(DIV_DEN, 0))
            @emitter.emit_branch(:bcond, by_zero, cond: :eq)
            emit_call_divide_fix_routine(widen)
            rounding == :nearest ? emit_whole_part_to_nearest(drop, done) : emit_whole_part_down(drop, done)
            @emitter.emit_branch(:b, done)

            @emitter.place_label(by_zero)
            if rounding == :nearest
              @emitter.emit(ASM.load_immediate(DIV_DEN, 0))
            else
              @emitter.emit(ASM.asr_imm(DIV_DEN, DIV_NUM, 31)) # -1 for a numerator below nought
            end
            @emitter.place_label(done)
          end

          def emit_call_routine_at(address)
            @emitter.emit_number(ADDR, address)
            @emitter.emit_call_through(ADDR)
          end

          # The routine, emitted once into ROM and copied into internal memory at boot. It
          # is position-independent — relative branches, every number built an instruction
          # at a time, nothing read from a table beside it — so it runs the same wherever
          # it is put. A routine of the game's that goes into the same memory DOES keep
          # such a table (see NumberTable), and can, because its table is copied with it.
          # This one is copied by its own two labels, so it has to hold all it reads.
          def emit_divide_routine
            return unless @divide_routine_iwram

            @emitter.refuse_open_number_table!("The divide routine")
            @emitter.emit(ASM.loop_forever) # the routine is only ever entered by the call above
            @emitter.place_label(:__divide_routine)
            start = @emitter.pos
            by_zero = @emitter.gensym

            @emitter.emit(ASM.cmp_imm(DIV_DEN, 0))
            @emitter.emit_branch(:bcond, by_zero, cond: :eq)

            emit_divide_strip_signs
            emit_divide_ladder
            emit_divide_restore_signs
            @emitter.place_label(by_zero)
            emit_divide_by_zero
            @emitter.place_label(:__divide_routine_end)
            refuse_oversized_routine!("divide", @emitter.pos - start, ROUTINE_BYTES)
          end

          # The other routine: dividing one number that holds a fraction by another.
          #
          # Two numbers multiplied up by the same amount divide that amount straight back
          # out, so the numerator has to be multiplied up AGAIN before anything is
          # divided — and once it is, it no longer fits in a register (see Int32.div_fix).
          # So this one divides a numerator held across TWO registers, which is why it
          # cannot share the routine above.
          #
          # It is a long division of that double-width numerator, at most thirty-two steps
          # of it. A step walks the numerator along one place, the bit falling out of the low
          # half carried into the high one, and takes the divisor out of the high half if it
          # fits; the place that frees up at the bottom of the low half is where the answer
          # collects, a bit a step.
          #
          # A STEP IS THREE INSTRUCTIONS, because the routine keeps the divisor NEGATED. Adding
          # minus the divisor is taking it out, and the carry an add leaves is set exactly when
          # the divisor fitted, so one add-with-carry doubles the high half, takes in the bit
          # carried up from the low one AND tries the divisor, and the carry it leaves is the
          # answer's next bit. When the divisor did not fit, one subtract puts it back. That
          # carry then rides into the next step's doubling of the low half, which is how it
          # lands in the answer, so the answer's last bit needs one more doubling after the run.
          # The high half never outgrows a register on the way: it stays below the divisor,
          # and the divisor is at most half of what a register counts to.
          #
          # STEPS THAT CAN ONLY GIVE NOUGHT ARE NOT RUN. A numerator less than the divisor
          # times 2**16 has nothing in the answer's top sixteen bits, so the routine asks that
          # first, and when it is, walks the numerator along sixteen places at once and enters
          # the written-out run sixteen steps in. Then the same for eight. An answer with a
          # fraction of sixteen bits and a whole part under 256 runs twenty-four steps, one
          # below one runs sixteen, and a bigger one all thirty-two.
          #
          # Asking for four as well was weighed and left out: the six instructions it takes
          # save twelve only when the answer is that small, which a fraction rarely is.
          #
          #   in:  r1 = the numerator, r0 = the divisor, r2 = how far to widen (0..32)
          #   out: r0 = the answer; r5 = what was left over and r1 = minus the divisor, when
          #        it neither divided by nought nor ran out of room
          def emit_divide_fix_routine
            return unless @divide_fix_routine_iwram

            @emitter.refuse_open_number_table!("The routine that divides fractions")
            @emitter.emit(ASM.loop_forever) # the routine is only ever entered by the call above
            @emitter.place_label(:__divide_fix_routine)
            start = @emitter.pos
            by_zero = @emitter.gensym
            too_big = @emitter.gensym

            @emitter.emit(ASM.cmp_imm(DIV_DEN, 0))
            @emitter.emit_branch(:bcond, by_zero, cond: :eq)

            @emitter.emit(ASM.eor_reg(DIV_SIGNS, DIV_NUM, DIV_DEN)) # bit 31 = the answer's sign
            @emitter.emit(ASM.cmp_imm(DIV_NUM, 0))
            @emitter.emit(ASM.rsb_imm_cond(:lt, DIV_NUM, DIV_NUM, 0))
            @emitter.emit(ASM.cmp_imm(DIV_DEN, 0))
            @emitter.emit(ASM.rsb_imm_cond(:lt, DIV_DEN, DIV_DEN, 0))

            # Widen the numerator across two registers. The shift is held in a register
            # rather than written into the instruction, which is what lets it be a whole
            # word: widening by 32 leaves nothing in the low half and the number itself
            # in the high one, and widening by nothing does the reverse.
            @emitter.emit(ASM.rsb_imm(FIX_WIDE, FIX_BITS, 32))
            @emitter.emit(ASM.mov_reg_lsl_reg(FIX_LOW, DIV_NUM, FIX_BITS))
            @emitter.emit(ASM.mov_reg_lsr_reg(FIX_HIGH, DIV_NUM, FIX_WIDE))

            # If the top half already reaches the divisor, the answer is wider than a
            # number can hold before a single step has run.
            @emitter.emit(ASM.cmp_reg(FIX_HIGH, DIV_DEN))
            @emitter.emit_branch(:bcond, too_big, cond: :hs)

            emit_divide_fix_skip_search
            # Negating the divisor also clears the carry, since it is not nought, so the bit the
            # first step slides into the answer is nought too: it would otherwise land just above
            # the answer when steps were skipped.
            @emitter.emit(ASM.rsbs_imm(FIX_NEG_DEN, DIV_DEN, 0))
            @emitter.emit(ASM.add_pc_reg_lsl(FIX_SKIP, 0)) # in past the skipped steps
            @emitter.emit(ASM.nop)                         # pc reads two ahead
            run_starts = @emitter.pos
            LADDER_STEPS.times do
              @emitter.emit(ASM.adcs_reg(FIX_LOW, FIX_LOW, FIX_LOW))                  # answer bit in, numerator bit out
              @emitter.emit(ASM.adcs_reg_lsl(FIX_HIGH, FIX_NEG_DEN, FIX_HIGH, 1))      # take it in, try the divisor
              @emitter.emit(ASM.sub_reg_cond(:lo, FIX_HIGH, FIX_HIGH, FIX_NEG_DEN))    # it did not fit: put it back
            end
            refuse_misjumping_steps!(@emitter.pos - run_starts)
            @emitter.emit(ASM.adc_reg(FIX_LOW, FIX_LOW, FIX_LOW)) # the last step's answer bit

            # The answer is built without a sign, so its top bit being set means it has
            # outgrown a signed number.
            @emitter.emit(ASM.cmp_imm(FIX_LOW, 0))
            @emitter.emit_branch(:bcond, too_big, cond: :lt)
            @emitter.emit(ASM.mov_reg(DIV_DEN, FIX_LOW))
            @emitter.emit(ASM.cmp_imm(DIV_SIGNS, 0))
            @emitter.emit(ASM.rsb_imm_cond(:lt, DIV_DEN, DIV_DEN, 0))
            @emitter.emit(ASM.return)

            @emitter.place_label(too_big)
            emit_divide_fix_saturate
            @emitter.place_label(by_zero)
            emit_divide_by_zero
            @emitter.place_label(:__divide_fix_routine_end)
            refuse_oversized_routine!("fraction divide", @emitter.pos - start, FIX_ROUTINE_BYTES)
          end

          private

          # How many of the run's steps to skip, as how far into it to jump: for each of
          # FIX_SKIPS, when the numerator is below the divisor times 2**(32 - places), the
          # answer's next that-many bits are nought, so the numerator walks along that far now.
          #
          # That product is twice a register wide too — its high half is the divisor moved down
          # that many places, its low half the divisor moved up the rest of the way — so the
          # question is two compares: the high halves, and only where those are equal, the low
          # ones. The divisor's low bits matter exactly there, which is why a divisor below one,
          # whose high half is nought, still skips as far as any other.
          def emit_divide_fix_skip_search
            @emitter.emit(ASM.load_immediate(FIX_SKIP, 0))
            FIX_SKIPS.each do |places|
              @emitter.emit(ASM.cmp_reg_lsr(FIX_HIGH, DIV_DEN, places))
              @emitter.emit(ASM.cmp_reg_lsl_cond(:eq, FIX_LOW, DIV_DEN, 32 - places))
              @emitter.emit(ASM.mov_reg_lsl_cond(:lo, FIX_HIGH, FIX_HIGH, places))
              @emitter.emit(ASM.orr_reg_lsr_cond(:lo, FIX_HIGH, FIX_HIGH, FIX_LOW, 32 - places))
              @emitter.emit(ASM.mov_reg_lsl_cond(:lo, FIX_LOW, FIX_LOW, places))
              @emitter.emit(ASM.add_imm_cond(:lo, FIX_SKIP, FIX_SKIP, places * FIX_STEP_BYTES))
            end
          end

          # Round a whole part down. The routine's answer in r0 was rounded toward nought, which
          # for a positive answer is down already, unless it is past the biggest whole number
          # the fraction holds. A negative one is one further down when its fraction was anything.
          def emit_whole_part_down(drop, done)
            @emitter.emit_number(WHOLE_LIMIT, (1 << (Int32::BITS - 1 - drop)) - 1)
            @emitter.emit(ASM.cmp_reg(DIV_DEN, WHOLE_LIMIT))
            @emitter.emit(ASM.mov_reg_cond(:gt, DIV_DEN, WHOLE_LIMIT))   # no room: the biggest
            @emitter.emit(ASM.cmp_imm(DIV_SIGNS, 0))
            @emitter.emit_branch(:bcond, done, cond: :ge)

            @emitter.emit(ASM.mvn_reg(WHOLE_LIMIT, WHOLE_LIMIT))         # the smallest
            @emitter.emit(ASM.cmp_reg(DIV_DEN, WHOLE_LIMIT))
            @emitter.emit(ASM.mov_reg_cond(:le, DIV_DEN, WHOLE_LIMIT))
            @emitter.emit_branch(:bcond, done, cond: :le)
            @emitter.emit(ASM.mvn_reg(WHOLE_TEST, FIX_NEG_DEN))          # the divisor less one...
            @emitter.emit(ASM.lsr_imm(WHOLE_TEST, WHOLE_TEST, drop))     # ...moved down
            @emitter.emit(ASM.cmp_reg(WHOLE_TEST, FIX_LEFT_OVER))
            @emitter.emit(ASM.sub_imm_cond(:lo, DIV_DEN, DIV_DEN, 1))     # the fraction was something
          end

          # Round a whole part to the nearest, a half going up on either side of nought. A
          # positive answer goes up when at least half the divisor was left over, and one that
          # reaches past the biggest whole number wraps to the smallest, the way adding the half
          # to a number held at the top of the range does. A negative one goes further down only
          # when its fraction was more than a half by anything the fraction's bits would have
          # kept: the leftover past half the divisor by more than the divisor's top bits.
          def emit_whole_part_to_nearest(drop, done)
            negative = @emitter.gensym
            held = @emitter.gensym
            @emitter.emit_number(WHOLE_LIMIT, 1 << (Int32::BITS - 1 - drop))  # one past the biggest
            @emitter.emit(ASM.rsb_imm(FIX_NEG_DEN, FIX_NEG_DEN, 0))           # the divisor
            @emitter.emit(ASM.sub_reg(WHOLE_TEST, FIX_NEG_DEN, FIX_LEFT_OVER)) # what the leftover is short of it
            @emitter.emit(ASM.cmp_imm(DIV_SIGNS, 0))
            @emitter.emit_branch(:bcond, negative, cond: :lt)

            @emitter.emit(ASM.cmp_reg(DIV_DEN, WHOLE_LIMIT))
            @emitter.emit_branch(:bcond, held, cond: :ge)
            @emitter.emit(ASM.cmp_reg(FIX_LEFT_OVER, WHOLE_TEST))             # at least half left over
            @emitter.emit(ASM.add_imm_cond(:hs, DIV_DEN, DIV_DEN, 1))
            @emitter.emit(ASM.cmp_reg(DIV_DEN, WHOLE_LIMIT))
            @emitter.emit(ASM.rsb_imm_cond(:eq, DIV_DEN, DIV_DEN, 0))         # one past the biggest wraps
            @emitter.emit_branch(:b, done)
            @emitter.place_label(held)
            @emitter.emit(ASM.rsb_imm(DIV_DEN, WHOLE_LIMIT, 0))               # held at the top, then wrapped
            @emitter.emit_branch(:b, done)

            @emitter.place_label(negative)
            @emitter.emit(ASM.rsb_imm(WHOLE_LIMIT, WHOLE_LIMIT, 0))           # the smallest
            @emitter.emit(ASM.cmp_reg(DIV_DEN, WHOLE_LIMIT))
            @emitter.emit(ASM.mov_reg_cond(:le, DIV_DEN, WHOLE_LIMIT))
            @emitter.emit_branch(:bcond, done, cond: :le)
            @emitter.emit(ASM.sub_imm(WHOLE_SPARE, FIX_NEG_DEN, 1))
            @emitter.emit(ASM.add_reg_lsr(WHOLE_TEST, WHOLE_TEST, WHOLE_SPARE, drop - 1))
            @emitter.emit(ASM.cmp_reg(WHOLE_TEST, FIX_LEFT_OVER))
            @emitter.emit(ASM.sub_imm_cond(:lo, DIV_DEN, DIV_DEN, 1))
          end

          # An answer with no room left is held at the end of the range rather than
          # wrapped (see Int32.div_fix for why that is the useful wrong answer).
          def emit_divide_fix_saturate
            @emitter.emit(ASM.mvn_imm(DIV_DEN, SIGN_BIT))               # the largest there is
            @emitter.emit(ASM.cmp_imm(DIV_SIGNS, 0))
            @emitter.emit(ASM.mov_imm_cond(:lt, DIV_DEN, SIGN_BIT))     # or the smallest
            @emitter.emit(ASM.return)
          end

          # Divide sizes and put the signs back afterwards, because long division has no
          # notion of a negative number. Two facts have to survive: the quotient is
          # negative when the two signs differ (one exclusive-or the other, top bit), and
          # the leftover follows the numerator. Both are packed into one register — the
          # numerator's sign where it already sits, the quotient's in the bottom bit —
          # rather than stacked, so nothing touches memory.
          def emit_divide_strip_signs
            @emitter.emit(ASM.and_imm(DIV_SIGNS, DIV_NUM, SIGN_BIT))
            @emitter.emit(ASM.eor_reg(DIV_COUNT, DIV_NUM, DIV_DEN))
            @emitter.emit(ASM.orr_reg_lsr(DIV_SIGNS, DIV_SIGNS, DIV_COUNT, 31))
            @emitter.emit(ASM.cmp_imm(DIV_NUM, 0))
            @emitter.emit(ASM.rsb_imm_cond(:lt, DIV_NUM, DIV_NUM, 0))
            @emitter.emit(ASM.cmp_imm(DIV_DEN, 0))
            @emitter.emit(ASM.rsb_imm_cond(:lt, DIV_DEN, DIV_DEN, 0))
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
            @emitter.emit(ASM.load_immediate(DIV_ANS, 0))
            @emitter.emit(ASM.load_immediate(DIV_COUNT, 0))
            SCALE_STEPS.each do |step|
              @emitter.emit(ASM.cmp_reg_lsr(DIV_DEN, DIV_NUM, step))
              @emitter.emit(ASM.mov_reg_lsl_cond(:ls, DIV_DEN, DIV_DEN, step))
              @emitter.emit(ASM.add_imm_cond(:ls, DIV_COUNT, DIV_COUNT, step))
            end

            @emitter.emit(ASM.rsb_imm(DIV_COUNT, DIV_COUNT, LADDER_STEPS - 1)) # steps to skip
            @emitter.emit(ASM.add_pc_reg_lsl(DIV_COUNT, 4))                   # four instructions each
            @emitter.emit(ASM.nop)                                            # pc reads two ahead
            LADDER_STEPS.times do
              @emitter.emit(ASM.cmp_reg(DIV_NUM, DIV_DEN))                    # does the divisor fit?
              @emitter.emit(ASM.sub_reg_cond(:hs, DIV_NUM, DIV_NUM, DIV_DEN)) # take it out when it does
              @emitter.emit(ASM.adc_reg(DIV_ANS, DIV_ANS, DIV_ANS))           # double, sliding that in
              @emitter.emit(ASM.lsr_imm(DIV_DEN, DIV_DEN, 1))                 # halve it for the next place
            end
          end

          # Put the signs back and leave the answers where a caller expects them: the
          # quotient in r0, the leftover in r1 (where it already is).
          def emit_divide_restore_signs
            @emitter.emit(ASM.mov_reg(DIV_DEN, DIV_ANS))
            @emitter.emit(ASM.tst_imm(DIV_SIGNS, 1))
            @emitter.emit(ASM.rsb_imm_cond(:ne, DIV_DEN, DIV_DEN, 0)) # the two signs differed
            @emitter.emit(ASM.cmp_imm(DIV_SIGNS, 0))
            @emitter.emit(ASM.rsb_imm_cond(:lt, DIV_NUM, DIV_NUM, 0)) # the numerator was negative
            @emitter.emit(ASM.return)
          end

          # Dividing by zero has no answer, and this gives back what the console's own
          # routine gave: 1 or -1 following the numerator's sign, with the numerator
          # itself left over. A program that does this has a fault in it either way; what
          # matters is that it behaves as it always did and does not hang. That answer is
          # the one every backend gives (see Int32.quotient_by_zero), so it is not this
          # routine's to change.
          def emit_divide_by_zero
            @emitter.emit(ASM.load_immediate(DIV_DEN, 1))
            @emitter.emit(ASM.cmp_imm(DIV_NUM, 0))
            @emitter.emit(ASM.rsb_imm_cond(:lt, DIV_DEN, DIV_DEN, 0))
            @emitter.emit(ASM.return)
          end

          # The jump into the fraction divide's steps counts in FIX_STEP_BYTES, so a step that
          # grew by an instruction would land the jump in the middle of one. Stop the build
          # rather than divide wrongly.
          def refuse_misjumping_steps!(run_bytes)
            return if run_bytes == LADDER_STEPS * FIX_STEP_BYTES

            raise LoweringError,
                  "the fraction divide's steps come to #{run_bytes} bytes, but its jump into them " \
                  "counts #{FIX_STEP_BYTES} bytes a step"
          end

          def refuse_oversized_routine!(what, size, room)
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
