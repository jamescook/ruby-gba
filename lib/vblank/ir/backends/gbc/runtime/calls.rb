# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # HOW THE GAME'S CODE AND THE RUNTIME CALL EACH OTHER.
          #
          # A runtime routine taking numbers finds them on the stack: the game pushes each, the first
          # deepest, and calls, so the last is just past the return address. The routine copies them
          # into the processor's quick memory (Memory#args) with rt_take_args and reads them from
          # there; the game takes them off the stack again afterwards. Number +i+ of +n+ is at
          # args + 4 × (n - 1 - i), lowest byte first (see Calls.arg).
          #
          # A routine of the game's may be in any bank of the cartridge, so it is called through
          # rt_far_call, which is in bank 0 and so always in view: it puts the routine's bank in
          # view, calls it, and puts the caller's bank back. The bank in view is kept in quick
          # memory (Memory::CURRENT_BANK), since the controller that switches banks cannot be read.
          module Calls
            module_function

            # Where number +i+ of +n+ handed to a runtime routine is, once rt_take_args has run.
            def arg(memory, i, n) = memory.args + (4 * (n - 1 - i))

            def emit(asm, memory)
              # Copy B bytes from (HL) into the arguments' place in quick memory: a number, four
              # bytes, to a turn of the loop.
              asm.label("rt_take_args")
              asm.load(:c, memory.args & 0xFF)
              asm.srl(:b)
              asm.srl(:b)
              asm.label("rt_take_args_loop")
              4.times do
                asm.load(:a, [:hli])
                asm.load_high([:c], :a)
                asm.inc(:c)
              end
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_take_args_loop")
              asm.ret

              # call rt_far_call / db bank / dw routine: the routine, called in its own bank.
              asm.label("rt_far_call")
              asm.pop(:hl)
              asm.load(:a, [:hli])
              asm.load(:e, [:hl])
              asm.inc(:hl)
              asm.load(:d, [:hl])
              asm.inc(:hl)
              asm.push(:hl) # where to come back to: past the bank and the address
              asm.jump("rt_far_call_de")

              # HL points at an address and a bank, in that order (a table of routines' entry).
              asm.label("rt_far_call_hl")
              asm.load(:e, [:hl])
              asm.inc(:hl)
              asm.load(:d, [:hl])
              asm.inc(:hl)
              asm.load(:a, [:hl])

              # The routine at DE, in bank A.
              asm.label("rt_far_call_de")
              asm.load(:l, :a)
              asm.load_high(:a, Memory::CURRENT_BANK)
              asm.push(:af)
              asm.load(:a, :l)
              asm.load_high(Memory::CURRENT_BANK, :a)
              asm.select_rom_bank
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.call("rt_jump_hl")
              asm.pop(:af)
              asm.load_high(Memory::CURRENT_BANK, :a)
              asm.select_rom_bank
              asm.ret
              asm.label("rt_jump_hl")
              asm.jump(:hl)

              # The table entry at HL in bank A, read by the reader at DE (one of the table readers
              # below). A big table is kept in a bank of its own rather than in the part always in
              # view, so its bank is put in view for the read and the caller's put back after it.
              asm.label("rt_far_read")
              asm.load(:c, :a)
              asm.load_high(:a, Memory::CURRENT_BANK)
              asm.push(:af)
              asm.load(:a, :c)
              asm.load_high(Memory::CURRENT_BANK, :a)
              asm.select_rom_bank
              asm.call("rt_jump_de")
              asm.pop(:af)
              asm.load_high(Memory::CURRENT_BANK, :a)
              asm.select_rom_bank
              asm.ret
              asm.label("rt_jump_de") # the return address is already pushed: DE is gone to
              asm.push(:de)
              asm.ret

              emit_parted_read(asm)

              emit_table_readers(asm)
              emit_clamp(asm)
            end

            # How many bytes of a big table each of its parts holds. A bank holds sixteen kilobytes, so
            # a table bigger than that cannot be one piece; it is cut into parts of this size, each
            # placed wherever there is room, and a list of where each part went (three bytes a part:
            # its address and its bank) is kept in view. A power of two, so the part an entry is in
            # is the top bits of the entry's offset and its place in the part is the bottom ones.
            TABLE_PART_BYTES = 8192

            # The entry DE bytes into a big table, read by the reader at BC: HL is the table's list
            # of parts. The offset never passes sixteen bits, so a table has eight parts at most.
            def emit_parted_read(asm)
              part_shift = TABLE_PART_BYTES.bit_length - 1 # 13: the part is the offset's top three bits
              asm.label("rt_far_read_parts")
              asm.push(:bc)
              asm.load(:a, :d)
              (16 - part_shift).times { asm.rlca } # the top bits of D, brought round to the bottom
              asm.and_a((1 << (16 - part_shift)) - 1)
              asm.load(:c, :a)
              asm.add_a(:a)
              asm.add_a(:c) # three bytes a part
              asm.add_a(:l)
              asm.load(:l, :a)
              asm.jump_relative(:nc, "rt_far_read_parts_found")
              asm.inc(:h)
              asm.label("rt_far_read_parts_found")
              asm.load(:a, :d)
              asm.and_a((TABLE_PART_BYTES >> 8) - 1)
              asm.load(:d, :a) # DE = the entry's place in its part
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.load(:b, :a) # BC = where the part starts
              asm.load(:a, [:hl]) # A = its bank
              asm.load(:h, :b)
              asm.load(:l, :c)
              asm.add_hl(:de)
              asm.pop(:de) # the reader
              asm.jump("rt_far_read")
            end

            # BCDE = the table entry at HL, widened to 32 bits with its sign (or without).
            def emit_table_readers(asm)
              asm.label("rt_read_int8")
              asm.load(:e, [:hl])
              asm.load(:d, 0)
              asm.bit(7, :e)
              asm.jump_relative(:z, "rt_read_zero_top")
              asm.load(:d, 0xFF)
              asm.label("rt_read_sign_top") # D holds the sign: C and B take it
              asm.load(:a, :d)
              asm.rla # the carry is the sign bit
              asm.sbc_a(:a) # 0x00 or 0xFF
              asm.load(:c, :a)
              asm.load(:b, :a)
              asm.ret
              asm.label("rt_read_uint8")
              asm.load(:e, [:hl])
              asm.load(:d, 0)
              asm.label("rt_read_zero_top")
              asm.load(:bc, 0)
              asm.ret
              asm.label("rt_read_int16")
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:d, [:hl])
              asm.jump_relative("rt_read_sign_top")
              asm.label("rt_read_uint16")
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:d, [:hl])
              asm.load(:bc, 0)
              asm.ret
              asm.label("rt_read_int32")
              asm.label("rt_load32") # the runtime's own reads of a number at HL; the game's are written in place
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:b, [:hl])
              asm.ret
            end

            # BCDE held at the floor (HL) first and then the ceiling (HL+4), so a floor above its
            # ceiling gives the ceiling, as the interpreter's clamp does.
            def emit_clamp(asm)
              asm.label("rt_clamp32")
              asm.push(:hl)
              asm.call("rt_cmp32")
              asm.pop(:hl)
              asm.cp_a(1)
              asm.jump_relative(:nz, "rt_clamp32_floor_ok")
              asm.call("rt_read_int32") # below the floor: the floor
              asm.inc(:hl)
              asm.jump_relative("rt_clamp32_ceiling")
              asm.label("rt_clamp32_floor_ok")
              4.times { asm.inc(:hl) }
              asm.label("rt_clamp32_ceiling")
              asm.push(:hl)
              asm.call("rt_cmp32")
              asm.pop(:hl)
              asm.cp_a(2)
              asm.ret(:nz)
              asm.jump("rt_read_int32") # above the ceiling: the ceiling
            end
          end
        end
      end
    end
  end
end
