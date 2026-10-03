# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Lowering the persistence ops to the cartridge's save memory.
        #
        # The GBA saves a game's progress in a small chip on the cartridge that keeps its
        # contents when the console is off: 32K of battery-backed SRAM, or a flash chip of 64K or
        # 128K, as the program says (see IR::SaveLayout.memory_of). What each chip does
        # differently — how a byte is written, how a block is wiped, how a place becomes an
        # address — is the chip's (see SaveChip); this lowers the ops onto whichever it is.
        #
        # Two quirks are shared by every chip. The memory is on an 8-bit bus, so it is read and
        # written ONE BYTE AT A TIME (a 4-byte value becomes four byte loads or stores). And an
        # emulator or a flashcart only maps the chip when it finds a marker string in the ROM (see
        # #emit_save_signature) — an emulator also watches the first thing the game does to save
        # memory, which is why a flash cartridge says a command to it before anything reads it
        # (see #emit_wake_chip).
        #
        # Layout of save_var's block: a 4-byte marker at the front, then each persisted variable as
        # a 4-byte little-endian value in its slot. The marker tells a fresh cartridge (whose save
        # memory is uninitialized garbage) apart from one that already holds real saved data.
        class Save
          include Console::Hardware

          def initialize(emitter:, primitives:, lowering:, memory:, call_cold:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @memory = memory
            @call_cold = call_cold
            @save_memory = IR::SaveLayout::PACKED
            @chip = chip_for(@save_memory)
          end

          # Pick the chip for +memory+ (an IR::SaveLayout::Memory), the save memory the program
          # says it has.
          def use_memory(memory)
            @save_memory = memory
            @chip = chip_for(memory)
          end

          # What the chip says before anything touches save memory (see FlashChip#emit_wake).
          def emit_wake_chip = @chip.emit_wake

          # Boot: load the persisted variables, or seed a fresh cartridge with the
          # defaults. Written without a branch — one compare of the stored marker sets
          # the flags, then each variable is filled with either its saved value or its
          # default by a pair of predicated moves. Nothing between the moves touches the
          # flags (loads and shifts don't), so the one compare governs every variable.
          def emit_save_init(node)
            refuse_save_var_on_flash!
            base = 4  # a pointer to the start of save memory, held for the whole routine
            marker = 5
            stored = 6
            saved = 7

            @emitter.emit(ASM.load_immediate(base, SRAM_START))
            @emitter.emit(ASM.load_immediate(marker, Int32.wrap(node.magic)))
            emit_load_sram_word(stored, base, IR::SaveLayout::SAVE_VAR_MARKER_AT, scratch: 2) # the marker actually in save memory
            @emitter.emit(ASM.cmp_reg(stored, marker))       # equal? -> the save is real

            node.vars.each do |var|
              offset = IR::SaveLayout.save_var_at(var.slot)
              emit_load_sram_word(saved, base, offset, scratch: 2)
              @emitter.emit(ASM.mov_reg_cond(:eq, ACC, saved))       # real save -> take the saved value
              @emitter.emit(ASM.load_immediate(3, Int32.wrap(var.default)))
              @emitter.emit(ASM.mov_reg_cond(:ne, ACC, 3))           # fresh cartridge -> take the default
              @primitives.store_var(ACC, var.name)                  # into the live variable in IWRAM
              emit_store_word_to_sram(ACC, base, offset, scratch: 3) # and back to save memory
            end

            emit_store_word_to_sram(marker, base, IR::SaveLayout::SAVE_VAR_MARKER_AT, scratch: 3) # stamp the marker so next boot loads
          end

          # Mirror one variable's current value back to its save slot — emitted right
          # after the variable changes, so the save always matches what the player sees.
          def emit_save_store(node)
            refuse_save_var_on_flash!
            offset = IR::SaveLayout.save_var_at(node.slot)
            @primitives.load_var(ACC, node.var)
            @emitter.emit(ASM.load_immediate(TMP, SRAM_START + offset)) # the slot's address
            @emitter.emit(ASM.strb(ACC, TMP))                           # low byte
            [8, 16, 24].each_with_index do |shift, i|
              @emitter.emit(ASM.lsr_imm(2, ACC, shift))
              @emitter.emit(ASM.strb_offset(2, TMP, i + 1))
            end
          end

          # --- the ways into save memory that save data is built from, each the chip's ---

          # r0 = the byte, half or word at node.at.
          def eval_save_read(node) = @chip.eval_read(node)

          def emit_save_write(node) = @chip.emit_write(node)

          # Wipe the block holding node.at, the way the chip does it.
          def emit_save_erase(node) = @chip.emit_wipe(node)

          # r0 = the checksum of node.length bytes from node.at (see IR::SaveLayout.checksum).
          def eval_save_sum(node) = @chip.eval_sum(node)

          # Append the save-type marker so a flashcart / emulator maps the save chip, and before
          # it the chip's own routines. The marker is plain data placed after all the code,
          # never executed; word-aligned so the scanner (which steps a word at a time) can find it.
          def emit_save_signature
            @chip.emit_routines
            @emitter.emit("\x00".b * ((-@emitter.pos) % 4))
            @emitter.emit(@chip.signature)
          end

          private

          def chip_for(memory)
            SaveChip.for(memory, emitter: @emitter, lowering: @lowering, call_cold: @call_cold,
                                 roomy_word: method(:allocate_bank_word))
          end

          # The word a 128K chip keeps of which bank is showing.
          def allocate_bank_word
            @memory.alloc_roomy(4) or
              raise LoweringError, "This game has 128K of save memory, and the console's roomy memory " \
                                   "is full, so there is no room for the one word that save memory needs. " \
                                   "To fix this, make a list or a pool smaller."
          end

          # A save_var writes its number into save memory each time it changes, and flash takes a
          # byte only once between two wipes of its block. A game is refused before it gets here
          # (see Builder#refuse_save_var_on_flash!); this catches a program put together another
          # way.
          def refuse_save_var_on_flash!
            return unless @chip.flash?

            raise LoweringError, IR::SaveLayout.save_var_on_flash_message(
              @save_memory.kilobytes, "give the program 32K of save memory.",
            )
          end

          # Read four consecutive bytes of save memory (little-endian) into +dest+,
          # rebuilding the 32-bit value. +base+ points at the start of save memory;
          # +offset+ is where this value's slot begins.
          def emit_load_sram_word(dest, base, offset, scratch:)
            @emitter.emit(ASM.ldrb_offset(dest, base, offset)) # byte 0 (lowest)
            [8, 16, 24].each_with_index do |shift, i|
              @emitter.emit(ASM.ldrb_offset(scratch, base, offset + i + 1))
              @emitter.emit(ASM.lsl_imm(scratch, scratch, shift))
              @emitter.emit(ASM.orr_reg(dest, dest, scratch))
            end
          end

          # Write the 32-bit value in +src+ as four little-endian bytes into the slot at
          # +offset+ from +base+. STRB stores a register's low byte, so each higher byte
          # is shifted down into place first.
          def emit_store_word_to_sram(src, base, offset, scratch:)
            @emitter.emit(ASM.strb_offset(src, base, offset)) # byte 0 (lowest)
            [8, 16, 24].each_with_index do |shift, i|
              @emitter.emit(ASM.lsr_imm(scratch, src, shift))
              @emitter.emit(ASM.strb_offset(scratch, base, offset + i + 1))
            end
          end
        end
      end
    end
  end
end
