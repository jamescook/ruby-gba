# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Lowering the persistence ops to the cartridge's save memory.
        #
        # The GBA saves a game's progress in a small chip on the cartridge that keeps
        # its contents when the console is off. This backend uses the simplest kind,
        # battery-backed SRAM: 32KB of memory mapped straight into the address space
        # at SRAM_START, so reading and writing it is just loads and stores — no erase
        # or command sequences (as flash would need). Two quirks shape the code below:
        # the memory is on an 8-bit bus, so it must be read and written ONE BYTE AT A
        # TIME (a 4-byte value becomes four LDRB/STRB), and an emulator or flashcart
        # only enables the save chip when it finds a marker string in the ROM (see
        # #emit_save_signature).
        #
        # Layout: a 4-byte marker at the front, then each persisted variable as a
        # 4-byte little-endian value in its slot. The marker tells a fresh cartridge
        # (whose save memory is uninitialized garbage) apart from one that already
        # holds real saved data.
        module Save
          include Constants

          # The 4-byte header (the marker) that sits before the saved values.
          SAVE_HEADER_BYTES = 4

          # The string a flashcart / emulator scans the ROM for to decide there IS a
          # save chip and map it in. Without it, writes to SRAM go nowhere. The trailing
          # digits are a version the detector ignores; padded to a word so it stays aligned.
          SRAM_SIGNATURE = "SRAM_V123\x00\x00\x00".b

          # The byte offset of a variable's 4-byte slot within save memory.
          def save_slot_offset(slot)
            SAVE_HEADER_BYTES + (slot * 4)
          end

          # Boot: load the persisted variables, or seed a fresh cartridge with the
          # defaults. Written without a branch — one compare of the stored marker sets
          # the flags, then each variable is filled with either its saved value or its
          # default by a pair of predicated moves. Nothing between the moves touches the
          # flags (loads and shifts don't), so the one compare governs every variable.
          def emit_save_init(node)
            base = 4  # a pointer to the start of save memory, held for the whole routine
            marker = 5
            stored = 6
            saved = 7

            emit(ASM.load_immediate(base, SRAM_START))
            emit(ASM.load_immediate(marker, Int32.wrap(node[:magic])))
            emit_assemble_word(stored, base, 0, scratch: 2) # the marker actually in save memory
            emit(ASM.cmp_reg(stored, marker))               # equal? -> the save is real

            node[:vars].each do |var|
              offset = save_slot_offset(var[:slot])
              emit_assemble_word(saved, base, offset, scratch: 2)
              emit(ASM.mov_reg_cond(:eq, ACC, saved))       # real save -> take the saved value
              emit(ASM.load_immediate(3, Int32.wrap(var[:default])))
              emit(ASM.mov_reg_cond(:ne, ACC, 3))           # fresh cartridge -> take the default
              store_var(ACC, var[:name])                    # into the live variable in IWRAM
              emit_store_word_to_sram(ACC, base, offset, scratch: 3) # and back to save memory
            end

            emit_store_word_to_sram(marker, base, 0, scratch: 3) # stamp the marker so next boot loads
          end

          # Mirror one variable's current value back to its save slot — emitted right
          # after the variable changes, so the save always matches what the player sees.
          def emit_save_store(node)
            offset = save_slot_offset(node[:slot])
            load_var(ACC, node[:var])
            emit(ASM.load_immediate(TMP, SRAM_START + offset)) # the slot's address
            emit(ASM.strb(ACC, TMP))                           # low byte
            [8, 16, 24].each_with_index do |shift, i|
              emit(ASM.lsr_imm(2, ACC, shift))
              emit(ASM.strb_offset(2, TMP, i + 1))
            end
          end

          # Append the save-type marker so a flashcart / emulator maps the save chip.
          # It's plain data placed after all the code, never executed; word-aligned so
          # the scanner (which steps a word at a time) can find it.
          def emit_save_signature
            emit("\x00".b * ((-pos) % 4))
            emit(SRAM_SIGNATURE)
          end

          private

          # Read four consecutive bytes of save memory (little-endian) into +dest+,
          # rebuilding the 32-bit value. +base+ points at the start of save memory;
          # +offset+ is where this value's slot begins.
          def emit_assemble_word(dest, base, offset, scratch:)
            emit(ASM.ldrb_offset(dest, base, offset)) # byte 0 (lowest)
            [8, 16, 24].each_with_index do |shift, i|
              emit(ASM.ldrb_offset(scratch, base, offset + i + 1))
              emit(ASM.lsl_imm(scratch, scratch, shift))
              emit(ASM.orr_reg(dest, dest, scratch))
            end
          end

          # Write the 32-bit value in +src+ as four little-endian bytes into the slot at
          # +offset+ from +base+. STRB stores a register's low byte, so each higher byte
          # is shifted down into place first.
          def emit_store_word_to_sram(src, base, offset, scratch:)
            emit(ASM.strb_offset(src, base, offset)) # byte 0 (lowest)
            [8, 16, 24].each_with_index do |shift, i|
              emit(ASM.lsr_imm(scratch, src, shift))
              emit(ASM.strb_offset(scratch, base, offset + i + 1))
            end
          end
        end
      end
    end
  end
end
