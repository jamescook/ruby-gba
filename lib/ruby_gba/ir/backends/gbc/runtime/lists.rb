# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        module Runtime
          # A GAME'S LISTS, as the interpreter means them (Reference::ListValue): a ring
          # of slots, the oldest item at +front+, so taking from the front moves where the front is
          # rather than every item. A slot is the width the game declared — a byte, a half or a whole
          # word — which matters on a machine with 8K of memory: a number too big for its slot keeps
          # its low bits and reads back with the slot's top bit as its sign, 200 in a byte reading
          # -56, exactly as the interpreter does it.
          #
          # In work memory a list is a header of HEADER bytes and then its slots:
          #
          #   +0 capacity (16 bits)   +2 slot width in bytes   +3 nothing   +4 front (16 bits)
          #   +6 length (16 bits)
          #
          # An index out of range, a push onto a full list or a pop from an empty one stops the game
          # (Frame's rt_fault), as it stops the interpreter's, with the list and the numbers kept so a
          # reader can say what happened in the interpreter's words.
          module Lists
            HEADER = 8
            CAPACITY = 0
            WIDTH = 2
            FRONT = 4
            LENGTH = 6

            module_function

            def emit(asm, memory)
              q = Quick.for(memory)
              emit_helpers(asm, memory, q)
              emit_routines(asm, memory, q)
              emit_start(asm)
            end

            # Where the routines keep the list they are working on, in quick memory.
            Quick = Data.define(:list, :capacity, :width, :front, :length, :entry) do
              def self.for(memory) = new(list: memory.quick(2), capacity: memory.quick(2), width: memory.quick(1),
                                         front: memory.quick(2), length: memory.quick(2), entry: memory.quick(4))
            end

            def arg(memory, i, n) = Calls.arg(memory, i, n)

            # Where rt_list_get_taken reads the list's place and the index, [list, index], for a
            # caller that writes them there itself (Lowering#value_of_list_get).
            def get_places(memory) = [arg(memory, 0, 2), arg(memory, 1, 2)]

            # The low byte of where argument +i+ of +n+ is: the routines find it with LDH (C).
            def arg_at(memory, i, n) = arg(memory, i, n) & 0xFF

            def emit_helpers(asm, memory, q)
              # The list whose address is argument A (an address in quick memory): its header copied
              # into quick memory, and HL its address.
              asm.label("rt_list_open")
              asm.load(:c, :a)
              asm.load_high(:a, [:c])
              asm.load(:l, :a)
              asm.load_high(q.list, :a)
              asm.inc(:c)
              asm.load_high(:a, [:c])
              asm.load(:h, :a)
              asm.load_high(q.list + 1, :a)
              asm.push(:hl)
              # The header in the order it is kept, read once along it: the byte after the width
              # is nothing, and is stepped over.
              at = 0
              { capacity: [CAPACITY, 2], width: [WIDTH, 1], front: [FRONT, 2], length: [LENGTH, 2] }.each do |field, (offset, bytes)|
                raise ArgumentError, "the list header's fields are read in the order they are kept" if offset < at

                (offset - at).times { asm.inc(:hl) }
                bytes.times do |i|
                  asm.load(:a, [:hli])
                  asm.load_high(q.public_send(field) + i, :a)
                end
                at = offset + bytes
              end
              asm.pop(:hl)
              asm.ret

              # The front and the length written back into the list's header.
              asm.label("rt_list_close")
              list_address(asm, q)
              FRONT.times { asm.inc(:hl) }
              %i[front length].each do |field|
                2.times do |i|
                  asm.load_high(:a, q.public_send(field) + i)
                  asm.load([:hli], :a)
                end
              end
              asm.ret

              # DE = the slot an item DE places from the front is in: front + DE, come round past
              # the capacity. Both are below the capacity, so one subtraction is enough.
              asm.label("rt_list_slot")
              asm.load_high(:a, q.front)
              asm.add_a(:e)
              asm.load(:e, :a)
              asm.load_high(:a, q.front + 1)
              asm.adc_a(:d)
              asm.load(:d, :a)
              asm.load_high(:a, q.capacity)
              asm.load(:l, :a)
              asm.load_high(:a, q.capacity + 1)
              asm.load(:h, :a)
              asm.load(:a, :e)
              asm.sub_a(:l)
              asm.load(:c, :a)
              asm.load(:a, :d)
              asm.sbc_a(:h)
              asm.ret(:c) # below the capacity: DE as it is
              asm.load(:d, :a)
              asm.load(:e, :c)
              asm.ret

              # HL = the address of slot DE: the slots start after the header, a width apart.
              asm.label("rt_list_slot_address")
              asm.load_high(:a, q.width)
              asm.load(:b, :a)
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.label("rt_list_slot_address_wide") # HL = DE × width, by doubling
              asm.srl(:b)
              asm.jump_relative(:z, "rt_list_slot_address_done")
              asm.add_hl(:hl)
              asm.jump_relative("rt_list_slot_address_wide")
              asm.label("rt_list_slot_address_done")
              asm.load(:de, HEADER)
              asm.add_hl(:de)
              asm.load_high(:a, q.list)
              asm.load(:e, :a)
              asm.load_high(:a, q.list + 1)
              asm.load(:d, :a)
              asm.add_hl(:de)
              asm.ret

              # BCDE written into the slot at HL, as wide as the list's slots are.
              asm.label("rt_list_write")
              asm.load(:a, :e)
              asm.load([:hli], :a)
              asm.load_high(:a, q.width)
              asm.cp_a(1)
              asm.ret(:z)
              asm.load(:a, :d)
              asm.load([:hli], :a)
              asm.load_high(:a, q.width)
              asm.cp_a(2)
              asm.ret(:z)
              asm.load(:a, :c)
              asm.load([:hli], :a)
              asm.load([:hl], :b)
              asm.ret

              # BCDE = the slot at HL, a narrow one widened with its top bit as the sign.
              asm.label("rt_list_read")
              asm.load_high(:a, q.width)
              asm.cp_a(1)
              asm.jump(:z, "rt_read_int8")
              asm.cp_a(2)
              asm.jump(:z, "rt_read_int16")
              asm.jump("rt_read_int32")

              # The index at argument (A) checked against the list's length: DE the slot it names
              # if it is in range; the game stopped if not.
              asm.label("rt_list_index")
              asm.load(:c, :a)
              asm.push(:bc)
              asm.load_high(:a, [:c])
              asm.load(:e, :a)
              asm.inc(:c)
              asm.load_high(:a, [:c])
              asm.load(:d, :a)
              asm.inc(:c)
              asm.load_high(:a, [:c])
              asm.inc(:c)
              asm.load(:b, :a)
              asm.load_high(:a, [:c])
              asm.or_a(:b)
              asm.jump_relative(:nz, "rt_list_index_bad") # past 16 bits, or below nought
              asm.load_high(:a, q.length)
              asm.load(:l, :a)
              asm.load_high(:a, q.length + 1)
              asm.load(:h, :a)
              asm.load(:a, :e)
              asm.sub_a(:l)
              asm.load(:a, :d)
              asm.sbc_a(:h)
              asm.jump_relative(:nc, "rt_list_index_bad") # not below the length
              asm.pop(:bc)
              asm.jump("rt_list_slot")
              asm.label("rt_list_index_bad")
              asm.pop(:bc)
              asm.load(:hl, memory[Frame::FAULT] + 3)
              4.times do
                asm.load_high(:a, [:c])
                asm.inc(:c)
                asm.load([:hli], :a)
              end
              asm.load_high(:a, q.length)
              asm.load([:hli], :a)
              asm.load_high(:a, q.length + 1)
              asm.load([:hli], :a)
              asm.xor_a(:a)
              asm.load([:hli], :a)
              asm.load([:hl], :a)
              asm.load(:a, Frame::INDEX_OUT_OF_RANGE)
              asm.jump("rt_list_fault")

              # The list into the fault's record, and the game stopped with what went wrong (A).
              asm.label("rt_list_fault")
              asm.push(:af)
              asm.load_high(:a, q.list)
              asm.load([memory[Frame::FAULT] + 1], :a)
              asm.load_high(:a, q.list + 1)
              asm.load([memory[Frame::FAULT] + 2], :a)
              asm.pop(:af)
              asm.jump("rt_fault")
            end

            # HL = the list's address, from quick memory.
            def list_address(asm, q)
              asm.load_high(:a, q.list)
              asm.load(:l, :a)
              asm.load_high(:a, q.list + 1)
              asm.load(:h, :a)
            end

            # BCDE = the 32-bit number at quick-memory address +at+.
            def load_arg(asm, at)
              %i[e d c b].each_with_index do |reg, i|
                asm.load_high(:a, at + i)
                asm.load(reg, :a)
              end
            end

            def take_args(asm, count)
              asm.load_hl_sp(2)
              asm.load(:b, 4 * count)
              asm.call("rt_take_args")
            end

            def emit_routines(asm, memory, q)
              # rt_list_empty(list)
              asm.label("rt_list_empty")
              take_args(asm, 1)
              asm.load(:a, arg_at(memory, 0, 1))
              asm.call("rt_list_open")
              asm.xor_a(:a)
              4.times { |i| asm.load_high((i < 2 ? q.front : q.length) + (i % 2), :a) }
              asm.jump("rt_list_close")

              # rt_list_at_capacity(list): the list holds its capacity, from its first slot. What the
              # slots hold is what they held; a list declared full is filled next (rt_list_fill).
              asm.label("rt_list_at_capacity")
              take_args(asm, 1)
              asm.load(:a, arg_at(memory, 0, 1))
              asm.call("rt_list_open")
              asm.xor_a(:a)
              2.times { |i| asm.load_high(q.front + i, :a) }
              2.times do |i|
                asm.load_high(:a, q.capacity + i)
                asm.load_high(q.length + i, :a)
              end
              asm.jump("rt_list_close")

              # rt_list_length(list)
              asm.label("rt_list_length")
              take_args(asm, 1)
              asm.load(:a, arg_at(memory, 0, 1))
              asm.call("rt_list_open")
              asm.load_high(:a, q.length)
              asm.load(:e, :a)
              asm.load_high(:a, q.length + 1)
              asm.load(:d, :a)
              asm.load(:bc, 0)
              asm.ret

              # rt_list_get(list, index); rt_list_get_taken with the two already where it takes them.
              asm.label("rt_list_get")
              take_args(asm, 2)
              asm.label("rt_list_get_taken")
              asm.load(:a, arg_at(memory, 0, 2))
              asm.call("rt_list_open")
              asm.load(:a, arg_at(memory, 1, 2))
              asm.call("rt_list_index")
              asm.call("rt_list_slot_address")
              asm.jump("rt_list_read")

              # rt_list_set(list, index, value)
              asm.label("rt_list_set")
              take_args(asm, 3)
              asm.load(:a, arg_at(memory, 0, 3))
              asm.call("rt_list_open")
              asm.load(:a, arg_at(memory, 1, 3))
              asm.call("rt_list_index")
              asm.call("rt_list_slot_address")
              load_arg(asm, arg(memory, 2, 3))
              asm.jump("rt_list_write")

              # rt_list_push(list, value)
              asm.label("rt_list_push")
              take_args(asm, 2)
              asm.load(:a, arg_at(memory, 0, 2))
              asm.call("rt_list_open")
              asm.load_high(:a, q.length) # full when the length has reached the capacity
              asm.load(:e, :a)
              asm.load_high(:a, q.length + 1)
              asm.load(:d, :a)
              asm.load_high(:a, q.capacity)
              asm.load(:l, :a)
              asm.load_high(:a, q.capacity + 1)
              asm.load(:h, :a)
              asm.load(:a, :e)
              asm.sub_a(:l)
              asm.load(:a, :d)
              asm.sbc_a(:h)
              asm.jump_relative(:nc, "rt_list_push_full")
              asm.push(:de)
              asm.call("rt_list_slot")
              asm.call("rt_list_slot_address")
              load_arg(asm, arg(memory, 1, 2))
              asm.call("rt_list_write")
              asm.pop(:de)
              asm.inc(:de)
              asm.load(:a, :e)
              asm.load_high(q.length, :a)
              asm.load(:a, :d)
              asm.load_high(q.length + 1, :a)
              asm.jump("rt_list_close")
              asm.label("rt_list_push_full")
              fault_numbers(asm, memory, [q.capacity, 2], nil)
              asm.load(:a, Frame::LIST_FULL)
              asm.jump("rt_list_fault")

              # rt_list_drop(list, from_the_front)
              asm.label("rt_list_drop")
              take_args(asm, 2)
              asm.load(:a, arg_at(memory, 0, 2))
              asm.call("rt_list_open")
              asm.load_high(:a, q.length)
              asm.load(:e, :a)
              asm.load_high(:a, q.length + 1)
              asm.load(:d, :a)
              asm.or_a(:e)
              asm.jump_relative(:z, "rt_list_drop_empty")
              asm.dec(:de)
              asm.load(:a, :e)
              asm.load_high(q.length, :a)
              asm.load(:a, :d)
              asm.load_high(q.length + 1, :a)
              asm.load_high(:a, arg(memory, 1, 2))
              asm.and_a(:a)
              asm.jump(:z, "rt_list_close")
              asm.load(:de, 1) # from the front: the front moves on one
              asm.call("rt_list_slot")
              asm.load(:a, :e)
              asm.load_high(q.front, :a)
              asm.load(:a, :d)
              asm.load_high(q.front + 1, :a)
              asm.jump("rt_list_close")
              asm.label("rt_list_drop_empty")
              fault_numbers(asm, memory, [arg(memory, 1, 2), 4], nil)
              asm.load(:a, Frame::LIST_EMPTY)
              asm.jump("rt_list_fault")

              emit_fill(asm, memory, q)
              emit_copy(asm, memory, q)
            end

            # The first and second numbers of the fault's record from quick memory: each [address,
            # bytes], or nil for nought.
            def fault_numbers(asm, memory, first, second)
              [first, second].each_with_index do |(at, bytes), k|
                asm.load(:hl, memory[Frame::FAULT] + 3 + (4 * k))
                4.times do |i|
                  if at && i < bytes
                    asm.load_high(:a, at + i)
                  else
                    asm.xor_a(:a)
                  end
                  asm.load([:hli], :a)
                end
              end
            end

            # rt_list_fill(list, from, count, value): every slot from +from+ for +count+ holds the
            # value. Nothing for a count of nought or less; the first and the last index checked.
            def emit_fill(asm, memory, q)
              asm.label("rt_list_fill")
              take_args(asm, 4)
              count = arg(memory, 2, 4)
              asm.load_high(:a, count + 3)
              asm.bit(7, :a)
              asm.ret(:nz)
              asm.load_high(:a, count)
              asm.load(:b, :a)
              (1..3).each do |i|
                asm.load_high(:a, count + i)
                asm.or_a(:b)
                asm.load(:b, :a)
              end
              asm.ret(:z)
              asm.load(:a, arg_at(memory, 0, 4))
              asm.call("rt_list_open")
              asm.load(:a, arg_at(memory, 1, 4))
              asm.call("rt_list_index")
              # The last index, from + count - 1, worked out as the interpreter's sum wraps, into the
              # place the first one was (it is not needed again: the slots follow from the first).
              from = arg(memory, 1, 4)
              asm.push(:de)
              load_arg(asm, count)
              asm.load(:hl, from)
              asm.call("rt_add32")
              asm.call("rt_dec32")
              asm.load(:hl, from)
              %i[e d c b].each do |reg|
                asm.load(:a, reg)
                asm.load([:hli], :a)
              end
              asm.load(:a, from & 0xFF)
              asm.call("rt_list_index")
              asm.pop(:de) # the first slot
              asm.load_high(:a, count)
              asm.load(:c, :a)
              asm.load_high(:a, count + 1)
              asm.load(:b, :a) # BC = how many: below the length, so 16 bits
              asm.label("rt_list_fill_loop")
              asm.push(:bc)
              asm.push(:de)
              asm.call("rt_list_slot_address")
              load_arg(asm, arg(memory, 3, 4))
              asm.call("rt_list_write")
              asm.pop(:de) # the next slot, come round past the capacity
              asm.inc(:de)
              asm.load_high(:a, q.capacity)
              asm.cp_a(:e)
              asm.jump_relative(:nz, "rt_list_fill_next")
              asm.load_high(:a, q.capacity + 1)
              asm.cp_a(:d)
              asm.jump_relative(:nz, "rt_list_fill_next")
              asm.load(:de, 0)
              asm.label("rt_list_fill_next")
              asm.pop(:bc)
              asm.dec(:bc)
              asm.load(:a, :b)
              asm.or_a(:c)
              asm.jump_relative(:nz, "rt_list_fill_loop")
              asm.ret
            end

            # rt_list_copy(list, table, kept, table_length, at, count): the list made to hold the
            # +count+ entries of the table from +at+ (held inside the table), oldest first.
            def emit_copy(asm, memory, q)
              asm.label("rt_list_copy")
              take_args(asm, 6)
              asm.load(:a, arg_at(memory, 0, 6))
              asm.call("rt_list_open")
              count = arg(memory, 5, 6)
              table_length = arg(memory, 3, 6)
              at = arg(memory, 4, 6)
              # More than the list holds, or than the table has: the game goes wrong.
              asm.load_high(:a, q.capacity)
              asm.load(:e, :a)
              asm.load_high(:a, q.capacity + 1)
              asm.load(:d, :a)
              asm.load(:bc, 0)
              asm.push(:bc)
              asm.push(:de)
              load_arg(asm, count)
              asm.load_hl_sp(0)
              asm.call("rt_cmp32")
              asm.add_sp(4)
              asm.cp_a(2)
              asm.jump_relative(:nz, "rt_list_copy_fits")
              fault_numbers(asm, memory, [count, 4], [q.capacity, 2])
              asm.load(:a, Frame::COPY_TOO_LONG)
              asm.jump("rt_list_fault")
              asm.label("rt_list_copy_fits")
              load_arg(asm, count)
              asm.load(:hl, table_length)
              asm.call("rt_cmp32")
              asm.cp_a(2)
              asm.jump_relative(:nz, "rt_list_copy_in_table")
              fault_numbers(asm, memory, [count, 4], [table_length, 4])
              asm.load(:a, Frame::COPY_PAST_TABLE)
              asm.jump("rt_list_fault")
              asm.label("rt_list_copy_in_table")
              # The first entry: at, held between 0 and table_length - count (kept in the table's
              # length's place, which is not needed again).
              load_arg(asm, table_length)
              asm.load(:hl, count)
              asm.call("rt_sub32")
              asm.push(:bc)
              asm.push(:de)
              asm.load(:bc, 0)
              asm.load(:de, 0)
              asm.push(:bc)
              asm.push(:de)
              load_arg(asm, at)
              asm.load_hl_sp(0)
              asm.call("rt_clamp32")
              asm.add_sp(8)
              asm.load(:a, :e)
              asm.load_high(at, :a)
              asm.load(:a, :d)
              asm.load_high(at + 1, :a)
              # The list holds count items from its first slot.
              asm.xor_a(:a)
              asm.load_high(q.front, :a)
              asm.load_high(q.front + 1, :a)
              asm.load_high(:a, count)
              asm.load_high(q.length, :a)
              asm.load_high(:a, count + 1)
              asm.load_high(q.length + 1, :a)
              asm.call("rt_list_close")
              asm.load(:de, 0)
              asm.label("rt_list_copy_loop")
              asm.load_high(:a, count) # done when the slot reaches the count
              asm.cp_a(:e)
              asm.jump_relative(:nz, "rt_list_copy_one")
              asm.load_high(:a, count + 1)
              asm.cp_a(:d)
              asm.ret(:z)
              asm.label("rt_list_copy_one")
              asm.push(:de)
              asm.load_high(:a, at) # HL = the table's index: the first entry, and this many on
              asm.add_a(:e)
              asm.load(:l, :a)
              asm.load_high(:a, at + 1)
              asm.adc_a(:d)
              asm.load(:h, :a)
              asm.call("rt_list_table_entry")
              asm.pop(:de)
              asm.push(:de)
              asm.call("rt_list_slot_address")
              load_arg(asm, q.entry)
              asm.call("rt_list_write")
              asm.pop(:de)
              asm.inc(:de)
              asm.jump_relative("rt_list_copy_loop")

              # The table's entry at index HL, kept the way argument 2 says (GBC::Lowering::TABLE_KEPT:
              # 0 a signed byte, 1 a byte, 2 a signed half, 3 a half, 4 a word), into q.entry.
              kept = arg(memory, 2, 6)
              table = arg(memory, 1, 6)
              asm.label("rt_list_table_entry")
              asm.load_high(:a, kept)
              asm.cp_a(2)
              asm.jump_relative(:c, "rt_list_table_entry_at")
              asm.add_hl(:hl)
              asm.cp_a(4)
              asm.jump_relative(:c, "rt_list_table_entry_at")
              asm.add_hl(:hl)
              asm.label("rt_list_table_entry_at")
              asm.load_high(:a, table)
              asm.load(:e, :a)
              asm.load_high(:a, table + 1)
              asm.load(:d, :a)
              asm.add_hl(:de)
              asm.load_high(:a, kept)
              %w[rt_read_int8 rt_read_uint8 rt_read_int16 rt_read_uint16].each_with_index do |reader, kind|
                asm.cp_a(kind)
                asm.jump_relative(:nz, "rt_list_table_entry_#{kind + 1}")
                asm.call(reader)
                asm.jump_relative("rt_list_table_entry_kept")
                asm.label("rt_list_table_entry_#{kind + 1}")
              end
              asm.call("rt_read_int32")
              asm.label("rt_list_table_entry_kept")
              %i[e d c b].each_with_index do |reg, i|
                asm.load(:a, reg)
                asm.load_high(q.entry + i, :a)
              end
              asm.ret
            end

            def emit_start(asm)
              # Every list's capacity and slot width into its header, from the table the compiler
              # wrote (Compiler#data_section): an address, a capacity and a width each, ending at an
              # address of nought.
              asm.label("rt_lists_start")
              asm.load(:hl, "game_lists")
              asm.label("rt_lists_start_next")
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.or_a(:e)
              asm.ret(:z)
              3.times do
                asm.load(:a, [:hli])
                asm.load([:de], :a)
                asm.inc(:de)
              end
              asm.jump_relative("rt_lists_start_next")
            end
          end
        end
      end
    end
  end
end
