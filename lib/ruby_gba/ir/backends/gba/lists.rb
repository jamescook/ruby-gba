# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # A list is stored as a ring buffer in IWRAM: a fixed block of `capacity`
        # 4-byte slots, plus two hidden variables — `head` (the index of the oldest
        # item) and `length` (how many items are live). The item logically at
        # position i sits in the physical slot (head + i) & mask, where mask is
        # capacity-1. Because capacity is a power of two, that wrap is a single
        # bitwise AND — no division — and because the AND confines every access to
        # the list's own block, a bad index can read a stale slot but can never
        # reach a neighbouring variable. This mirrors the interpreter's list exactly
        # (same items readable, same length, same overflow point); the interpreter's
        # friendly errors catch logic bugs in testing, and here the hardware just
        # stays bounded.
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
          def register_list(name, capacity)
            if (existing = @lists[name])
              return if existing[:capacity] == capacity

              raise LoweringError,
                    "list #{name.inspect} is created with two different capacities " \
                    "(#{existing[:capacity]} and #{capacity})"
            end

            base = @memory.alloc(capacity * 4) # the ring's slots
            @primitives.var_addr(head_var(name))  # head and length, allocated alongside
            @primitives.var_addr(length_var(name))
            @lists[name] = { capacity: capacity, mask: capacity - 1, base: base }
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
            list_info(node.name)
            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, head_var(node.name))
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

            emit_slot_address(info, node.name)         # r12 = &slot[(head+length)&mask]
            @emitter.emit(ASM.push(ADDR))                         # hold the address across the value eval
            @lowering.value(node.value)                     # r0 = value
            @emitter.emit(ASM.pop(TMP))                           # r1 = address
            @emitter.emit(ASM.str(ACC, TMP))                      # slot = value

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
            emit_slot_address(info, node.name)         # r12 = &slot[(head+index)&mask]
            @emitter.emit(ASM.push(ADDR))
            @lowering.value(node.value)                     # r0 = value
            @emitter.emit(ASM.pop(TMP))                           # r1 = address
            @emitter.emit(ASM.str(ACC, TMP))                      # slot = value
          end

          # list_get: read the item at an index into the accumulator (a value).
          def eval_list_get(node)
            info = list_info(node.name)
            @lowering.value(node.index)                     # r0 = index
            emit_slot_address(info, node.name)         # r12 = &slot[(head+index)&mask]
            @emitter.emit(ASM.ldr(ACC, ADDR))                     # r0 = slot
          end

          # list_len: read the length variable into the accumulator (a value).
          def eval_list_len(node)
            list_info(node.name)
            @primitives.load_var(ACC, length_var(node.name))
          end

          private

          # Turn an offset-from-head (already in r0 — an index, or length for a push)
          # into the physical slot address in r12: base + ((head + offset) & mask)*4.
          # Clobbers r0/r1; leaves the address in ADDR (r12), ready for ldr/str.
          def emit_slot_address(info, name)
            @primitives.load_var(TMP, head_var(name))                # r1 = head
            @emitter.emit(ASM.add_reg(ACC, TMP, ACC))             # r0 = head + offset
            @primitives.emit_and_const(ACC, ACC, info[:mask], TMP)   # r0 = slot (ring-wrapped)
            @emitter.emit(ASM.lsl_imm(ACC, ACC, 2))               # r0 = slot * 4 bytes
            @emitter.emit(ASM.load_immediate(TMP, info[:base]))   # r1 = base address
            @emitter.emit(ASM.add_reg(ADDR, TMP, ACC))            # r12 = base + slot*4
          end
        end
      end
    end
  end
end
