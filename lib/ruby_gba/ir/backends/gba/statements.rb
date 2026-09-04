# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Statement lowering: variable ops and control flow.
        class Statements
          include Constants

          def initialize(emitter:, primitives:, lowering:, placement:, functions:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @placement = placement
            @functions = functions
            @loop_shapes = {}
          end

          # Which shape each loop got (register/spilled/memory), keyed by its index —
          # read by GBA#loop_shapes for the cost estimate.
          attr_reader :loop_shapes

          def emit_set(node)
            @lowering.value(node.value)
            @primitives.store_var(ACC, node.var)
          end

          # add/sub: new value = var (op) operand. Evaluate the operand into the
          # accumulator, load the variable alongside it, combine, store back.
          def emit_accumulate(node, op)
            @lowering.value(node.operand)       # r0 = operand
            @primitives.load_var(TMP, node.var)        # r1 = current value
            @emitter.emit(ASM.send(op, ACC, TMP, ACC)) # r0 = r1 (op) r0
            @primitives.store_var(ACC, node.var)
          end

          def emit_add(node) = emit_accumulate(node, :add_reg)
          def emit_sub(node) = emit_accumulate(node, :sub_reg)

          def emit_copy(node)
            @primitives.load_var(ACC, node.src)
            @primitives.store_var(ACC, node.dest)
          end

          def emit_negate(node)
            @primitives.load_var(ACC, node.var)
            @emitter.emit(ASM.rsb_imm(ACC, ACC, 0))   # r0 = 0 - r0
            @primitives.store_var(ACC, node.var)
          end

          def emit_abs(node) = emit_conditional_negate(node.var, skip_when: :ge)
          def emit_negate_abs(node) = emit_conditional_negate(node.var, skip_when: :le)

          # Negate a variable only when it sits on one side of zero — the shared
          # shape of abs (|v|: negate when < 0, so skip when >= 0) and negate_abs
          # (-|v|: negate when > 0, so skip when <= 0). Compare to zero, jump over
          # the negate when the value is already on the wanted side.
          def emit_conditional_negate(var, skip_when:)
            @primitives.load_var(ACC, var)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            done = @emitter.gensym
            @emitter.emit_branch(:bcond, done, cond: skip_when)
            @emitter.emit(ASM.rsb_imm(ACC, ACC, 0))
            @emitter.place_label(done)
            @primitives.store_var(ACC, var)
          end

          # Clamp a variable into [min, max] with two compare-and-maybe-replace steps.
          #
          # A bound the program works out as it runs is evaluated first and the value
          # being clamped waits on the stack, the same way a binary operation holds one
          # side while it computes the other. A bound that is a plain number skips all
          # that and loads straight into a register, so a program with fixed bounds
          # emits exactly what it always did.
          def emit_clamp(node)
            @primitives.load_var(ACC, node.var)
            clamp_acc_to(node.min, cond: :ge) # below the floor? take the floor
            clamp_acc_to(node.max, cond: :le) # above the ceiling? take the ceiling
            @primitives.store_var(ACC, node.var)
          end

          # Replace r0 with +bound+ unless the comparison against it already holds.
          def clamp_acc_to(bound, cond:)
            if (fixed = @primitives.const_int(bound))
              @emitter.emit(ASM.load_immediate(TMP, fixed))
            else
              @emitter.emit(ASM.push(ACC))         # hold the value being clamped
              @lowering.value(bound)      # r0 = the bound
              @emitter.emit(ASM.mov_reg(TMP, ACC)) # r1 = the bound
              @emitter.emit(ASM.pop(ACC))          # r0 = the value again
            end

            keep = @emitter.gensym
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, keep, cond: cond)
            @emitter.emit(ASM.mov_reg(ACC, TMP))
            @emitter.place_label(keep)
          end

          # if: run the then-body when the condition is non-zero. With no else, a
          # false condition jumps past the body. With an else, a false condition
          # jumps to the else-body, and the then-body jumps over it to the end.
          def emit_if(node)
            @lowering.value(node.cond)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            else_node = node.else

            if else_node
              else_label = @emitter.gensym
              end_label = @emitter.gensym
              @emitter.emit_branch(:bcond, else_label, cond: :eq) # false => run the else
              node.children.each { |stmt| @lowering.statement(stmt) }
              @emitter.emit_branch(:b, end_label)                 # then done => skip the else
              @emitter.place_label(else_label)
              else_node.children.each { |stmt| @lowering.statement(stmt) }
              @emitter.place_label(end_label)
            else
              skip = @emitter.gensym
              @emitter.emit_branch(:bcond, skip, cond: :eq) # zero => condition false => skip
              node.children.each { |stmt| @lowering.statement(stmt) }
              @emitter.place_label(skip)
            end
          end

          # loop: an endless repeat of the body — a jump back to the top. A `halt`
          # (or the step budget, on the interpreter) is what ends it.
          #
          # The body is usually the busiest code in the whole program, so it is the first
          # thing worth keeping in the console's quick memory. When it has been chosen for
          # that (see {Placement}) the loop becomes a call into it and the body is emitted
          # with the other moved routines; otherwise it stays inline, exactly as it was.
          # EVERYTHING INSIDE STAYS INSIDE THESE EDGES. There is nothing to emit for the area
          # itself: it is not a thing the console knows about, it is the edges every shape below
          # is cut against — so it is remembered while the children are emitted and each of them
          # works its own clipping out against these instead of against the whole screen.
          #
          # Which is why the edges must be settled while building. A shape clips by comparing
          # against a number, and a number known here is an instruction; a number the game works
          # out would be a register held across every shape in the block.
          def emit_inside(node)
            @lowering.inside(node.x, node.y, node.w, node.h) do
              node.children.each { |stmt| @lowering.statement(stmt) }
            end
          end

          def emit_loop(node)
            top = @emitter.gensym
            @emitter.place_label(top)
            if @placement.fast_funcs.include?(Placement::FRAME_ROUTINE)
              @placement.emit_call_func(Placement::FRAME_ROUTINE)
            else
              start = @emitter.pos
              node.children.each { |stmt| @lowering.statement(stmt) }
              # Remember how big it came out: the measuring pass reads this to decide
              # whether moving it would fit.
              @functions.func_ranges[Placement::FRAME_ROUTINE] = (start...@emitter.pos)
            end
            @emitter.emit_branch(:b, top)
          end

          # repeat: a counted loop. The count is evaluated once into a hidden limit (matching
          # the interpreter, which captures the bound up front) and a hidden counter runs
          # 0..count-1 with the body on each pass.
          #
          # Where those two numbers are kept is the whole difference between the two shapes
          # below, and it is decided by the body and nothing else — see LoopForm.
          #
          # The answer is REMEMBERED as it is made, because the cost estimate has to charge for
          # the shape that will really run and must not work that out for itself: which
          # registers are free is this file's business. #loop_shapes hands it over the way
          # #var_addresses hands over where a variable landed.
          def emit_repeat(node)
            return emit_shape(node, :registers) { emit_repeat_held(node) } if LoopForm.registers?(node)
            return emit_shape(node, :spilled) { emit_repeat_spilled(node) } if LoopForm.spills?(node)

            emit_shape(node, :memory) { emit_repeat_in_memory(node) }
          end

          # Remember which shape this loop got before emitting it, so the cost estimate charges
          # for the code that will really run. The build decides; the estimate is told.
          def emit_shape(node, shape)
            @loop_shapes[node.index] =
              CostModel::LoopShape.new(shape: shape,
                                       blocked_by: shape == :registers ? nil : LoopForm.reason(node),
                                       spills: shape == :spilled ? LoopForm.blocking_children(node).size : 0)
            yield
          end

          # THE SAFE SHAPE: the counter and the limit live in the console's quick memory, so
          # anything at all may happen in the body — a call, a nested loop, a divide that
          # reaches the console's own routine — and the loop still counts right.
          #
          # It costs sixteen instructions a pass, twelve of them reaching those two numbers.
          def emit_repeat_in_memory(node)
            index = node.index
            limit = :"#{index}__limit"

            @lowering.value(node.count)   # r0 = count
            @primitives.store_var(ACC, limit)           # limit = count (once)
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, index)           # counter = 0

            top = @emitter.gensym
            done = @emitter.gensym
            @emitter.place_label(top)
            @primitives.load_var(ACC, index)            # r0 = counter
            @primitives.load_var(TMP, limit)            # r1 = limit
            @emitter.emit(ASM.cmp_reg(ACC, TMP))     # counter - limit
            @emitter.emit_branch(:bcond, done, cond: :ge) # counter >= limit => finished

            # ...and the other way out: a loop given something to stop for asks before every
            # pass, so one already answered on its first pass runs the body no times at all.
            if LoopForm.stops_early?(node)
              @lowering.value(node.stop_when)
              @emitter.emit(ASM.cmp_imm(ACC, 0))
              @emitter.emit_branch(:bcond, done, cond: :ne)
            end

            node.children.each { |stmt| @lowering.statement(stmt) }

            @primitives.load_var(ACC, index)
            @emitter.emit(ASM.add_imm(ACC, ACC, 1))  # counter += 1
            @primitives.store_var(ACC, index)
            @emitter.emit_branch(:b, top)
            @emitter.place_label(done)
          end

          # THE FAST SHAPE: the counter and the limit stay in two registers for the whole loop,
          # so a pass is a compare, a branch, an add and a branch — four instructions where the
          # safe shape spends sixteen.
          #
          # The body may still READ the index (`xs[i]` is what most loops are for), and it
          # reads it out of the register: #load_var is told the index is being held, so a read
          # is one move rather than three instructions of address and load. The index is
          # written back to its memory once on the way out, so anything after the loop sees
          # the value it would have seen anyway.
          def emit_repeat_held(node)
            emit_repeat_loop(node) do
              node.children.each { |stmt| @lowering.statement(stmt) }
            end
          end

          # THE THIRD SHAPE: the counter and the limit stay in registers, and the few statements
          # that would land in those registers are bracketed — the pair saved before and put
          # back after.
          #
          # This is what lets a loop keep the fast shape while its body does the thing the
          # framework asks for: behaviour in a func, called once per instance. A routine may
          # use any register it likes, which is why a call gives up the registers for the whole
          # body otherwise — but it can only do that WHILE IT RUNS, so saving the pair across
          # it is enough.
          #
          # A bracket is four instructions: the count written out to its variable, so a body
          # that reads the loop's index inside the bracket reads the true one (the fast shape
          # only writes it back on the way out, so its memory is stale until then), and the
          # pair saved and restored around the statement. Against the twelve a pass through
          # memory spends, two brackets still pay — which is what LoopForm::SPILL_LIMIT says.
          def emit_repeat_spilled(node)
            index = node.index
            bracketed = LoopForm.blocking_children(node).to_set

            emit_repeat_loop(node) do
              node.children.each do |statement|
                next @lowering.statement(statement) unless bracketed.include?(statement)

                emit_bracketed(index) { @lowering.statement(statement) }
              end
            end
          end

          # One statement run with the loop's pair kept safe across it. The index is written to
          # its variable first and read from there while the bracket is open, since the register
          # holding it is about to be somebody else's.
          def emit_bracketed(index)
            @primitives.store_var(LoopForm::COUNTER, index)
            @emitter.emit(ASM.push(LoopForm::COUNTER, LoopForm::LIMIT))
            @primitives.not_holding(index) { yield }
            @emitter.emit(ASM.pop(LoopForm::COUNTER, LoopForm::LIMIT))
          end

          # The counting the two register shapes share: set up, test, run the body, step on.
          # Only what happens to the body differs between them, so only that is passed in.
          def emit_repeat_loop(node)
            @lowering.value(node.count)
            @emitter.emit(ASM.mov_reg(LoopForm::LIMIT, ACC))
            @emitter.emit(ASM.load_immediate(LoopForm::COUNTER, 0))

            top = @emitter.gensym
            done = @emitter.gensym
            @emitter.place_label(top)
            @emitter.emit(ASM.cmp_reg(LoopForm::COUNTER, LoopForm::LIMIT))
            @emitter.emit_branch(:bcond, done, cond: :ge)

            @primitives.holding(node.index, LoopForm::COUNTER) { yield }

            @emitter.emit(ASM.add_imm(LoopForm::COUNTER, LoopForm::COUNTER, 1))
            @emitter.emit_branch(:b, top)
            @emitter.place_label(done)
            @primitives.store_var(LoopForm::COUNTER, node.index)
          end

          # every: run the body once every `period` frames. Tick the hidden frame
          # counter, and when it reaches the period, reset it and run the body. Built
          # as a small sub-tree and emitted through the shared statement emitters
          # (rather than hand-written instructions), so it reuses the tested add/if
          # lowering.
          # COUNTED IN FRAMES, NOT IN TIMES THIS CODE RAN. A pass of the game loop is one frame
          # on a game that fits and two on a game that does not, so adding one a pass makes a
          # beat given in seconds take longer than that many seconds on a heavy game.
          #
          # Taking the period off rather than clearing to nought keeps the remainder, so a beat
          # that overshoots does not lose the overshoot and drift further every time. With one
          # frame a pass the counter lands on the period exactly and the two are the same thing.
          #
          # A beat shorter than the frames a pass took fires once and catches up on the next
          # pass rather than firing several times in one — a bounded lag, against a body running
          # three times where the author wrote it once.
          def emit_every(node)
            counter = node.counter
            reached = Build.binop(:>=, Build.var_ref(counter), Build.int(node.period))
            gate = Build.if_(reached, Build.sub(counter, node.period), *node.children)
            @lowering.statement(Build.add(counter, Build.var_ref(IR::Frames::STEP)))
            @lowering.statement(gate)
          end

          # after: run the body exactly once, `frames` frames in. Count up only until
          # the target — so the counter never overflows or fires twice — and run the
          # body on the one frame it lands on. Built as a sub-tree emitted through the
          # shared statement emitters, reusing the tested add/if lowering.
          # ...and the same for a one-shot. Counted in frames for the same reason — and the test
          # is REACHED rather than LANDED ON, because a pass worth two frames can step over the
          # frame it was waiting for. Landing exactly is what one-a-pass counting guaranteed;
          # counting frames does not, and a body that never fires is a worse fault than one that
          # fires a frame late. The outer test is what still keeps it to once.
          def emit_after(node)
            counter = node.counter
            frames = node.frames
            lands = Build.if_(Build.binop(:>=, Build.var_ref(counter), Build.int(frames)), *node.children)
            not_yet = Build.if_(Build.binop(:<, Build.var_ref(counter), Build.int(frames)),
                                Build.add(counter, Build.var_ref(IR::Frames::STEP)), lands)
            @lowering.statement(not_yet)
          end

          def emit_call(node) = @placement.emit_call_func(node.target)
          def emit_raw(node) = @emitter.emit(node.bytes) # escape hatch: pre-assembled bytes, verbatim
          def emit_halt(_node) = @emitter.emit(ASM.loop_forever)
        end
      end
    end
  end
end
