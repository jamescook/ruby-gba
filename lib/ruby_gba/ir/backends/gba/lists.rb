# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Lists and the sprite backing store — their IWRAM layout and ops — plus func/case.
        module Lists
          include Constants

          #
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

            base = @next_var
            @next_var += capacity * 4 # the ring's slots
            var_addr(head_var(name))  # head and length, allocated alongside
            var_addr(length_var(name))
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

            base = @next_var
            @next_var += ((width * height * 2) + 3) & ~3 # bytes, rounded up to a word
            @backing[name] = { width: width, height: height, base: base }
          end

          # A backing buffer's layout, or a friendly error if it was never declared.
          def backing_info(name)
            @backing[name] ||
              raise(LoweringError,
                    "backing buffer #{name.inspect} was used before it was created — " \
                    "declare it first (a sprite does this for you)")
          end

          def backing_region_unsupported_in_buffered!
            raise LoweringError,
                  "A sprite's save and restore cannot run on the tear-free screen (`tear_free: true`). Its " \
                  "backing store holds direct colors, and that screen stores colors as color-table indices. " \
                  "To use sprites, use the direct-color screen: drop `tear_free:`."
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
            list_info(node[:name])
            emit(ASM.load_immediate(ACC, 0))
            store_var(ACC, head_var(node[:name]))
            store_var(ACC, length_var(node[:name]))
          end

          # list_push: append at the tail — slot (head + length) & mask — then grow
          # length by one. If the list is already full the push is dropped rather than
          # overwriting the oldest item (hardware has no way to raise, so it stays
          # safe and quiet; the interpreter is what flags the overflow in testing).
          def emit_list_push(node)
            info = list_info(node[:name])
            length = length_var(node[:name])

            load_var(ACC, length)                        # r0 = length (the tail offset)
            emit(ASM.load_immediate(TMP, info[:capacity]))
            emit(ASM.cmp_reg(ACC, TMP))                  # length - capacity
            skip = gensym
            emit_branch(:bcond, skip, cond: :ge)         # full => drop the push

            emit_slot_address(info, node[:name])         # r12 = &slot[(head+length)&mask]
            emit(ASM.push(ADDR))                         # hold the address across the value eval
            eval_value(node[:value])                     # r0 = value
            emit(ASM.pop(TMP))                           # r1 = address
            emit(ASM.str(ACC, TMP))                      # slot = value

            load_var(ACC, length)                        # length += 1
            emit(ASM.add_imm(ACC, ACC, 1))
            store_var(ACC, length)
            place_label(skip)
          end

          # list_drop: remove one item. A shift (:front) advances head past the oldest
          # item; a pop (:back) just forgets the newest. Either way length shrinks by
          # one. An empty list is left untouched (length never goes negative).
          def emit_list_drop(node)
            info = list_info(node[:name])
            head = head_var(node[:name])
            length = length_var(node[:name])

            load_var(ACC, length)
            emit(ASM.cmp_imm(ACC, 0))
            skip = gensym
            emit_branch(:bcond, skip, cond: :eq)         # empty => nothing to drop

            if node[:from] == :front
              load_var(ACC, head)                        # head = (head + 1) & mask
              emit(ASM.add_imm(ACC, ACC, 1))
              emit_and_const(ACC, ACC, info[:mask], TMP)
              store_var(ACC, head)
            end

            load_var(ACC, length)                        # length -= 1
            emit(ASM.sub_imm(ACC, ACC, 1))
            store_var(ACC, length)
            place_label(skip)
          end

          # list_set: overwrite the item at an index. The masked address confines the
          # write to the list's own slots, so an out-of-range index scribbles a stale
          # slot at worst, never a neighbouring variable.
          def emit_list_set(node)
            info = list_info(node[:name])

            eval_value(node[:index])                     # r0 = index
            emit_slot_address(info, node[:name])         # r12 = &slot[(head+index)&mask]
            emit(ASM.push(ADDR))
            eval_value(node[:value])                     # r0 = value
            emit(ASM.pop(TMP))                           # r1 = address
            emit(ASM.str(ACC, TMP))                      # slot = value
          end

          # list_get: read the item at an index into the accumulator (a value).
          def eval_list_get(node)
            info = list_info(node[:name])
            eval_value(node[:index])                     # r0 = index
            emit_slot_address(info, node[:name])         # r12 = &slot[(head+index)&mask]
            emit(ASM.ldr(ACC, ADDR))                     # r0 = slot
          end

          # list_len: read the length variable into the accumulator (a value).
          def eval_list_len(node)
            list_info(node[:name])
            load_var(ACC, length_var(node[:name]))
          end

          # Turn an offset-from-head (already in r0 — an index, or length for a push)
          # into the physical slot address in r12: base + ((head + offset) & mask)*4.
          # Clobbers r0/r1; leaves the address in ADDR (r12), ready for ldr/str.
          def emit_slot_address(info, name)
            load_var(TMP, head_var(name))                # r1 = head
            emit(ASM.add_reg(ACC, TMP, ACC))             # r0 = head + offset
            emit_and_const(ACC, ACC, info[:mask], TMP)   # r0 = slot (ring-wrapped)
            emit(ASM.lsl_imm(ACC, ACC, 2))               # r0 = slot * 4 bytes
            emit(ASM.load_immediate(TMP, info[:base]))   # r1 = base address
            emit(ASM.add_reg(ADDR, TMP, ACC))            # r12 = base + slot*4
          end

          # Func bodies live after the main code. A leading endless loop guards
          # against the main flow running off its end into the first body. Each func
          # saves the return address and restores it as the program counter.
          # The routines that stay in the cartridge. The ones chosen to run from the
          # console's quick memory are emitted separately, as one block (see
          # {Placement}#emit_hot_functions), because that block is copied wholesale.
          def emit_functions
            cold = @funcs.reject { |name, _| @fast_funcs.include?(name) }
            return if cold.empty?

            emit(ASM.loop_forever) # fall-through guard
            cold.each { |name, fnode| emit_one_function(name, fnode) }
          end

          # One routine: save the return address, run the body, return. Shared by both
          # places routines are emitted, so where a routine lives cannot change what it
          # does.
          def emit_one_function(name, fnode)
            start = pos
            place_label(func_label(name))
            emit(ASM.push(14))                          # push {lr}
            # Draws in this func lower in its resolved mode; a scene (a per-frame
            # entry point) also switches the hardware to that mode as it takes over.
            @lower_mode = @func_mode.fetch(name, @default_mode)
            emit_scene_preamble(name) if @manage_modes && @scene_funcs.include?(name)
            fnode.children.each { |stmt| emit_statement(stmt) }
            emit(ASM.pop(15))                           # pop {pc}  (return)
            @func_ranges[name] = (start...pos)          # byte span, for dump_func
          end

          def func_label(name)
            "func_#{name}"
          end

          # Multi-way dispatch lowers to one "if the variable equals this value, call
          # that scene" per clause — reusing the ordinary if/compare/call path. Each
          # comparison reloads the variable from memory itself, so a scene call is free
          # to clobber every register without disturbing the dispatch.
          def emit_case(node)
            node[:clauses].each do |value, target|
              test = Build.binop(:==, Build.var_ref(node[:var]), Build.int(value))
              emit_statement(Build.if_(test, Build.call(target)))
            end
          end
        end
      end
    end
  end
end
