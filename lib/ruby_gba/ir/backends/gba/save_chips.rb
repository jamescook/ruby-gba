# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # THE KINDS OF SAVE CHIP, and what each does differently with the three ways into save
        # memory that save data is built from (see Save): read, write, and checksum a run of
        # bytes — and the wipe, which only flash has.
        #
        # Every chip sits at the same address, SRAM_START, on an 8-bit bus: a place in save
        # memory, a count of bytes from its start, becomes an address by adding SRAM_START, and
        # a word is four bytes put together lowest first, the same order the interpreter keeps.
        #
        # BATTERY-BACKED SRAM, 32K, takes any byte with a plain store.
        #
        # FLASH, 64K, is read with the same loads. Writing is not a store: the chip takes a byte
        # only after a short command — writes to two fixed addresses inside it — and then takes
        # a while to settle, so the code asks it again and again until the byte reads back as
        # written. A write can only turn bits off, so a block of 4K is wiped back to all bits on
        # (0xFF), with another command, before it is written afresh, and that takes longer still.
        #
        # FLASH, 128K, is two 64K banks, and the console sees one at a time: another command
        # says which. So a place is turned into an address a byte at a time, by a routine that
        # shows the bank the byte is in first — a word can straddle the line between the banks,
        # and so can a run of bytes being summed.
        #
        # Every method that works out a place leaves its address in r1 (TMP), and the flash
        # routines leave every register but r12 (ADDR) as they found it, so a caller in the
        # middle of working something out loses nothing.
        class SaveChip
          include Console::Hardware

          SAVE_WIDTH_BYTES = { byte: 1, half: 2, word: 4 }.freeze

          # The chip for +memory+ (an IR::SaveLayout::Memory). +roomy_word+ is called for a word of
          # the roomy memory, which only a 128K chip needs. +call_cold+ calls a routine in the
          # cartridge from wherever the code is (see Placement#emit_call_cold_routine).
          def self.for(memory, emitter:, lowering:, call_cold:, roomy_word:)
            parts = { emitter: emitter, lowering: lowering, call_cold: call_cold }
            return BatteryChip.new(**parts) unless memory.flash?
            return FlashChip.new(**parts) if memory.size <= 0x10000

            BankedFlashChip.new(bank_word: roomy_word.call, **parts)
          end

          def initialize(emitter:, lowering:, call_cold:)
            @emitter = emitter
            @lowering = lowering
            @call_cold = call_cold
          end

          def flash? = false

          # What a chip says before anything touches save memory.
          def emit_wake; end

          # The chip's own routines, emitted once after all the code.
          def emit_routines; end

          # r0 = the byte, half or word at node.at.
          def eval_read(node)
            emit_save_address(node.at)
            emit_read_bytes(ACC, TMP, SAVE_WIDTH_BYTES.fetch(node.width), scratch: 2)
          end

          # r0 = the checksum of node.length bytes from node.at: two running totals, the bytes
          # and the totals so far, the second in the top half (see IR::SaveLayout.checksum).
          # Only the low sixteen bits of each are kept at the end, which is the same answer as
          # keeping them to sixteen bits all the way.
          def eval_sum(node)
            low = 2
            high = 3
            emit_sum_start(node.at)
            @emitter.emit(ASM.push(TMP))
            @lowering.value(node.length)                           # r0 = how many bytes are left
            @emitter.emit(ASM.pop(TMP))                            # r1 = the next byte
            @emitter.emit(ASM.load_immediate(low, 0))
            @emitter.emit(ASM.load_immediate(high, 0))
            again = @emitter.gensym
            done = @emitter.gensym
            @emitter.place_label(again)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, done, cond: :le)
            emit_load_summed_byte
            @emitter.emit(ASM.add_imm(TMP, TMP, 1))
            @emitter.emit(ASM.add_reg(low, low, ADDR))
            @emitter.emit(ASM.add_reg(high, high, low))
            @emitter.emit(ASM.sub_imm(ACC, ACC, 1))
            @emitter.emit_branch(:b, again)
            @emitter.place_label(done)
            @emitter.emit(ASM.lsl_imm(low, low, 16))
            @emitter.emit(ASM.lsr_imm(low, low, 16))
            @emitter.emit(ASM.lsl_imm(ACC, high, 16))
            @emitter.emit(ASM.orr_reg(ACC, ACC, low))
          end

          private

          # r1 = the address of the place in save memory +at+ says (a value node).
          def emit_save_address(at)
            @lowering.value(at)
            @emitter.emit(ASM.load_immediate(TMP, SRAM_START))
            @emitter.emit(ASM.add_reg(TMP, TMP, ACC))
          end

          # r1 = the place in save memory +at+ says, not yet an address.
          def emit_save_place(at)
            @lowering.value(at)
            @emitter.emit(ASM.mov_reg(TMP, ACC))
          end

          # r1, a place in save memory, becomes its address. Spends r12.
          def emit_place_to_address
            @emitter.emit(ASM.load_immediate(ADDR, SRAM_START))
            @emitter.emit(ASM.add_reg(TMP, TMP, ADDR))
          end

          # Where the sum starts, in r1, and how it reads the byte there into r12.
          def emit_sum_start(at) = emit_save_address(at)
          def emit_load_summed_byte = @emitter.emit(ASM.ldrb_offset(ADDR, TMP, 0))

          # +count+ bytes from the address in +base+, lowest first, into +dest+ — the bytes that
          # make up a byte, a half or a word. A word is the whole signed number; the narrower
          # two stay unsigned, as they are stored.
          def emit_read_bytes(dest, base, count, scratch:)
            @emitter.emit(ASM.ldrb_offset(dest, base, 0))
            (1...count).each do |i|
              @emitter.emit(ASM.ldrb_offset(scratch, base, i))
              @emitter.emit(ASM.orr_reg_lsl(dest, dest, scratch, 8 * i))
            end
          end
        end

        # Battery-backed SRAM: a byte is a store, and there is nothing to wipe.
        class BatteryChip < SaveChip
          SIGNATURE = "SRAM_V123\x00\x00\x00".b.freeze

          def signature = SIGNATURE

          def emit_write(node)
            emit_save_address(node.at)
            @emitter.emit(ASM.push(TMP))
            @lowering.value(node.value)                            # r0 = what to write
            @emitter.emit(ASM.pop(TMP))                            # r1 = where
            SAVE_WIDTH_BYTES.fetch(node.width).times do |i|
              if i.zero?
                @emitter.emit(ASM.strb_offset(ACC, TMP, 0))
              else
                @emitter.emit(ASM.lsr_imm(2, ACC, 8 * i))
                @emitter.emit(ASM.strb_offset(2, TMP, i))
              end
            end
          end

          # Battery memory takes any byte as it is, so wiping it is nothing.
          def emit_wipe(_node); end
        end

        # A 64K flash chip, and what the 128K one shares with it.
        class FlashChip < SaveChip
          SIGNATURE = "FLASH512_V131\x00\x00\x00".b.freeze

          # The two addresses inside a flash chip every command is said to, and what is said.
          COMMAND_AT = SRAM_START + 0x5555
          UNLOCK_AT = SRAM_START + 0x2AAA
          ERASE = 0x80
          ERASE_SECTOR = 0x30
          ID_ENTER = 0x90
          ID_LEAVE = 0xF0
          PROGRAM = 0xA0
          SWITCH_BANK = 0xB0

          # How many times a write or a wipe asks the chip whether it has finished before giving
          # up on it. A chip that never finishes is one the game wrote wrongly, and the read back
          # after every save then says the save failed, where waiting for ever would stop the game.
          # A wipe finishes long before this on any chip.
          ASKS = 0x40000

          # Flash needs the slowest of the four speeds the console can read save memory at, which
          # is these two bits of the wait-state register set.
          SLOWEST_SAVE_ACCESS = 0b11

          PROGRAM_LABEL = "save_flash_program"
          WIPE_LABEL = "save_flash_wipe"
          START_WIPE_LABEL = "save_flash_start_wipe"

          def flash? = true
          def signature = SIGNATURE

          # SAY A COMMAND TO THE CHIP FIRST, before anything reads save memory. An emulator
          # decides which chip a cartridge has from the first thing the game does to save memory:
          # a command makes it flash, and anything else — a read included — makes it battery
          # memory for good. Asking the chip for its maker's number and putting it back is the
          # command every flash chip answers. Save memory is read at the slowest speed first,
          # which flash needs; a cartridge built for the fast speeds has it already.
          def emit_wake
            @emitter.emit(ASM.load_immediate(0, REG_WAITCNT))
            @emitter.emit(ASM.load_halfword(1, 0))
            @emitter.emit(ASM.orr_imm(1, 1, SLOWEST_SAVE_ACCESS))
            @emitter.emit(ASM.store_halfword(1, 0))
            emit_command(ID_ENTER, at: 0, value: 1)
            emit_command(ID_LEAVE, at: 0, value: 1)
          end

          def emit_write(node)
            @lowering.value(node.at)                               # r0 = the place
            @emitter.emit(ASM.push(ACC))
            @lowering.value(node.value)                            # r0 = what to write
            @emitter.emit(ASM.pop(TMP))                            # r1 = the place
            SAVE_WIDTH_BYTES.fetch(node.width).times do |i|
              @emitter.emit(ASM.add_imm(TMP, TMP, 1)) unless i.zero?
              @emitter.emit(i.zero? ? ASM.mov_reg(2, ACC) : ASM.lsr_imm(2, ACC, 8 * i)) # r2 = this byte
              @emitter.emit(ASM.push(TMP))
              emit_place_to_address
              @call_cold.call(PROGRAM_LABEL)
              @emitter.emit(ASM.pop(TMP))
            end
          end

          # Wipe the block holding node.at, waiting for the chip to finish unless the node says
          # not to (see Nodes::SaveErase).
          def emit_wipe(node)
            emit_save_place(node.at)
            emit_place_to_address
            @call_cold.call(node.wait == false ? START_WIPE_LABEL : WIPE_LABEL)
          end

          def emit_routines
            emit_program_routine
            emit_wipe_routines
          end

          private

          # The three writes that say +command+ to the chip, using registers +at+ and +value+: the
          # two that unlock it, then the command.
          def emit_command(command, at:, value:)
            emit_unlock(at: at, value: value)
            emit_chip_byte(COMMAND_AT, command, at: at, value: value)
          end

          def emit_unlock(at:, value:)
            emit_chip_byte(COMMAND_AT, 0xAA, at: at, value: value)
            emit_chip_byte(UNLOCK_AT, 0x55, at: at, value: value)
          end

          def emit_chip_byte(address, byte, at:, value:)
            @emitter.emit(ASM.load_immediate(at, address))
            @emitter.emit(ASM.load_immediate(value, byte))
            @emitter.emit(ASM.strb(value, at))
          end

          # WRITE r2's low byte at the address in r1: the program command, the byte, then ask the
          # chip until the byte reads back. While the chip is busy a read of the block it is busy
          # in comes back with the top bit the other way round from the byte, so a read that
          # matches is one the chip has finished.
          def emit_program_routine
            @emitter.place_label(PROGRAM_LABEL)
            @emitter.emit(ASM.push(0, 3))
            emit_command(PROGRAM, at: 0, value: 3)
            @emitter.emit(ASM.strb(2, TMP))
            @emitter.emit(ASM.and_imm(3, 2, 0xFF))
            emit_wait_until_read_is(TMP, 3)
            @emitter.emit(ASM.pop(0, 3))
            @emitter.emit(ASM.bx(14))
          end

          # WIPE the 4K block holding the address in r1: the erase command, unlocked a second time
          # and then said at the block. One routine leaves it at that, and the other then asks the
          # chip until the block reads 0xFF.
          def emit_wipe_routines
            [[START_WIPE_LABEL, false], [WIPE_LABEL, true]].each do |label, wait|
              @emitter.place_label(label)
              @emitter.emit(ASM.push(0, 2, 3))
              emit_command(ERASE, at: 0, value: 3)
              emit_unlock(at: 0, value: 3)
              @emitter.emit(ASM.lsr_imm(2, TMP, 12))
              @emitter.emit(ASM.lsl_imm(2, 2, 12))              # r2 = the block's first byte
              @emitter.emit(ASM.load_immediate(3, ERASE_SECTOR))
              @emitter.emit(ASM.strb(3, 2))
              if wait
                @emitter.emit(ASM.load_immediate(3, 0xFF))
                emit_wait_until_read_is(2, 3)
              end
              @emitter.emit(ASM.pop(0, 2, 3))
              @emitter.emit(ASM.bx(14))
            end
          end

          # Read the byte at +at+ until it is the byte in +want+, or the chip has been asked ASKS
          # times. Spends r0 and r12.
          def emit_wait_until_read_is(at, want)
            again = @emitter.gensym
            done = @emitter.gensym
            @emitter.emit(ASM.load_immediate(0, ASKS))
            @emitter.place_label(again)
            @emitter.emit(ASM.ldrb_offset(ADDR, at, 0))
            @emitter.emit(ASM.cmp_reg(ADDR, want))
            @emitter.emit_branch(:bcond, done, cond: :eq)
            @emitter.emit(ASM.sub_imm(0, 0, 1))
            @emitter.emit(ASM.cmp_imm(0, 0))
            @emitter.emit_branch(:bcond, again, cond: :ne)
            @emitter.place_label(done)
          end
        end

        # A 128K flash chip: a 64K one shown a bank at a time. A word of the roomy memory says
        # which bank is showing, so a run of bytes in one bank switches once rather than at
        # every byte.
        class BankedFlashChip < FlashChip
          SIGNATURE = "FLASH1M_V103".b.freeze
          SHOW_BANK_LABEL = "save_flash_show_bank"

          def initialize(bank_word:, **)
            super(**)
            @bank_word = bank_word
          end

          def signature = SIGNATURE

          # The first bank is shown, which the bank word says.
          def emit_wake
            super
            emit_command(SWITCH_BANK, at: 0, value: 1)
            @emitter.emit(ASM.load_immediate(0, SRAM_START))
            @emitter.emit(ASM.load_immediate(1, 0))
            @emitter.emit(ASM.strb(1, 0))
            @emitter.emit(ASM.load_immediate(0, @bank_word))
            @emitter.emit(ASM.str(1, 0))
          end

          # r0 = +count+ bytes from the place node.at, each through the bank routine. r3 keeps the
          # place, which the routine leaves alone.
          def eval_read(node)
            @lowering.value(node.at)
            @emitter.emit(ASM.mov_reg(3, ACC))
            SAVE_WIDTH_BYTES.fetch(node.width).times do |i|
              @emitter.emit(i.zero? ? ASM.mov_reg(TMP, 3) : ASM.add_imm(TMP, 3, i))
              emit_place_to_address
              if i.zero?
                @emitter.emit(ASM.ldrb_offset(ACC, TMP, 0))
              else
                @emitter.emit(ASM.ldrb_offset(2, TMP, 0))
                @emitter.emit(ASM.orr_reg_lsl(ACC, ACC, 2, 8 * i))
              end
            end
          end

          def emit_routines
            super
            emit_show_bank_routine
          end

          private

          def emit_place_to_address = @call_cold.call(SHOW_BANK_LABEL)

          # The sum keeps the place in r1, and each byte is found through the bank routine.
          def emit_sum_start(at) = emit_save_place(at)

          def emit_load_summed_byte
            @emitter.emit(ASM.push(TMP))
            emit_place_to_address
            @emitter.emit(ASM.ldrb_offset(ADDR, TMP, 0))
            @emitter.emit(ASM.pop(TMP))
          end

          # r1, a place in the chip, becomes an address in the 64K window the console sees, and
          # the bank it is in is shown first unless the bank word says it already is. Leaves r0,
          # r2 and r3 alone; r12 is spent.
          def emit_show_bank_routine
            same = @emitter.gensym
            @emitter.place_label(SHOW_BANK_LABEL)
            @emitter.emit(ASM.push(2, 3))
            @emitter.emit(ASM.lsr_imm(ADDR, TMP, 16))          # r12 = the bank the place is in
            @emitter.emit(ASM.load_immediate(2, @bank_word))
            @emitter.emit(ASM.ldr(3, 2))
            @emitter.emit(ASM.cmp_reg(3, ADDR))
            @emitter.emit_branch(:bcond, same, cond: :eq)
            @emitter.emit(ASM.str(ADDR, 2))
            emit_command(SWITCH_BANK, at: 2, value: 3)
            @emitter.emit(ASM.load_immediate(2, SRAM_START))
            @emitter.emit(ASM.strb(ADDR, 2))                   # the bank, said at the chip's first byte
            @emitter.place_label(same)
            @emitter.emit(ASM.lsl_imm(TMP, TMP, 16))
            @emitter.emit(ASM.lsr_imm(TMP, TMP, 16))           # where in the bank
            @emitter.emit(ASM.load_immediate(2, SRAM_START))
            @emitter.emit(ASM.add_reg(TMP, TMP, 2))
            @emitter.emit(ASM.pop(2, 3))
            @emitter.emit(ASM.bx(14))
          end
        end
      end
    end
  end
end
