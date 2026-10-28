# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE LISTS: a game's `list`, and every field of a pool, as the interpreter keeps them
          # (Reference::ListValue) — items added at the back and taken from either end, read and
          # written by index, and the game stopped, in the interpreter's words, by an index outside
          # the list, an item added to a full one or taken from an empty one.
          #
          # A list lives in the far part of work RAM (Memory#reserve_far): a header of four words —
          # its capacity, where its first item is, how many items it holds, and how many bytes a slot
          # takes (1, 2 or 4) — and then its slots. The items go round the slots like a ring, so
          # taking one from the front moves where the first item is rather than every item after it.
          #
          # A slot narrower than a word keeps the low bits of what goes in and reads back with its top
          # bit as the sign: 200 in a byte slot reads -56, as the interpreter has it.
          #
          # Every routine is handed the list's place in R0 (its 24-bit address) and is reached with
          # JSL. The place is copied to a pointer on the direct page, and the list read through it
          # with the long indirect address [pointer],Y, Y being how far into the list.
          module Lists
            CAPACITY = 0
            FRONT = 2
            LENGTH = 4
            WIDTH = 6
            HEADER = 8

            R0 = Memory.register(0)
            R1 = Memory.register(1)
            R2 = Memory.register(2)
            R3 = Memory.register(3)
            R4 = Memory.register(4)
            R5 = Memory.register(5)

            # The direct page the routines work on: the list's pointer (three bytes and a spare), the
            # slot an index names, a count, a table's pointer, and how a table keeps its entries.
            Scratch = Data.define(:list, :slot, :count, :table, :kept)

            # How a table keeps its entries, by the number the lowering hands rt_list_copy: a signed
            # byte, an unsigned byte, a signed half, an unsigned half, a whole word.
            KEPT = { signed_byte: 0, byte: 1, signed_half: 2, half: 3, word: 4 }.freeze

            module_function

            def scratch(memory)
              Scratch.new(list: memory.scratch(4), slot: memory.scratch(2), count: memory.scratch(4),
                          table: memory.scratch(4), kept: memory.scratch(2))
            end

            def emit(asm, memory, s)
              emit_start(asm, s)
              emit_pointer(asm, s)
              emit_empty(asm, s)
              emit_push(asm, s)
              emit_drop(asm, s)
              emit_get_and_set(asm, s)
              emit_fill(asm, s)
              emit_copy(asm, s)
              emit_slot_access(asm, s)
              emit_faults(asm, memory, s)
            end

            # rt_lists_start: every list's header, from the table the lowering writes ("game_lists"):
            # each list's place (three bytes), its capacity and its slot's bytes (a word each), and a
            # place of nought after the last.
            def emit_start(asm, s)
              asm.label("rt_lists_start")
              asm.ldx(0)
              asm.label("rt_lists_start_next")
              asm.lda(asm.long_x("game_lists"))
              asm.sta(asm.direct(s.list))
              asm.lda(asm.long_x("game_lists", 2))
              asm.and_a(0x00FF)
              asm.sta(asm.direct(s.list + 2))
              asm.ora(asm.direct(s.list))
              asm.beq("rt_lists_start_done")
              asm.ldy(CAPACITY)
              asm.lda(asm.long_x("game_lists", 3))
              asm.sta(asm.ind_long_y(s.list))
              asm.ldy(WIDTH)
              asm.lda(asm.long_x("game_lists", 5))
              asm.sta(asm.ind_long_y(s.list))
              asm.txa
              asm.clc
              asm.adc(7)
              asm.tax
              asm.bra("rt_lists_start_next")
              asm.label("rt_lists_start_done")
              asm.rtl
            end

            # rt_list_pointer (JSR): the list at R0 into the pointer.
            def emit_pointer(asm, s)
              asm.label("rt_list_pointer")
              asm.lda(asm.direct(R0))
              asm.sta(asm.direct(s.list))
              asm.lda(asm.direct(R0 + 2))
              asm.sta(asm.direct(s.list + 2))
              asm.rts
            end

            # rt_list_empty: no items. rt_list_at_capacity: as many as it holds, from its first slot
            # (rt_list_fill then says what they are). rt_list_length: R0 = how many it holds.
            def emit_empty(asm, s)
              asm.label("rt_list_empty")
              asm.jsr(asm.abs("rt_list_pointer"))
              asm.lda(0)
              asm.bra("rt_list_empty_length")
              asm.label("rt_list_at_capacity")
              asm.jsr(asm.abs("rt_list_pointer"))
              asm.ldy(CAPACITY)
              asm.lda(asm.ind_long_y(s.list))
              asm.label("rt_list_empty_length")
              asm.ldy(LENGTH)
              asm.sta(asm.ind_long_y(s.list))
              asm.ldy(FRONT)
              asm.lda(0)
              asm.sta(asm.ind_long_y(s.list))
              asm.rtl

              asm.label("rt_list_length")
              asm.jsr(asm.abs("rt_list_pointer"))
              asm.ldy(LENGTH)
              asm.lda(asm.ind_long_y(s.list))
              asm.sta(asm.direct(R0))
              asm.stz(asm.direct(R0 + 2))
              asm.rtl
            end

            # rt_list_push(list, value): the value into the slot after the last item. A full list
            # stops the game.
            def emit_push(asm, s)
              asm.label("rt_list_push")
              asm.jsr(asm.abs("rt_list_pointer"))
              asm.ldy(LENGTH)
              asm.lda(asm.ind_long_y(s.list))
              asm.ldy(CAPACITY)
              asm.cmp(asm.ind_long_y(s.list))
              asm.bcc("rt_list_push_room")
              asm.jmp(asm.abs("rt_list_full"))
              asm.label("rt_list_push_room")
              asm.jsr(asm.abs("rt_list_slot_of_a")) # the slot the length names: just past the last
              asm.lda(asm.direct(R1))
              asm.sta(asm.direct(R2))
              asm.lda(asm.direct(R1 + 2))
              asm.sta(asm.direct(R2 + 2))
              asm.jsr(asm.abs("rt_list_write_slot"))
              asm.ldy(LENGTH)
              asm.lda(asm.ind_long_y(s.list))
              asm.inc
              asm.sta(asm.ind_long_y(s.list))
              asm.rtl
            end

            # rt_list_drop(list, from): the first item taken (from 1) or the last (from 0). An empty
            # list stops the game.
            def emit_drop(asm, s)
              asm.label("rt_list_drop")
              asm.jsr(asm.abs("rt_list_pointer"))
              asm.ldy(LENGTH)
              asm.lda(asm.ind_long_y(s.list))
              asm.bne("rt_list_drop_some")
              asm.jmp(asm.abs("rt_list_empty_fault"))
              asm.label("rt_list_drop_some")
              asm.dec
              asm.sta(asm.ind_long_y(s.list))
              asm.lda(asm.direct(R1))
              asm.beq("rt_list_drop_done")
              asm.ldy(FRONT)
              asm.lda(asm.ind_long_y(s.list))
              asm.inc
              asm.ldy(CAPACITY)
              asm.cmp(asm.ind_long_y(s.list))
              asm.bcc("rt_list_drop_front")
              asm.lda(0)
              asm.label("rt_list_drop_front")
              asm.ldy(FRONT)
              asm.sta(asm.ind_long_y(s.list))
              asm.label("rt_list_drop_done")
              asm.rtl
            end

            # rt_list_get(list, index): R0 = the item. rt_list_set(list, index, value). An index
            # outside the list stops the game before anything is read or written.
            def emit_get_and_set(asm, s)
              asm.label("rt_list_get")
              asm.jsr(asm.abs("rt_list_pointer"))
              asm.jsr(asm.abs("rt_list_slot_of_index"))
              asm.jsr(asm.abs("rt_list_read_slot"))
              asm.rtl

              asm.label("rt_list_set")
              asm.jsr(asm.abs("rt_list_pointer"))
              asm.jsr(asm.abs("rt_list_slot_of_index"))
              asm.jsr(asm.abs("rt_list_write_slot"))
              asm.rtl
            end

            # rt_list_fill(list, from, count, value): count items from +from+ set to the value. A
            # count of nought or less sets none; an index outside the list, first or last, stops the
            # game before anything is written.
            def emit_fill(asm, s)
              asm.label("rt_list_fill")
              asm.jsr(asm.abs("rt_list_pointer"))
              asm.lda(asm.direct(R2 + 2))
              asm.bmi("rt_list_fill_done")
              asm.ora(asm.direct(R2))
              asm.beq("rt_list_fill_done")
              # The first index checked, and then the last (from + count - 1), as the interpreter
              # checks them; the first is kept while R1 is the last.
              asm.lda(asm.direct(R1))
              asm.sta(asm.direct(s.count))
              asm.lda(asm.direct(R1 + 2))
              asm.sta(asm.direct(s.count + 2))
              asm.jsr(asm.abs("rt_list_slot_of_index"))
              asm.clc
              asm.lda(asm.direct(s.count))
              asm.adc(asm.direct(R2))
              asm.sta(asm.direct(R1))
              asm.lda(asm.direct(s.count + 2))
              asm.adc(asm.direct(R2 + 2))
              asm.sta(asm.direct(R1 + 2))
              asm.lda(asm.direct(R1))
              asm.bne("rt_list_fill_last_low")
              asm.dec(asm.direct(R1 + 2))
              asm.label("rt_list_fill_last_low")
              asm.dec(asm.direct(R1))
              asm.jsr(asm.abs("rt_list_slot_of_index"))
              # Then each item from the first: R4 counts them, and R2 holds the value.
              asm.lda(asm.direct(s.count))
              asm.sta(asm.direct(R1))
              asm.stz(asm.direct(R1 + 2))
              asm.lda(asm.direct(R2))
              asm.sta(asm.direct(R4))
              asm.lda(asm.direct(R3))
              asm.sta(asm.direct(R2))
              asm.lda(asm.direct(R3 + 2))
              asm.sta(asm.direct(R2 + 2))
              asm.label("rt_list_fill_item")
              asm.jsr(asm.abs("rt_list_slot_of_index"))
              asm.jsr(asm.abs("rt_list_write_slot"))
              asm.inc(asm.direct(R1))
              asm.dec(asm.direct(R4))
              asm.bne("rt_list_fill_item")
              asm.label("rt_list_fill_done")
              asm.rtl
            end

            # rt_list_copy(list, table, kept, length, at, count): the list made to hold the run of
            # the table's +count+ entries from +at+, held so the run is inside the table (Reference
            # #exec_list_copy). +table+ is the table's 24-bit place, +kept+ how it keeps an entry
            # (KEPT), +length+ how many entries it has.
            def emit_copy(asm, s)
              asm.label("rt_list_copy")
              asm.jsr(asm.abs("rt_list_pointer"))
              asm.lda(asm.direct(R1))
              asm.sta(asm.direct(s.table))
              asm.lda(asm.direct(R1 + 2))
              asm.sta(asm.direct(s.table + 2))
              asm.lda(asm.direct(R2))
              asm.sta(asm.direct(s.kept))
              # The start held to 0..length-count: above first, then below.
              asm.sec
              asm.lda(asm.direct(R3))
              asm.sbc(asm.direct(R5))
              asm.sta(asm.direct(s.count)) # length - count, never below nought
              asm.lda(asm.direct(R4 + 2))
              asm.bmi("rt_list_copy_from_nought")
              asm.bne("rt_list_copy_from_last")
              asm.lda(asm.direct(R4))
              asm.cmp(asm.direct(s.count))
              asm.bcc("rt_list_copy_start")
              asm.label("rt_list_copy_from_last")
              asm.lda(asm.direct(s.count))
              asm.bra("rt_list_copy_start")
              asm.label("rt_list_copy_from_nought")
              asm.lda(0)
              asm.label("rt_list_copy_start")
              asm.sta(asm.direct(s.count + 2)) # the table's entry to read next
              asm.ldy(FRONT)
              asm.lda(0)
              asm.sta(asm.ind_long_y(s.list))
              asm.ldy(LENGTH)
              asm.lda(asm.direct(R5))
              asm.sta(asm.ind_long_y(s.list))
              asm.stz(asm.direct(R4)) # the list's slot to write next
              asm.lda(asm.direct(R5))
              asm.beq("rt_list_copy_done")
              asm.sta(asm.direct(s.count))
              asm.label("rt_list_copy_item")
              asm.jsr(asm.abs("rt_list_copy_entry"))
              asm.lda(asm.direct(R4))
              asm.jsr(asm.abs("rt_list_slot_at"))
              asm.jsr(asm.abs("rt_list_write_slot"))
              asm.inc(asm.direct(R4))
              asm.inc(asm.direct(s.count + 2))
              asm.dec(asm.direct(s.count))
              asm.bne("rt_list_copy_item")
              asm.label("rt_list_copy_done")
              asm.rtl

              # rt_list_copy_entry (JSR): R2 = the table's entry (s.count + 2), widened by how it is
              # kept.
              asm.label("rt_list_copy_entry")
              asm.lda(asm.direct(s.count + 2))
              asm.ldx(asm.direct(s.kept))
              asm.cpx(KEPT[:signed_half])
              asm.bcc("rt_list_copy_entry_bytes")
              asm.asl # a half or a word: two bytes an entry or four
              asm.cpx(KEPT[:word])
              asm.bne("rt_list_copy_entry_offset")
              asm.asl
              asm.bra("rt_list_copy_entry_offset")
              asm.label("rt_list_copy_entry_bytes")
              asm.label("rt_list_copy_entry_offset")
              asm.tay
              asm.lda(asm.ind_long_y(s.table))
              asm.sta(asm.direct(R2))
              asm.stz(asm.direct(R2 + 2))
              asm.cpx(KEPT[:word])
              asm.bne("rt_list_copy_entry_narrow")
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(s.table))
              asm.sta(asm.direct(R2 + 2))
              asm.rts
              asm.label("rt_list_copy_entry_narrow")
              asm.cpx(KEPT[:signed_half])
              asm.bcs("rt_list_copy_entry_half")
              asm.lda(asm.direct(R2))
              asm.and_a(0x00FF)
              asm.sta(asm.direct(R2))
              asm.cpx(KEPT[:byte])
              asm.beq("rt_list_copy_entry_done")
              asm.cmp(0x0080) # a signed byte: its top bit through the rest
              asm.bcc("rt_list_copy_entry_done")
              asm.ora(0xFF00)
              asm.sta(asm.direct(R2))
              asm.dec(asm.direct(R2 + 2))
              asm.rts
              asm.label("rt_list_copy_entry_half")
              asm.cpx(KEPT[:half])
              asm.beq("rt_list_copy_entry_done")
              asm.lda(asm.direct(R2))
              asm.bpl("rt_list_copy_entry_done")
              asm.dec(asm.direct(R2 + 2))
              asm.label("rt_list_copy_entry_done")
              asm.rts
            end

            # THE SLOTS (all reached with JSR):
            #
            #   rt_list_slot_of_index   the slot the index in R1 names, into s.slot as how far into
            #                           the list it is; an index outside the list stops the game
            #   rt_list_slot_of_a       the same for the A-th place after the first item, unchecked
            #   rt_list_slot_at         the same for slot A itself, from the start of the slots
            #   rt_list_read_slot       R0 = what the slot holds, widened by its sign
            #   rt_list_write_slot      R2 into the slot, as many bytes as it takes
            def emit_slot_access(asm, s)
              asm.label("rt_list_slot_of_index")
              asm.lda(asm.direct(R1 + 2))
              asm.bne("rt_list_slot_outside")
              asm.lda(asm.direct(R1))
              asm.ldy(LENGTH)
              asm.cmp(asm.ind_long_y(s.list))
              asm.bcc("rt_list_slot_of_a")
              asm.label("rt_list_slot_outside")
              asm.jmp(asm.abs("rt_list_index_fault"))

              asm.label("rt_list_slot_of_a")
              asm.clc
              asm.ldy(FRONT)
              asm.adc(asm.ind_long_y(s.list))
              asm.ldy(CAPACITY)
              asm.cmp(asm.ind_long_y(s.list))
              asm.bcc("rt_list_slot_at")
              asm.sbc(asm.ind_long_y(s.list)) # the carry is set: once round the ring
              asm.label("rt_list_slot_at")
              asm.sta(asm.direct(s.slot))
              asm.ldy(WIDTH)
              asm.lda(asm.ind_long_y(s.list))
              asm.cmp(2)
              asm.bcc("rt_list_slot_bytes") # a byte a slot
              asm.asl(asm.direct(s.slot))
              asm.cmp(4)
              asm.bcc("rt_list_slot_bytes") # two bytes
              asm.asl(asm.direct(s.slot))
              asm.label("rt_list_slot_bytes")
              asm.lda(asm.direct(s.slot))
              asm.clc
              asm.adc(HEADER)
              asm.sta(asm.direct(s.slot))
              asm.rts

              asm.label("rt_list_read_slot")
              asm.ldy(WIDTH)
              asm.lda(asm.ind_long_y(s.list))
              asm.tax
              asm.ldy(asm.direct(s.slot))
              asm.lda(asm.ind_long_y(s.list))
              asm.sta(asm.direct(R0))
              asm.stz(asm.direct(R0 + 2))
              asm.cpx(4)
              asm.bne("rt_list_read_narrow")
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(s.list))
              asm.sta(asm.direct(R0 + 2))
              asm.rts
              asm.label("rt_list_read_narrow")
              asm.cpx(2)
              asm.beq("rt_list_read_half")
              asm.and_a(0x00FF)
              asm.cmp(0x0080)
              asm.bcc("rt_list_read_byte")
              asm.ora(0xFF00)
              asm.dec(asm.direct(R0 + 2))
              asm.label("rt_list_read_byte")
              asm.sta(asm.direct(R0))
              asm.rts
              asm.label("rt_list_read_half")
              asm.lda(asm.direct(R0))
              asm.bpl("rt_list_read_done")
              asm.dec(asm.direct(R0 + 2))
              asm.label("rt_list_read_done")
              asm.rts

              asm.label("rt_list_write_slot")
              asm.ldy(WIDTH)
              asm.lda(asm.ind_long_y(s.list))
              asm.tax
              asm.ldy(asm.direct(s.slot))
              asm.cpx(1)
              asm.bne("rt_list_write_wide")
              asm.sep(0x20)
              asm.lda(asm.direct(R2))
              asm.sta(asm.ind_long_y(s.list))
              asm.rep(0x20)
              asm.rts
              asm.label("rt_list_write_wide")
              asm.lda(asm.direct(R2))
              asm.sta(asm.ind_long_y(s.list))
              asm.cpx(4)
              asm.bne("rt_list_write_done")
              asm.iny
              asm.iny
              asm.lda(asm.direct(R2 + 2))
              asm.sta(asm.ind_long_y(s.list))
              asm.label("rt_list_write_done")
              asm.rts
            end

            # The game stopped: what went wrong, the list's place, and the numbers that say how,
            # into FAULT for the reader (Frame), then rt_fault.
            def emit_faults(asm, memory, s)
              asm.label("rt_list_full")
              emit_fault_list(asm, memory)
              asm.ldy(CAPACITY)
              asm.lda(asm.ind_long_y(s.list))
              asm.sta(asm.abs(memory[Frame::FAULT], Frame::FAULT_FIRST))
              asm.stz(asm.abs(memory[Frame::FAULT], Frame::FAULT_FIRST + 2))
              asm.lda(Frame::LIST_FULL)
              asm.jml(asm.long("rt_fault"))

              asm.label("rt_list_empty_fault")
              emit_fault_list(asm, memory)
              asm.lda(asm.direct(R1)) # 1 taken from the front, 0 from the back
              asm.sta(asm.abs(memory[Frame::FAULT], Frame::FAULT_FIRST))
              asm.stz(asm.abs(memory[Frame::FAULT], Frame::FAULT_FIRST + 2))
              asm.lda(Frame::LIST_EMPTY)
              asm.jml(asm.long("rt_fault"))

              asm.label("rt_list_index_fault")
              emit_fault_list(asm, memory)
              asm.lda(asm.direct(R1))
              asm.sta(asm.abs(memory[Frame::FAULT], Frame::FAULT_FIRST))
              asm.lda(asm.direct(R1 + 2))
              asm.sta(asm.abs(memory[Frame::FAULT], Frame::FAULT_FIRST + 2))
              asm.ldy(LENGTH)
              asm.lda(asm.ind_long_y(s.list))
              asm.sta(asm.abs(memory[Frame::FAULT], Frame::FAULT_SECOND))
              asm.stz(asm.abs(memory[Frame::FAULT], Frame::FAULT_SECOND + 2))
              asm.lda(Frame::INDEX_OUT_OF_RANGE)
              asm.jml(asm.long("rt_fault"))
            end

            def emit_fault_list(asm, memory)
              asm.lda(asm.direct(R0))
              asm.sta(asm.abs(memory[Frame::FAULT], Frame::FAULT_LIST))
              asm.lda(asm.direct(R0 + 2))
              asm.sta(asm.abs(memory[Frame::FAULT], Frame::FAULT_LIST + 2))
            end
          end
        end
      end
    end
  end
end
