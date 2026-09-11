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
          include Constants

          def initialize(memory:, primitives:, emitter:, lowering:)
            @memory = memory
            @primitives = primitives
            @emitter = emitter
            @lowering = lowering
            @lists = {}
            @backing = {}
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

              raise LoweringError, no_room_anywhere(name, want) if fast == false
            end
            [@memory.alloc(want), false]
          end

          def no_room_anywhere(name, want)
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
