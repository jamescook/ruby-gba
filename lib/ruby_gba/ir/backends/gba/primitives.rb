# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Small shared primitives: variable addresses, stores, constant folding.
        class Primitives
          include Console::Hardware

          # THE WORD A FILL READS ITS COLOUR FROM. The console's copying engine fills by
          # reading the same word over and over, so a fill stores its colour in this one
          # and hands the engine the word's ADDRESS — as a number, built by instructions.
          FILL_SCRATCH = :_dma_scratch

          def initialize(emitter:, memory:)
            @emitter = emitter
            @memory = memory
            @vars = {}             # variable name -> IWRAM address
            @var_mentions = []     # [where in the code, variable name], one for each time one is named
            @held_registers = {}
          end

          # THE FILL'S WORD GETS THE FIRST ADDRESS THERE IS, so this is called before the
          # program has named anything. How many instructions a number takes depends on its
          # bits, and the first address of this memory is the only one the chip builds in a
          # single instruction; most of the others take two or three. Handed out on first
          # mention like everything else, the word landed wherever the variables named before
          # the first fill left it, so what EVERY fill in a game cost was settled by something
          # nobody chose. A program that never fills spends one word of memory on it.
          def claim_first_address_for_fill_scratch
            var_addr(FILL_SCRATCH)
          end

          # Every variable's allocated address (name => address) — read by GBA#var_addresses.
          attr_reader :vars

          # A variable is 4 bytes in IWRAM, addresses handed out on first mention — and
          # handed out at the near end, which is what keeps them inside the window the
          # note below is about. See {Memory}.
          def var_addr(name)
            @var_mentions << [@emitter.pos, name]
            @vars[name] ||= roomy_var?(name) ? claim_roomy_var(name) : @memory.alloc_near_base(4)
          end

          # A VARIABLE A COLLECTION OWNS GOES WHERE THE COLLECTION WENT. A list keeps how many
          # items it holds, and a pool a dozen more of its own (see Lists#roomy_counter?); a
          # collection kept in the roomy memory, because the author said it is cold or because
          # the quick one ran out, would otherwise leave those behind in the quick memory, where
          # every one of them is a word the code kept there cannot have. Reaching one there costs
          # its whole address, which the collection's own items already cost.
          #
          # +roomy_counter_test+ answers whether a name is one of those, and is handed in by
          # whoever knows where the collections went.
          attr_writer :roomy_counter_test

          def roomy_var?(name) = @roomy_counter_test&.call(name) || false

          # Give +name+ a place in the roomy memory, before anything names it. The build's second
          # pass asks this for each variable its measuring pass put there, since it names them
          # before it has placed the collections that decide it (see
          # Placement#allocate_variables_where_measured).
          def claim_roomy_var(name)
            @vars[name] ||= @memory.alloc_roomy_var ||
                            raise(LoweringError, "The console's roomy memory is full. A list or pool kept there " \
                                                 "needs room for one more number of its own. To fix this, use " \
                                                 "a smaller capacity, or narrower items (`width: :byte`).")
          end

          # The variables named anywhere in +span+ of the code, each once, in the order they
          # were first named there. This is how the build learns which variables a routine
          # uses, the ones it made for itself included.
          def variables_named_in(span)
            @var_mentions.filter_map { |pos, name| name if span.cover?(pos) }.uniq
          end

          # HOW FAR FROM THE BASE A VARIABLE CAN SIT and still be reached by naming the two
          # together. The instruction keeps twelve bits for the distance, so a thousand
          # variables. Past that the address is built in full, as everything used to be.
          FURTHEST_FROM_BASE = 0xFFF

          # READING A VARIABLE IS TWO INSTRUCTIONS, AND OFTEN ONE: put the base of the variable
          # memory in a register, then load from that register plus this variable's distance
          # along — and skip the first of those when the base is still sitting there from the
          # last access.
          #
          # It used to be the whole address and then a load, and the whole address is the
          # expensive part. This console can name a number in one instruction only when the
          # number has eight significant bits in the right places, which an address does not,
          # except by luck: the FIRST variable sits at the base itself and costs one, the next
          # sixty-three cost two, and everything past that costs three. So the hundredth variable
          # a program declares was read in four instructions and the first in two, for no reason
          # the program could see — it was the order the backend happened to emit things in.
          #
          # The base is a number this console CAN name in one instruction, and the distance rides
          # inside the load. So every variable is two, and the hundredth costs what the first
          # does. And since the base never changes for the life of the program, a run of accesses
          # with nothing between them that could disturb the register needs it made only once —
          # which is most of a run of arithmetic, where the whole of the work between two
          # variables is an add or a compare. What knows when it is still there is
          # {AddressRegister}, which is careful about it, because being wrong writes to the
          # wrong address rather than failing.
          #
          # A variable the code around us is already HOLDING in a register is one move instead,
          # and it is the same number either way because whoever holds it is keeping memory and
          # register in step (see Statements#emit_repeat, the only holder today: a loop's index).
          def load_var(reg, name)
            held = held_register(name)
            return @emitter.emit(ASM.mov_reg(reg, held)) if held

            offset = var_offset(name)
            return @emitter.emit(ASM.ldr_offset(reg, ADDR, offset)) if emit_var_address_base(offset)

            @emitter.emit(ASM.ldr(reg, ADDR))
          end

          def store_var(reg, name)
            offset = var_offset(name)
            return @emitter.emit(ASM.str_offset(reg, ADDR, offset)) if emit_var_address_base(offset)

            @emitter.emit(ASM.str(reg, ADDR))
          end

          def var_offset(name) = var_addr(name) - IWRAM_START

          # The register a variable is being held in for the moment, or nil. Kept as a plain
          # map rather than an allocator: exactly one thing puts anything in it, and it puts
          # the entry back the way it found it.
          def held_register(name) = @held_registers[name]

          # For a moment, read this variable from its memory rather than from the register that
          # was holding it — because the register is about to be lent to something else and put
          # back afterwards (see Statements#emit_bracketed).
          def without_var_in_register(name, &block) = with_var_in_register(name, nil, &block)

          def with_var_in_register(name, reg)
            was = @held_registers[name]
            @held_registers[name] = reg
            yield
          ensure
            @held_registers[name] = was
            @held_registers.delete(name) if was.nil?
          end

          # Store the full 32-bit word in r0 to a fixed address.
          def store_word_acc(address)
            @emitter.emit_number(TMP, address)
            @emitter.emit(ASM.str(ACC, TMP))
          end

          # Store the low 16 bits of r0 to a fixed address — for a register that is a
          # halfword wide and holds a value the program worked out as it ran.
          def store_halfword_acc(address)
            @emitter.emit_number(TMP, address)
            @emitter.emit(ASM.store_halfword(ACC, TMP))
          end

          # Write a full 32-bit word to an address.
          def store_word_immediate(value, address)
            @emitter.emit_number(ACC, value)
            @emitter.emit_number(TMP, address)
            @emitter.emit(ASM.str(ACC, TMP))
          end

          # A value that is already waiting in a register, for {#emit_start_copy_engine}: that
          # register is written as it stands, where a plain number is loaded first.
          InRegister = Data.define(:register)

          # How far along from the first of the copying engine's three registers the other
          # two sit.
          COPY_TO_STEP = REG_DMA3DAD - REG_DMA3SAD
          COPY_START_STEP = REG_DMA3CNT - REG_DMA3SAD

          # TELL THE COPYING ENGINE WHAT TO COPY, AND START IT. The console has an engine that
          # moves a block of memory on its own, far faster than a loop of loads and stores, and
          # it is told what to do through three registers: where to copy +from+, where +to+,
          # and a +control+ word saying how much and in what manner. Writing the control word
          # is what starts it, so that one always goes last.
          #
          # THE THREE SIT SIDE BY SIDE IN MEMORY, which is why this is one call and not three
          # stores. An address is the dear part of a store on this chip — two instructions to
          # build, where the store itself is one — and a store can name a small step from the
          # address it is given for nothing. So the first address is built once and the other
          # two are reached from it: two instructions for the three, not six. A game starts
          # this engine wherever it clears, fills, copies a row or sends a picture, so it is a
          # sequence written out hundreds of times over.
          #
          # Each of the three is one of:
          #
          #   * a number settled while building, which is loaded and written;
          #   * an {InRegister}, written from where it waits;
          #   * a block that leaves the number in the accumulator — an address filled in
          #     later, a size not known yet — which is run and then written.
          #
          # Numbers pass through the accumulator on their way, so anything already waiting in
          # a register is written before the first of them. That is the only reordering, and
          # the engine does not care which of its two ends it hears about first.
          def emit_start_copy_engine(from:, to:, control:)
            refuse_copy_engine_register_clash!(from, to, control)
            @emitter.emit_number(TMP, REG_DMA3SAD)
            # What a block must leave alone: the engine's address, and a control word that is
            # still waiting for its turn.
            kept = [TMP, *(control.register if control.is_a?(InRegister))]
            waiting, loaded = [[from, 0], [to, COPY_TO_STEP]].partition { |value, _| value.is_a?(InRegister) }
            (waiting + loaded).each { |value, step| emit_copy_engine_store(value, step, kept) }
            emit_copy_engine_store(control, COPY_START_STEP, kept)
          end

          # The value of an operand the author fixed, or nil if the game works it out. The
          # same question the surface asks, so the two cannot disagree about what counts as
          # fixed; what this adds is the console's own arithmetic, where a number is signed
          # and thirty-two bits wide.
          def self.const_int(node)
            fixed = DSL::Value.fixed_number(node)
            Int32.wrap(fixed) if fixed
          end

          def const_int(node) = self.class.const_int(node)

          # Each named operand as a number settled while building, in the order given. The
          # caller passes the values along with what to call them, because the name is only
          # wanted for the message if one of them turns out to be worked out as the game runs.
          def constant_ints!(node, **sides)
            sides.map do |name, value|
              const_int(value) ||
                raise(LoweringError,
                      "the GBA backend needs a constant #{name} for #{node.kind} " \
                      "(a computed one is the runtime-rect work, tracked separately)")
            end
          end

          # Run +body+ once per row of a rect whose height the program works out as it
          # runs. +counter+ is the register holding how many rows are left; +body+ emits
          # one row and must leave the counter alone.
          #
          # The count is tested BEFORE the first row, which is what makes a height of
          # zero — or a negative one, from a bar that ran past empty — draw nothing
          # instead of wrapping round to four thousand million rows.
          def emit_row_loop(counter)
            top = @emitter.gensym
            done = @emitter.gensym
            @emitter.place_label(top)
            @emitter.emit(ASM.cmp_imm(counter, 0))
            @emitter.emit_branch(:bcond, done, cond: :le)
            yield
            @emitter.emit(ASM.sub_imm(counter, counter, 1))
            @emitter.emit_branch(:b, top)
            @emitter.place_label(done)
          end

          # rd = rn + imm. A small immediate rides directly in the ADD; a larger one
          # (a wide bitmap's row offset, say) is loaded into +scratch+ first, since
          # ARM can only fold an 8-bit rotated immediate into the instruction.
          def emit_add_const(rd, rn, imm, scratch)
            if imm.zero?
              @emitter.emit(ASM.mov_reg(rd, rn)) unless rd == rn
            elsif ASM.encode_rotated_immediate(imm)
              @emitter.emit(ASM.add_imm(rd, rn, imm))
            else
              @emitter.emit_number(scratch, imm)
              @emitter.emit(ASM.add_reg(rd, rn, scratch))
            end
          end

          # PUT AN ADDRESS IN AN ADDRESS REGISTER, as cheaply as what is already in there
          # allows. Three prices, and the caller writes the same line for all three:
          #
          #   * Nothing at all, when the register already holds it. This is the case that
          #     matters — a run of accesses to the same thing names its address once.
          #   * ONE instruction, when the register holds another address near enough that
          #     the step between them is a number this chip can name outright. Two lists
          #     side by side in memory — which is what a pool's fields are — are a step
          #     apart of exactly one list's length, so walking from one field to the next
          #     is an add rather than an address built from scratch.
          #   * The address in full: built a byte at a time, or, in a routine kept in the
          #     quick memory, read from that routine's table of numbers (Emit#emit_number).
          #
          # Being WRONG here writes to the wrong place rather than failing, so what may be
          # believed about the register is decided in one place ({AddressRegister}) and
          # this only spends it. Note the order: the instruction is emitted first and the
          # new value recorded after, because emitting it is itself what makes the old
          # value untrue.
          def emit_load_address_register(address, reg = ADDR, held = @emitter.address_register)
            return if held.holds?(address)

            step = held.value && address - held.value
            if step && ASM.encode_rotated_immediate(step.abs)
              @emitter.emit(step.negative? ? ASM.sub_imm(reg, reg, -step) : ASM.add_imm(reg, reg, step))
            else
              @emitter.emit_number(reg, address)
            end
            held.now_holds(address)
          end

          # The same, for a collection's own base — which waits in a register of its own so
          # that the variables and the collections are not forever pushing each other out of
          # one. See {LIST_ADDR}.
          def emit_list_base(address) = emit_load_address_register(address, LIST_ADDR, @emitter.list_register)

          # rd = rn & imm — the ring-wrap mask. A mask that fits an 8-bit rotated
          # immediate (capacity up to 256) rides directly in the AND; a wider one is
          # loaded into +scratch+ first, since ARM can't fold it into the instruction.
          def emit_and_const(rd, rn, imm, scratch)
            if ASM.encode_rotated_immediate(imm)
              @emitter.emit(ASM.and_imm(rd, rn, imm))
            else
              @emitter.emit_number(scratch, imm)
              @emitter.emit(ASM.and_reg(rd, rn, scratch))
            end
          end

          private

          # One of the engine's three registers, +step+ along from the first, whose address
          # is waiting in TMP. +kept+ is the registers a block has to leave as they are.
          def emit_copy_engine_store(value, step, kept)
            return @emitter.emit(ASM.str_offset(value.register, TMP, step)) if value.is_a?(InRegister)

            if value.respond_to?(:call)
              before = [@emitter.pos, @emitter.branches]
              value.call
              refuse_copy_engine_block_overwrite!(*before, kept)
            else
              @emitter.emit_number(ACC, value)
            end
            @emitter.emit(ASM.str_offset(ACC, TMP, step))
          end

          # BEING WRONG HERE WRITES TO THE WRONG PLACE AND SAYS NOTHING, so the ways a caller
          # could lose a number are refused while building. TMP holds the engine's address
          # from the first store to the last, and the accumulator is what every loaded number
          # passes through — so a control word waiting there would be gone by the time it was
          # written. (What a block may write is checked once it has run; see below.)
          def refuse_copy_engine_register_clash!(from, to, control)
            waiting = [from, to, control].grep(InRegister)
            if waiting.any? { |value| value.register == TMP }
              raise ArgumentError, "the copying engine's own address is kept in r#{TMP}, so a number " \
                                   "for it cannot wait there"
            end
            return unless control == InRegister.new(ACC) && waiting != [from, to, control]

            raise ArgumentError, "the control word cannot wait in r#{ACC}: the numbers written before " \
                                 "it are loaded through that register"
          end

          # A block that works a number out must leave the +kept+ registers as they are, and
          # that has to be something its instructions can be read for. A jump or a call cannot
          # be: each is a placeholder until the second pass, and a call reaches a routine that
          # uses the registers for work of its own. So a block is a straight run or it is
          # refused.
          def refuse_copy_engine_block_overwrite!(start, branches, kept)
            if @emitter.branches != branches
              raise ArgumentError, "working out a number for the copying engine jumped or called, so " \
                                   "what it left in the registers cannot be checked"
            end
            written = @emitter.code.byteslice(start, @emitter.pos - start).unpack("V*")
            lost = kept.find { |register| written.any? { |word| ASM.may_write_register?(word, register) } }
            return unless lost

            raise ArgumentError, "working out a number for the copying engine wrote r#{lost}, which " \
                                 "holds a number the engine has not been given yet"
          end

          # Put what the load will be read from into the address register: the base of the
          # variable memory when the variable is near enough to it, and the variable's own
          # address when it is not. Answers whether the distance still has to be named.
          def emit_var_address_base(offset)
            near = offset.between?(0, FURTHEST_FROM_BASE)
            emit_load_address_register(near ? IWRAM_START : IWRAM_START + offset)
            near
          end
        end
      end
    end
  end
end
