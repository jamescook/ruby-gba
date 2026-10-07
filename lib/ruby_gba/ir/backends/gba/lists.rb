# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # A list is a block of 4-byte slots in IWRAM plus a hidden `length` variable, and it
        # is stored one of two ways depending on what the program does to it.
        #
        # A LIST THAT IS SHIFTED IS A RING. Dropping from the front means the oldest item moves,
        # so the list keeps a `head` as well, and the item logically at position i sits in the
        # physical slot (head + i) & mask. The mask is what makes that wrap a single bitwise AND
        # rather than a division — which needs a power-of-two block, so a ring is given the next
        # power of two up and pays for the slots in between. It never HOLDS more than it was
        # asked for; the extra slots exist only so the mask cannot point outside its own block.
        #
        # A LIST THAT IS ONLY INDEXED IS A PLAIN ARRAY, which is nearly all of them: a pool's
        # fields, a board, anything filled once and then read and written by number. Its head
        # can never move, so the physical slot IS the index — no head to load, no wrap to do,
        # and no rounding to pay for. A pool of 145 slots takes 145 and not 256, which on a
        # cartridge with a lot of them is thousands of bytes of the console's 32K.
        #
        # EITHER WAY A BAD INDEX STAYS INSIDE THE LIST. The ring's mask confines it; the plain
        # array compares against its own length and reads slot nought instead. So an index off
        # the end can pick up a stale slot and can never reach a neighbouring variable. This
        # mirrors the interpreter's list (same items readable, same length, same overflow
        # point); the interpreter's friendly errors catch logic bugs in testing, and here the
        # hardware just stays bounded.
        #
        # A sprite's save-under backing buffer shares this file because it shares this
        # IWRAM allocation story — a name registered once, a layout looked up
        # afterward — not because it's a list; see #register_backing/#backing_info.
        class Lists
          include Console::Hardware

          def initialize(memory:, primitives:, emitter:, lowering:, call_cold:)
            @memory = memory
            @primitives = primitives
            @emitter = emitter
            @lowering = lowering
            @call_cold = call_cold
            @lists = {}
            @backing = {}
            @fills = false
            @copies = false
          end

          # The routine every list_fill calls, named once.
          FILL_ROUTINE = Messages::MadeNames.make(:list_fill_routine)

          # list_fill: +count+ items from +from+ set to one value, the way that many list_sets
          # would — and a bad index stays inside the list the same way: a run starting outside
          # it writes nothing, and one running off its end stops at the end. What it saves is
          # the per-item work: the run is handed to one routine that writes a word, four bytes,
          # at a time (see #emit_fill_routine), where a list_set per item works out an address
          # and stores one item each time.
          #
          # Only a plain array can be filled: a ring's items wrap round its block, so a run of
          # them is not a run of memory. Nothing builds a fill of one.
          def emit_list_fill(node)
            info = list_info(node.name)
            raise LoweringError, "list #{node.name.inspect} is shifted, so a run of it cannot be filled" if info[:ring]

            @fills = true
            skip = @emitter.gensym
            @lowering.value(node.value)
            @emitter.emit(ASM.push(ACC))
            @lowering.value(node.count)
            @emitter.emit(ASM.push(ACC))
            @lowering.value(node.from)                              # r0 = from
            @emitter.emit(ASM.pop(2))                               # r2 = count
            @emitter.emit(ASM.pop(3))                               # r3 = the value
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, skip, cond: :lt)           # starts before the list
            # r12 is the address register, borrowed here for a count: the emitter forgets the
            # address it held the moment anything writes it.
            @emitter.emit(ASM.load_immediate(12, info[:capacity]))
            @emitter.emit(ASM.sub_reg(12, 12, ACC))                 # r12 = items from +from+ to the end
            @emitter.emit(ASM.cmp_reg(2, 12))
            @emitter.emit(ASM.mov_reg_cond(:gt, 2, 12))             # stop at the end
            @emitter.emit(ASM.cmp_imm(2, 0))
            @emitter.emit_branch(:bcond, skip, cond: :le)           # nothing to write
            shift = Math.log2(info[:bytes]).to_i
            if shift.positive?
              @emitter.emit(ASM.lsl_imm(ACC, ACC, shift))           # r0 = from * item size
              @emitter.emit(ASM.lsl_imm(2, 2, shift))               # r2 = bytes to write
            end
            @primitives.emit_list_base(info[:base])
            @emitter.emit(ASM.add_reg(TMP, LIST_ADDR, ACC))         # r1 = where the run starts
            emit_fill_pattern(info[:width])                         # r0 = the value in every byte place
            @call_cold.call(FILL_ROUTINE)
            @emitter.place_label(skip)
          end

          # The routine every list_copy calls, named once.
          COPY_ROUTINE = Messages::MadeNames.make(:list_copy_routine)

          # list_copy: the list made to hold +count+ entries of a table in the cartridge, from
          # the entry the game worked out. The start is held so the whole run is inside the
          # table, the same as the interpreter holds it, and the run always lands at the front
          # of the list — so a ring's head goes back to its first slot and the copy is still
          # one block of memory. The bytes are handed to one routine (see #emit_copy_routine).
          def emit_list_copy(node, table)
            info = list_info(node.name)
            # The builder refuses these (Builder#copy_table_run); this is the lowering's own
            # invariant, for a tree that reached it some other way — either would write past
            # the list into whatever memory follows it.
            unless table.elem_bytes == info[:bytes] && node.count.between?(1, [info[:capacity], table.count].min)
              raise LoweringError, "list #{node.name.inspect} cannot hold #{node.count} entries of table #{node.table.inspect}"
            end

            @copies = true
            @lowering.value(node.at)                                         # r0 = where the run starts
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit(ASM.mov_imm_cond(:lt, ACC, 0))                     # not before the table
            @emitter.emit(ASM.load_immediate(TMP, table.count - node.count))
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit(ASM.mov_reg_cond(:gt, ACC, TMP))                   # nor running off its end
            shift = Math.log2(table.elem_bytes).to_i
            @emitter.emit(ASM.lsl_imm(ACC, ACC, shift)) if shift.positive?   # r0 = its distance in bytes
            @emitter.emit_load_data_address(TMP, node.table)
            @emitter.emit(ASM.add_reg(ACC, TMP, ACC))                        # r0 = where it is in the cartridge
            @primitives.emit_list_base(info[:base])
            @emitter.emit(ASM.mov_reg(TMP, LIST_ADDR))                       # r1 = the list's first slot
            @emitter.emit(ASM.load_immediate(2, node.count * table.elem_bytes)) # r2 = bytes to copy
            @call_cold.call(COPY_ROUTINE)
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, head_var(node.name)) if info[:ring]
            @emitter.emit(ASM.load_immediate(ACC, node.count))
            @primitives.store_var(ACC, length_var(node.name))
          end

          # THE ROUTINE THAT COPIES A RUN: r0 where it comes from, r1 where it goes, r2 how many
          # bytes, more than nought. The copying engine moves a run without the processor, a
          # word or a half-word at a time, while a byte at a time is all the processor can do
          # in a loop — so the widest one the two addresses and the length all allow is taken:
          # words when all three are a whole number of words, half-words when they are a whole
          # number of halves, and bytes one at a time only for a run that is neither. A table
          # run starting at an entry the game works out is usually on a word, since entries
          # are picked by a number times the run's length. Touches r0 to r3 and nothing else,
          # and is emitted only in a program that copies.
          def emit_copy_routine
            return unless @copies

            e = @emitter
            halves = e.gensym
            bytes = e.gensym
            e.emit(ASM.loop_forever) # fall-through guard: only ever entered by a call
            e.place_label(COPY_ROUTINE)
            e.emit(ASM.orr_reg(3, ACC, TMP))
            e.emit(ASM.orr_reg(3, 3, 2))                                     # r3 = every address bit in play
            e.emit(ASM.tst_imm(3, 1))
            e.emit_branch(:bcond, bytes, cond: :ne)
            e.emit(ASM.tst_imm(3, 2))
            e.emit_branch(:bcond, halves, cond: :ne)
            e.emit(ASM.lsr_imm(3, 2, 2))                                     # words
            e.emit(ASM.orr_imm(3, 3, DMA_32BIT))
            e.emit(ASM.orr_imm(3, 3, DMA_ENABLE))
            emit_start_engine
            e.emit(ASM.return)
            e.place_label(halves)
            e.emit(ASM.lsr_imm(3, 2, 1))                                     # half-words
            e.emit(ASM.orr_imm(3, 3, DMA_ENABLE))
            emit_start_engine
            e.emit(ASM.return)
            e.place_label(bytes)
            e.emit(ASM.ldrb_offset(3, ACC, 0))
            e.emit(ASM.add_imm(ACC, ACC, 1))
            e.emit(ASM.strb_post(3, TMP, 1))
            e.emit(ASM.subs_imm(2, 2, 1))
            e.emit_branch(:bcond, bytes, cond: :ne)
            e.emit(ASM.return)
            # Where it ends, so a profile can say how much of a frame went into copying (see
            # GBA#lowered_routine_addresses).
            e.place_label(:"#{COPY_ROUTINE}_end")
          end

          # The value in r3 repeated across a whole word in r0, so a word written anywhere in the
          # run holds the right item in each of its places.
          def emit_fill_pattern(width)
            case width
            when :byte
              @emitter.emit(ASM.and_imm(ACC, 3, 0xFF))
              @emitter.emit(ASM.orr_reg_lsl(ACC, ACC, ACC, 8))
              @emitter.emit(ASM.orr_reg_lsl(ACC, ACC, ACC, 16))
            when :half
              @emitter.emit(ASM.lsl_imm(ACC, 3, 16))
              @emitter.emit(ASM.lsr_imm(ACC, ACC, 16))
              @emitter.emit(ASM.orr_reg_lsl(ACC, ACC, ACC, 16))
            when :word
              @emitter.emit(ASM.mov_reg(ACC, 3))
            end
          end

          # THE ROUTINE THAT WRITES A RUN: r0 the word pattern, r1 where the run starts, r2 how
          # many bytes, more than nought. Bytes one at a time until the address is on a whole
          # word, then whole words, then the bytes left over. Each byte written alone is the
          # pattern's low byte, and the pattern is turned a byte along after it, so the next
          # address finds the byte that belongs there — which is what keeps a run of halves or
          # words right whichever byte it starts on. Touches r0 to r3 and nothing else, and is
          # emitted only in a program that fills.
          def emit_fill_routine
            return unless @fills

            e = @emitter
            e.emit(ASM.loop_forever) # fall-through guard: only ever entered by a call
            e.place_label(FILL_ROUTINE)
            lead = e.gensym
            words = e.gensym
            last_bytes = e.gensym
            done = e.gensym
            e.place_label(lead)
            e.emit(ASM.tst_imm(TMP, 3))
            e.emit_branch(:bcond, words, cond: :eq)               # on a whole word
            emit_fill_byte
            e.emit(ASM.subs_imm(2, 2, 1))
            e.emit_branch(:bcond, done, cond: :eq)
            e.emit_branch(:b, lead)
            e.place_label(words)
            e.emit(ASM.cmp_imm(2, 4))
            e.emit_branch(:bcond, last_bytes, cond: :lt)          # less than a word left
            emit_fill_words_by_engine
            e.place_label(last_bytes)
            e.emit(ASM.cmp_imm(2, 0))
            e.emit_branch(:bcond, done, cond: :eq)
            emit_fill_byte
            e.emit(ASM.sub_imm(2, 2, 1))
            e.emit_branch(:b, last_bytes)
            e.place_label(done)
            e.emit(ASM.return)
            # Where it ends, so a profile can say how much of a frame went into filling (see
            # GBA#lowered_routine_addresses).
            e.place_label(:"#{FILL_ROUTINE}_end")
          end

          # THE WHOLE WORDS OF THE RUN, handed to the copying engine rather than stored one at a
          # time: told to read the same word over and over, it writes it across the run with the
          # processor waiting, which is a few cycles a word where a store in a loop run from the
          # cartridge is several times that. The engine reads its word from memory, so the pattern
          # goes on the stack for it to read and comes back off after. r1 then points past the
          # words and r2 holds the bytes left, fewer than four, with the pattern as it was — a
          # whole number of words moves it round no places.
          def emit_fill_words_by_engine
            e = @emitter
            e.emit(ASM.push(ACC))                                   # the pattern, where the engine can read it
            e.emit(ASM.mov_reg(ACC, 13))                            # it reads from the stack...
            e.emit(ASM.lsr_imm(3, 2, 2))                            # ...this many words
            e.emit(ASM.orr_imm(3, 3, DMA_ENABLE))
            e.emit(ASM.orr_imm(3, 3, DMA_32BIT))
            e.emit(ASM.orr_imm(3, 3, DMA_SRC_FIXED))
            emit_start_engine
            e.emit(ASM.bic_imm(3, 2, 3))
            e.emit(ASM.add_reg(TMP, TMP, 3))                        # r1 past the words
            e.emit(ASM.and_imm(2, 2, 3))                            # r2 the bytes left
            e.emit(ASM.pop(ACC))
          end

          # START THE COPYING ENGINE from r0 to r1 with the control word in r3, every register
          # as it was afterwards. The engine is set up in three writes and goes on the last, and
          # a routine answering an interrupt can use the same engine — a timer's handler that
          # fills or copies — so an interrupt between the writes would leave this one starting
          # with that one's addresses. So interrupts are held off for the three writes, and the
          # switch is put back as it was rather than turned on, which keeps it off where the
          # caller had it off. The processor waits while the engine runs, so the hold covers the
          # copy as well.
          def emit_start_engine
            e = @emitter
            e.emit(ASM.push(ACC, 2, 3))
            e.emit(ASM.load_immediate(2, REG_IME))
            e.emit(ASM.load_halfword(ACC, 2))
            e.emit(ASM.push(ACC))                                   # the interrupt switch as it was
            e.emit(ASM.load_immediate(ACC, 0))
            e.emit(ASM.store_halfword(ACC, 2))
            e.emit(ASM.load_immediate(2, REG_DMA3SAD))
            e.emit(ASM.ldr_offset(ACC, 13, 4))
            e.emit(ASM.str_offset(ACC, 2, 0))                       # from
            e.emit(ASM.str_offset(TMP, 2, 4))                       # to
            e.emit(ASM.ldr_offset(ACC, 13, 12))
            e.emit(ASM.str_offset(ACC, 2, 8))                       # go; the processor waits
            e.emit(ASM.pop(ACC))
            e.emit(ASM.load_immediate(2, REG_IME))
            e.emit(ASM.store_halfword(ACC, 2))
            e.emit(ASM.pop(ACC, 2, 3))
          end

          # One byte of the pattern written, the address moved on, and the pattern turned a byte
          # along to match it.
          def emit_fill_byte
            @emitter.emit(ASM.strb_post(ACC, TMP, 1))
            @emitter.emit(ASM.lsr_imm(3, ACC, 8))
            @emitter.emit(ASM.orr_reg_lsl(ACC, 3, ACC, 24))
          end

          # Reserve a list's IWRAM layout: the slot block, then the head and length
          # variables. Called once per name during the definitions pass; a name
          # created twice with different capacities is a contradiction.
          #
          # +ring+ says the program SHIFTS this one, so its head moves and its slots have to be
          # rounded up to a power of two for the wrapping mask. Everything else is a plain
          # array of exactly the slots it asked for.
          #
          # +fast+ is what the author said about where it should live: false for "I know
          # this is cold — give it room", true to insist on the quick memory, nil to let the
          # framework decide (see #place_list).
          def register_list(name, capacity, ring: true, width: :word, fast: nil)
            if (existing = @lists[name])
              return if existing[:capacity] == capacity && existing[:width] == width

              raise LoweringError,
                    "list #{name.inspect} is created with two different capacities " \
                    "(#{existing[:capacity]} and #{capacity})"
            end

            slots = ring ? Build.round_up_capacity(capacity) : capacity
            bytes = Build::ELEMENT_BYTES.fetch(width)
            # Rounded up to a whole word so the NEXT thing allocated stays word-aligned — a
            # narrow list is allowed to be an odd number of bytes long, but nothing after it is.
            want = ((slots * bytes) + 3) & ~3
            base, roomy = place_list(name, want, fast)
            @primitives.var_addr(head_var(name)) if ring # a plain array's head can never move
            @primitives.var_addr(length_var(name))
            @lists[name] = { capacity: capacity, ring: ring, mask: slots - 1, base: base,
                             width: width, bytes: bytes, roomy: roomy }
          end

          # WHICH MEMORY THIS ONE GOES IN. The quick one unless the author said it does not
          # need to be there, or there is no longer room — and then the roomy one, which is
          # eight times the size and about six times the wait on a read.
          #
          # Nothing is moved to make space: the caller registers the collections a frame
          # touches FIRST (see Roomy), so whatever is left when the quick memory fills is
          # the coldest thing the program has. Running out of BOTH is a real ceiling, and
          # the message says which one gave way.
          def place_list(name, want, fast)
            if fast == false || !@memory.room_for?(want)
              addr = @memory.alloc_roomy(want)
              return [addr, true] if addr

              raise LoweringError, no_room_message(name, want) if fast == false
            end
            [@memory.alloc(want), false]
          end

          def no_room_message(name, want)
            "list #{name.inspect} needs #{want} bytes and neither of the console's work memories has " \
              "room left. It has 32K of quick memory (which also holds the code kept there) and 256K " \
              "of roomy memory, and both are full. Use a smaller capacity, or narrower items " \
              "(`width: :byte`)."
          end

          # The collections that ended up in the roomy memory, and how big each is — the
          # one thing a build report has to say about a decision nobody wrote.
          def roomy_lists
            @lists.select { |_name, info| info[:roomy] }
                  .to_h { |name, info| [name, info[:capacity] * info[:bytes]] }
          end

          # WHERE EACH LIST LIVES, for a finished cartridge to be asked about: the address of its
          # first slot, how many slots it may hold, and the address of the number saying how many
          # it holds now. A measurement that wants a list held full writes that number (see
          # Diagnostics::FullCollections), and nothing but this build knows where it is.
          Place = Data.define(:base, :capacity, :length_at)

          def list_places
            @lists.to_h do |name, info|
              [name, Place.new(base: info[:base], capacity: info[:capacity],
                               length_at: @primitives.vars.fetch(length_var(name)))]
            end
          end

          # A list's layout, or a friendly error if the program never created it.
          def list_info(name)
            @lists[name] ||
              raise(LoweringError,
                    "list #{name.inspect} was used before it was created — " \
                    "a `list #{name.inspect}, capacity: N` must run first")
          end

          # Reserve a backing buffer's RAM: a width×height block of 16-bit pixels in
          # the same IWRAM the variables live in. Allocated once per name during the
          # definitions pass; the block is padded to a whole word so the next
          # allocation stays word-aligned. A name declared twice with a different size
          # is a contradiction.
          def register_backing(name, width, height)
            if (existing = @backing[name])
              return if existing[:width] == width && existing[:height] == height

              raise LoweringError,
                    "backing buffer #{name.inspect} is declared with two different sizes " \
                    "(#{existing[:width]}x#{existing[:height]} and #{width}x#{height})"
            end

            base = @memory.alloc(((width * height * 2) + 3) & ~3) # bytes, rounded up to a word
            @backing[name] = { width: width, height: height, base: base }
          end

          # A backing buffer's layout, or a friendly error if it was never declared.
          def backing_info(name)
            @backing[name] ||
              raise(LoweringError,
                    "backing buffer #{name.inspect} was used before it was created — " \
                    "declare it first (a sprite does this for you)")
          end

          def head_var(name)
            :"#{name}__head"
          end

          def length_var(name)
            :"#{name}__len"
          end

          # list_new: reset the list to empty. Its storage is already reserved (see
          # register_list); this just zeroes head and length. The slot contents are
          # left as-is — nothing reads them until a push makes them live.
          def emit_list_new(node)
            info = list_info(node.name)
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, head_var(node.name)) if info[:ring]
            @primitives.store_var(ACC, length_var(node.name))
          end

          # list_push: append at the tail — slot (head + length) & mask — then grow
          # length by one. If the list is already full the push is dropped rather than
          # overwriting the oldest item (hardware has no way to raise, so it stays
          # safe and quiet; the interpreter is what flags the overflow in testing).
          def emit_list_push(node)
            info = list_info(node.name)
            length = length_var(node.name)

            @primitives.load_var(ACC, length)            # r0 = length (the tail offset)
            @emitter.emit(ASM.load_immediate(TMP, info[:capacity]))
            @emitter.emit(ASM.cmp_reg(ACC, TMP))                  # length - capacity
            skip = @emitter.gensym
            @emitter.emit_branch(:bcond, skip, cond: :ge)         # full => drop the push

            emit_slot_address(info, node.name)         # r1 = &slot[(head+length)&mask]
            @emitter.emit(ASM.push(TMP))                          # hold the address across the value eval
            @lowering.value(node.value)                     # r0 = value
            @emitter.emit(ASM.pop(TMP))                           # r1 = address
            emit_store_element(info, ACC, TMP)                    # slot = value

            @primitives.load_var(ACC, length)                        # length += 1
            @emitter.emit(ASM.add_imm(ACC, ACC, 1))
            @primitives.store_var(ACC, length)
            @emitter.place_label(skip)
          end

          # list_drop: remove one item. A shift (:front) advances head past the oldest
          # item; a pop (:back) just forgets the newest. Either way length shrinks by
          # one. An empty list is left untouched (length never goes negative).
          def emit_list_drop(node)
            info = list_info(node.name)
            head = head_var(node.name)
            length = length_var(node.name)

            @primitives.load_var(ACC, length)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            skip = @emitter.gensym
            @emitter.emit_branch(:bcond, skip, cond: :eq)         # empty => nothing to drop

            if node.from == :front
              @primitives.load_var(ACC, head)                        # head = (head + 1) & mask
              @emitter.emit(ASM.add_imm(ACC, ACC, 1))
              @primitives.emit_and_const(ACC, ACC, info[:mask], TMP)
              @primitives.store_var(ACC, head)
            end

            @primitives.load_var(ACC, length)                        # length -= 1
            @emitter.emit(ASM.sub_imm(ACC, ACC, 1))
            @primitives.store_var(ACC, length)
            @emitter.place_label(skip)
          end

          # list_set: overwrite the item at an index. The masked address confines the
          # write to the list's own slots, so an out-of-range index scribbles a stale
          # slot at worst, never a neighbouring variable.
          def emit_list_set(node)
            info = list_info(node.name)

            @lowering.value(node.index)                     # r0 = index
            emit_slot_address(info, node.name)         # r1 = &slot[(head+index)&mask]
            @emitter.emit(ASM.push(TMP))
            @lowering.value(node.value)                     # r0 = value
            @emitter.emit(ASM.pop(TMP))                           # r1 = address
            emit_store_element(info, ACC, TMP)                    # slot = value
          end

          # list_get: read the item at an index into the accumulator (a value).
          def eval_list_get(node)
            info = list_info(node.name)
            @lowering.value(node.index)                     # r0 = index
            emit_slot_address(info, node.name)         # r1 = &slot[(head+index)&mask]
            emit_load_element(info, ACC, TMP)                     # r0 = slot
          end

          # list_len: read the length variable into the accumulator (a value).
          def eval_list_len(node)
            list_info(node.name)
            @primitives.load_var(ACC, length_var(node.name))
          end

          private

          # Turn an offset (already in r0 — an index, or length for a push) into the physical
          # slot address. Clobbers r0/r1 and the list's address register; leaves the address
          # in TMP (r1), ready for ldr/str.
          #
          # A ring adds its head and wraps with the mask. A plain array's head can never move,
          # so the offset IS the slot — which saves a variable read and an add on every access,
          # and costs a compare instead of the mask to keep a bad index inside the block.
          #
          # THE LIST'S OWN BASE IS LEFT WHERE IT WAS PUT and the slot address built somewhere
          # else, which is the whole reason a second touch of the same list is cheaper than
          # the first: the base outlives the access instead of being written over by its
          # answer. A variable has always worked this way — a register holds where the
          # variables start and each one rides a distance from it — and a list did not, so a
          # list rebuilt an address that had not changed since the cartridge was built, three
          # instructions at a time, in the hottest loop a game has.
          def emit_slot_address(info, name)
            if info[:ring]
              @primitives.load_var(TMP, head_var(name))            # r1 = head
              @emitter.emit(ASM.add_reg(ACC, TMP, ACC))            # r0 = head + offset
              @primitives.emit_and_const(ACC, ACC, info[:mask], TMP) # r0 = slot (ring-wrapped)
            else
              emit_bound_to_capacity(info[:capacity])              # r0 = slot, or nought
            end
            shift = Math.log2(info[:bytes]).to_i                   # 4 bytes -> 2, 2 -> 1, 1 -> 0
            @emitter.emit(ASM.lsl_imm(ACC, ACC, shift)) if shift.positive? # r0 = slot * elem size
            @primitives.emit_list_base(info[:base])               # r9 = base address, often already there
            @emitter.emit(ASM.add_reg(TMP, LIST_ADDR, ACC))       # r1 = base + slot*size
          end

          # LOAD AND STORE ONE ELEMENT at the address in +addr+, at the list's own width. A
          # word list is one instruction either way; a narrower one is the same instruction
          # with the size bits set, so a narrow list is no slower to read or write — it is
          # only smaller.
          #
          # A NARROW ELEMENT IS READ BACK SIGN-EXTENDED, filling the whole register with the
          # number it holds including its sign, so what comes out of a byte slot holding -4 is
          # -4 and not 252. That is why there is no unsigned option: a slot that could not come
          # back negative would break every countdown written `sub` first and tested second.
          def emit_load_element(info, into, addr)
            case info[:width]
            when :word then @emitter.emit(ASM.ldr(into, addr))
            when :half then @emitter.emit(ASM.ldrsh(into, addr))
            when :byte then @emitter.emit(ASM.ldrsb(into, addr))
            end
          end

          # ...and the store, which keeps only the low bits that fit. A value too big for the
          # width is cut down rather than reaching the element next door — the same bargain
          # the index bound makes, and the interpreter cuts it down to exactly the same number.
          def emit_store_element(info, from, addr)
            case info[:width]
            when :word then @emitter.emit(ASM.str(from, addr))
            when :half then @emitter.emit(ASM.store_halfword(from, addr))
            when :byte then @emitter.emit(ASM.strb(from, addr))
            end
          end

          # Hold r0 inside 0...capacity, reading slot nought for anything outside it. The
          # compare is UNSIGNED, which is what catches a negative index too: as an unsigned
          # number it is enormous, so it fails the same test. Predicated rather than branched,
          # so there is no jump in the hottest thing a list does.
          def emit_bound_to_capacity(capacity)
            if ASM.encode_rotated_immediate(capacity)
              @emitter.emit(ASM.cmp_imm(ACC, capacity))
            else
              @emitter.emit(ASM.load_immediate(TMP, capacity))
              @emitter.emit(ASM.cmp_reg(ACC, TMP))
            end
            @emitter.emit(ASM.mov_imm_cond(:hs, ACC, 0))
          end
        end
      end
    end
  end
end
