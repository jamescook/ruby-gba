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

          # The chip for +memory+ (an IR::SaveLayout::Memory). +roomy_bytes+ is called with a count
          # of bytes of the roomy memory to keep, which only a 128K chip and the EEPROM need. +call_cold+ calls a routine in the
          # cartridge from wherever the code is (see Placement#emit_call_cold_routine).
          def self.for(memory, emitter:, lowering:, call_cold:, roomy_bytes:)
            parts = { emitter: emitter, lowering: lowering, call_cold: call_cold }
            return EepromChip.new(area: roomy_bytes.call(EepromChip::AREA_BYTES), **parts) if memory.eeprom?
            return BatteryChip.new(**parts) unless memory.flash?
            return FlashChip.new(**parts) if memory.size <= 0x10000

            BankedFlashChip.new(bank_word: roomy_bytes.call(4), **parts)
          end

          def initialize(emitter:, lowering:, call_cold:)
            @emitter = emitter
            @lowering = lowering
            @call_cold = call_cold
          end

          def flash? = false

          # What a chip says before anything touches save memory.
          def emit_wake; end

          # What a chip does at the end of each pass of the game loop, before the console sleeps
          # until the next frame.
          def emit_end_of_pass; end

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

        # A CHIP WHOSE PLACES BECOME ADDRESSES ONE BYTE AT A TIME, through a routine of the chip's
        # own (#emit_place_to_address): r1 holds a place going in and an address the console can
        # read coming out, and r0, r2 and r3 are left as they were. The 128K flash chip finds the
        # bank a byte is in; the EEPROM finds its block.
        module PlaceFoundEachByte
          # r0 = +count+ bytes from the place node.at, each through the routine. r3 keeps the
          # place, which the routine leaves alone.
          def eval_read(node)
            @lowering.value(node.at)
            @emitter.emit(ASM.mov_reg(3, ACC))
            SaveChip::SAVE_WIDTH_BYTES.fetch(node.width).times do |i|
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

          private

          # The sum keeps the place in r1, and each byte is found through the routine.
          def emit_sum_start(at) = emit_save_place(at)

          def emit_load_summed_byte
            @emitter.emit(ASM.push(TMP))
            emit_place_to_address
            @emitter.emit(ASM.ldrb_offset(ADDR, TMP, 0))
            @emitter.emit(ASM.pop(TMP))
          end
        end

        # A 128K flash chip: a 64K one shown a bank at a time. A word of the roomy memory says
        # which bank is showing, so a run of bytes in one bank switches once rather than at
        # every byte.
        class BankedFlashChip < FlashChip
          include PlaceFoundEachByte

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

          def emit_routines
            super
            emit_show_bank_routine
          end

          private

          def emit_place_to_address = @call_cold.call(SHOW_BANK_LABEL)

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

        # AN 8K EEPROM. It is not on the bus the other chips are on: it sits at the start of
        # EEPROM_AT and is spoken to ONE BIT AT A TIME, a bit in the lowest bit of each halfword
        # the copying engine moves there or back. It reads and writes a BLOCK of eight bytes
        # and nothing smaller, numbered from 0 to 1023.
        #
        # Reading a block is two copies: out go 17 bits — 1, 1, the block's number in 14 bits
        # with the highest first, and a 0 — and back come 68, the first four of no meaning and
        # then the block's 64 bits, the highest bit of its first byte first. Writing one is a
        # single copy of 81 bits — 1, 0, the number, the 64 bits, a 0 — after which the chip
        # takes most of half a frame to settle, and a read at EEPROM_AT says when it has: its
        # lowest bit comes back 1.
        #
        # SO THE CHIP IS SEEN THROUGH ONE BLOCK KEPT IN THE ROOMY MEMORY. A place becomes an
        # address in that copy, and the copy is fetched first when it holds another block; a
        # byte written goes into the copy, which says it now differs from the chip. The copy goes
        # back to the chip when another block is wanted, and at the end of every pass of the game
        # loop, before the console sleeps until the next frame. Writing straight through would
        # write a whole block for every byte a save writes, and a save writes its bytes one at a
        # time. So a block is written once for each run of the save through it, the writes reach
        # the chip in the order the save made them — the checksum that makes a half good still
        # goes in last — and nothing a pass wrote is still in the copy when the frame ends.
        #
        # READS HAVE A BLOCK OF THEIR OWN. A save after the first copies from the older half
        # while it writes the newer, a byte from one and then a byte to the other; with one copy
        # each read would throw out the block being written and every byte would cost a block
        # written back. So a read is served from the block a save writes into when it is that
        # block — written back first, so what is read is what the chip kept, which is how a save
        # the chip did not keep is found out — and otherwise from a second block kept only for
        # reading, which never differs from the chip and is let go when a write lands in it.
        #
        # The routines are in the cartridge, called from wherever the code is, and leave every
        # register as they found it but the ones each says.
        class EepromChip < SaveChip
          include PlaceFoundEachByte

          SIGNATURE = "EEPROM_V124\x00".b.freeze

          # Where the chip answers. The console sees it there on a cartridge of 16MB or less,
          # which every cartridge this builds is.
          EEPROM_AT = 0x0D000000

          # The block number takes 14 bits on the 8K chip, though only the low ten count.
          ADDRESS_BITS = 14
          BLOCK_BITS = 64

          # The bits each of the three moves carries.
          READ_REQUEST = 2 + ADDRESS_BITS + 1
          READ_REPLY = 4 + BLOCK_BITS
          WRITE_REQUEST = 2 + ADDRESS_BITS + BLOCK_BITS + 1

          # The two copies and what is known about them, in the roomy memory: for the one a save
          # writes into, which block it holds (-1 for none), whether it differs from the chip
          # and its eight bytes; for the one kept for reading, which block and its bytes; then
          # room for the longest run of bits, a halfword each.
          HELD_AT = 0
          CHANGED_AT = 4
          BYTES_AT = 8
          READ_HELD_AT = BYTES_AT + IR::SaveLayout::EEPROM_BLOCK
          READ_BYTES_AT = READ_HELD_AT + 4
          BITS_AT = READ_BYTES_AT + IR::SaveLayout::EEPROM_BLOCK
          AREA_BYTES = BITS_AT + (2 * WRITE_REQUEST) + 2

          # A copying-engine transfer of halfwords that starts as it is written: the enable bit,
          # every other choice the plain one. In the top half, where the count's register ends.
          COPY_NOW = 0x8000 << 16

          # The console's wait for the third cartridge window, the one the EEPROM is in: the
          # longest first access there is, which the chip needs.
          SLOWEST_THIRD_WINDOW = 0b11 << 8

          # How many times the end of a write asks the chip whether it has settled before giving
          # up on it, as FlashChip::ASKS does.
          ASKS = 0x40000

          ADDRESS_LABEL = "save_eeprom_address"
          PUT_LABEL = "save_eeprom_put"
          FETCH_LABEL = "save_eeprom_fetch"
          FETCH_FOR_READING_LABEL = "save_eeprom_fetch_for_reading"
          WRITE_BACK_LABEL = "save_eeprom_write_back"

          def initialize(area:, **)
            super(**)
            @area = area
          end

          def signature = SIGNATURE

          # Neither copy holds a block yet, and the chip's window is read at the speed it needs.
          def emit_wake
            @emitter.emit(ASM.load_immediate(0, REG_WAITCNT))
            @emitter.emit(ASM.load_halfword(1, 0))
            @emitter.emit(ASM.orr_imm(1, 1, SLOWEST_THIRD_WINDOW))
            @emitter.emit(ASM.store_halfword(1, 0))
            @emitter.emit(ASM.load_immediate(0, @area))
            @emitter.emit(ASM.mvn_imm(1, 0))
            @emitter.emit(ASM.str_offset(1, 0, HELD_AT))
            @emitter.emit(ASM.str_offset(1, 0, READ_HELD_AT))
            emit_copy_matches_chip(scratch: 1, area: 0)
          end

          # What a pass wrote reaches the chip before the frame ends.
          def emit_end_of_pass = @call_cold.call(WRITE_BACK_LABEL)

          # Each byte into the copy, through the put routine: r1 the place, r2 the byte.
          def emit_write(node)
            @lowering.value(node.at)                               # r0 = the place
            @emitter.emit(ASM.push(ACC))
            @lowering.value(node.value)                            # r0 = what to write
            @emitter.emit(ASM.pop(TMP))                            # r1 = the place
            SAVE_WIDTH_BYTES.fetch(node.width).times do |i|
              @emitter.emit(ASM.add_imm(TMP, TMP, 1)) unless i.zero?
              @emitter.emit(i.zero? ? ASM.mov_reg(2, ACC) : ASM.lsr_imm(2, ACC, 8 * i)) # r2 = this byte
              @emitter.emit(ASM.push(TMP))
              @call_cold.call(PUT_LABEL)
              @emitter.emit(ASM.pop(TMP))
            end
          end

          # An EEPROM is written over as it is, so there is nothing to wipe.
          def emit_wipe(_node); end

          def emit_routines
            emit_address_routine
            emit_put_routine
            emit_fetch_routine(FETCH_LABEL, held_at: HELD_AT, bytes_at: BYTES_AT)
            emit_fetch_routine(FETCH_FOR_READING_LABEL, held_at: READ_HELD_AT, bytes_at: READ_BYTES_AT)
            emit_write_back_routine
          end

          private

          def emit_place_to_address = @call_cold.call(ADDRESS_LABEL)

          # r1, a place, becomes the address of its byte for READING. From the copy a save writes
          # into, when it holds the block — written back first, so the byte read is the one the
          # chip kept, and given up if the chip did not keep it — and otherwise from the copy kept
          # for reading, fetched when it holds another block. Spends r12; leaves r0, r2 and r3
          # alone.
          def emit_address_routine
            elsewhere = @emitter.gensym
            reading = @emitter.gensym
            found = @emitter.gensym
            @emitter.place_label(ADDRESS_LABEL)
            @emitter.emit(ASM.push(0, 2, 3, 14))
            @emitter.emit(ASM.lsr_imm(ADDR, TMP, 3))                  # r12 = the block the place is in
            @emitter.emit(ASM.load_immediate(2, @area))
            @emitter.emit(ASM.ldr_offset(3, 2, HELD_AT))
            @emitter.emit(ASM.cmp_reg(3, ADDR))
            @emitter.emit_branch(:bcond, elsewhere, cond: :ne)
            @emitter.emit_branch(:bl, WRITE_BACK_LABEL)
            @emitter.emit(ASM.ldr_offset(3, 2, HELD_AT))              # still held, unless the chip refused it
            @emitter.emit(ASM.cmp_reg(3, ADDR))
            @emitter.emit_branch(:bcond, elsewhere, cond: :ne)
            @emitter.emit(ASM.load_immediate(0, BYTES_AT))
            @emitter.emit_branch(:b, found)
            @emitter.place_label(elsewhere)
            @emitter.emit(ASM.ldr_offset(3, 2, READ_HELD_AT))
            @emitter.emit(ASM.cmp_reg(3, ADDR))
            @emitter.emit_branch(:bcond, reading, cond: :eq)
            @emitter.emit_branch(:bl, FETCH_FOR_READING_LABEL)
            @emitter.place_label(reading)
            @emitter.emit(ASM.load_immediate(0, READ_BYTES_AT))
            @emitter.place_label(found)                               # r0 = where that copy's bytes are
            @emitter.emit(ASM.and_imm(TMP, TMP, IR::SaveLayout::EEPROM_BLOCK - 1))
            @emitter.emit(ASM.add_reg(TMP, TMP, 2))
            @emitter.emit(ASM.add_reg(TMP, TMP, 0))
            @emitter.emit(ASM.pop(0, 2, 3, 14))
            @emitter.emit(ASM.bx(14))
          end

          # r2's low byte into the copy a save writes into, at the place in r1: that copy written
          # back and the place's block fetched first when it holds another block, and the copy
          # kept for reading let go of the block if it holds it, since that is no longer what the
          # chip will hold. The copy then differs from the chip. Spends r1 and r12; leaves r0, r2
          # and r3 alone.
          def emit_put_routine
            held = @emitter.gensym
            fresh = @emitter.gensym
            @emitter.place_label(PUT_LABEL)
            @emitter.emit(ASM.push(0, 3, 14))
            @emitter.emit(ASM.lsr_imm(ADDR, TMP, 3))                  # r12 = the block the place is in
            @emitter.emit(ASM.load_immediate(0, @area))
            @emitter.emit(ASM.ldr_offset(3, 0, HELD_AT))
            @emitter.emit(ASM.cmp_reg(3, ADDR))
            @emitter.emit_branch(:bcond, held, cond: :eq)
            @emitter.emit_branch(:bl, WRITE_BACK_LABEL)
            @emitter.emit_branch(:bl, FETCH_LABEL)
            @emitter.place_label(held)
            @emitter.emit(ASM.ldr_offset(3, 0, READ_HELD_AT))
            @emitter.emit(ASM.cmp_reg(3, ADDR))
            @emitter.emit_branch(:bcond, fresh, cond: :ne)
            @emitter.emit(ASM.mvn_imm(3, 0))
            @emitter.emit(ASM.str_offset(3, 0, READ_HELD_AT))
            @emitter.place_label(fresh)
            @emitter.emit(ASM.and_imm(TMP, TMP, IR::SaveLayout::EEPROM_BLOCK - 1))
            @emitter.emit(ASM.add_reg(TMP, TMP, 0))
            @emitter.emit(ASM.strb_offset(2, TMP, BYTES_AT))
            @emitter.emit(ASM.load_immediate(3, 1))
            @emitter.emit(ASM.str_offset(3, 0, CHANGED_AT))
            @emitter.emit(ASM.pop(0, 3, 14))
            @emitter.emit(ASM.bx(14))
          end

          # Read block r12 into the copy whose block number is at +held_at+ and whose bytes are at
          # +bytes_at+. Fetching into the copy a save writes into also says it matches the chip;
          # the caller has written that copy back first. Leaves every register alone.
          def emit_fetch_routine(label, held_at:, bytes_at:)
            byte = @emitter.gensym
            bit = @emitter.gensym
            @emitter.place_label(label)
            @emitter.emit(ASM.push(0, 1, 2, 3, ADDR, 14))
            @emitter.emit(ASM.load_immediate(2, @area))
            @emitter.emit(ASM.str_offset(ADDR, 2, held_at))
            @emitter.emit(ASM.add_imm(1, 2, BITS_AT))                  # r1 = where the bits go
            emit_request_start(1, 1)
            emit_block_number                                          # r12 still the block
            @emitter.emit(ASM.load_immediate(0, 0))
            @emitter.emit(ASM.store_halfword(0, 1))                    # the request's last bit
            emit_copy(from: :bits, to: :chip, count: READ_REQUEST)
            emit_copy(from: :chip, to: :bits, count: READ_REPLY)
            # The 64 bits after the first four, eight to a byte, highest first.
            @emitter.emit(ASM.load_immediate(2, @area))
            @emitter.emit(ASM.add_imm(1, 2, BITS_AT + 8))              # r1 = the first bit of the block
            @emitter.emit(ASM.add_imm(3, 2, bytes_at))                 # r3 = where each byte goes
            @emitter.emit(ASM.load_immediate(14, IR::SaveLayout::EEPROM_BLOCK))
            @emitter.place_label(byte)
            @emitter.emit(ASM.load_immediate(ADDR, 0))
            @emitter.emit(ASM.load_immediate(2, 8))
            @emitter.place_label(bit)
            @emitter.emit(ASM.load_halfword(0, 1))
            @emitter.emit(ASM.add_imm(1, 1, 2))
            @emitter.emit(ASM.and_imm(0, 0, 1))
            @emitter.emit(ASM.orr_reg_lsl(ADDR, 0, ADDR, 1))           # r12 = r12 * 2 + this bit
            @emitter.emit(ASM.subs_imm(2, 2, 1))
            @emitter.emit_branch(:bcond, bit, cond: :ne)
            @emitter.emit(ASM.strb_post(ADDR, 3, 1))
            @emitter.emit(ASM.subs_imm(14, 14, 1))
            @emitter.emit_branch(:bcond, byte, cond: :ne)
            emit_copy_matches_chip(scratch: 0, area: 2) if held_at == HELD_AT
            @emitter.emit(ASM.pop(0, 1, 2, 3, ADDR, 14))
            @emitter.emit(ASM.bx(14))
          end

          # Write the copy a save writes into back to the chip if it differs from it, and wait for
          # the chip to settle. A chip that never settles did not keep the block, so the copy
          # gives the block up: what is read of it next comes from the chip, and a save's check
          # that it went in finds out. Leaves every register alone.
          def emit_write_back_routine
            done = @emitter.gensym
            byte = @emitter.gensym
            bit = @emitter.gensym
            asked = @emitter.gensym
            settled = @emitter.gensym
            @emitter.place_label(WRITE_BACK_LABEL)
            @emitter.emit(ASM.push(0, 1, 2, 3, ADDR, 14))
            @emitter.emit(ASM.load_immediate(2, @area))
            @emitter.emit(ASM.ldr_offset(0, 2, CHANGED_AT))
            @emitter.emit(ASM.cmp_imm(0, 0))
            @emitter.emit_branch(:bcond, done, cond: :eq)
            @emitter.emit(ASM.ldr_offset(ADDR, 2, HELD_AT))
            @emitter.emit(ASM.add_imm(1, 2, BITS_AT))                  # r1 = where the bits go
            emit_request_start(1, 0)
            emit_block_number
            # The eight bytes, each highest bit first.
            @emitter.emit(ASM.add_imm(3, 2, BYTES_AT))                 # r3 = the next byte
            @emitter.emit(ASM.load_immediate(14, IR::SaveLayout::EEPROM_BLOCK))
            @emitter.place_label(byte)
            @emitter.emit(ASM.ldrb_offset(ADDR, 3, 0))
            @emitter.emit(ASM.add_imm(3, 3, 1))
            @emitter.emit(ASM.load_immediate(2, 7))
            @emitter.place_label(bit)
            @emitter.emit(ASM.mov_reg_lsr_reg(0, ADDR, 2))
            @emitter.emit(ASM.and_imm(0, 0, 1))
            @emitter.emit(ASM.store_halfword_post(0, 1, 2))
            @emitter.emit(ASM.subs_imm(2, 2, 1))
            @emitter.emit_branch(:bcond, bit, cond: :ge)
            @emitter.emit(ASM.subs_imm(14, 14, 1))
            @emitter.emit_branch(:bcond, byte, cond: :ne)
            @emitter.emit(ASM.load_immediate(0, 0))
            @emitter.emit(ASM.store_halfword(0, 1))                    # the request's last bit
            emit_copy(from: :bits, to: :chip, count: WRITE_REQUEST)
            # Ask the chip until it has settled, or it has been asked ASKS times.
            @emitter.emit(ASM.load_immediate(1, EEPROM_AT))
            @emitter.emit(ASM.load_immediate(3, ASKS))
            @emitter.place_label(asked)
            @emitter.emit(ASM.load_halfword(0, 1))
            @emitter.emit(ASM.tst_imm(0, 1))
            @emitter.emit_branch(:bcond, settled, cond: :ne)
            @emitter.emit(ASM.subs_imm(3, 3, 1))
            @emitter.emit_branch(:bcond, asked, cond: :ne)
            @emitter.emit(ASM.load_immediate(2, @area))               # never settled: give the block up
            @emitter.emit(ASM.mvn_imm(0, 0))
            @emitter.emit(ASM.str_offset(0, 2, HELD_AT))
            @emitter.place_label(settled)
            emit_copy_matches_chip(scratch: 0, area: 2)
            @emitter.place_label(done)
            @emitter.emit(ASM.pop(0, 1, 2, 3, ADDR, 14))
            @emitter.emit(ASM.bx(14))
          end

          # The copy no longer differs from the chip. Spends +scratch+, and leaves the address of
          # the copy's area in +area+.
          def emit_copy_matches_chip(scratch:, area:)
            @emitter.emit(ASM.load_immediate(area, @area))
            @emitter.emit(ASM.load_immediate(scratch, 0))
            @emitter.emit(ASM.str_offset(scratch, area, CHANGED_AT))
          end

          # The request's first two bits, 1 and then +second+, at r1, which moves on past them.
          # Spends r0.
          def emit_request_start(first, second)
            @emitter.emit(ASM.load_immediate(0, first))
            @emitter.emit(ASM.store_halfword_post(0, 1, 2))
            @emitter.emit(ASM.load_immediate(0, second))
            @emitter.emit(ASM.store_halfword_post(0, 1, 2))
          end

          # Block r12's number in ADDRESS_BITS bits, highest first, at r1, which moves on past
          # them. Spends r0 and r3.
          def emit_block_number
            bit = @emitter.gensym
            @emitter.emit(ASM.load_immediate(3, ADDRESS_BITS - 1))
            @emitter.place_label(bit)
            @emitter.emit(ASM.mov_reg_lsr_reg(0, ADDR, 3))
            @emitter.emit(ASM.and_imm(0, 0, 1))
            @emitter.emit(ASM.store_halfword_post(0, 1, 2))
            @emitter.emit(ASM.subs_imm(3, 3, 1))
            @emitter.emit_branch(:bcond, bit, cond: :ge)
          end

          # The copying engine moves +count+ halfwords between the bits in the roomy memory and the
          # chip, and the console waits while it does. The interrupts are held off while the engine
          # is told what to move, so an interrupt that copies something of its own cannot land
          # between two of those writes. Spends r0, r1, r2 and r3.
          def emit_copy(from:, to:, count:)
            ends = { bits: @area + BITS_AT, chip: EEPROM_AT }
            @emitter.emit(ASM.load_immediate(1, REG_IME))
            @emitter.emit(ASM.load_halfword(2, 1))                     # r2 = whether interrupts were on
            @emitter.emit(ASM.load_immediate(0, 0))
            @emitter.emit(ASM.store_halfword(0, 1))
            @emitter.emit(ASM.load_immediate(3, REG_DMA3SAD))
            @emitter.emit(ASM.load_immediate(0, ends.fetch(from)))
            @emitter.emit(ASM.str_offset(0, 3, 0))
            @emitter.emit(ASM.load_immediate(0, ends.fetch(to)))
            @emitter.emit(ASM.str_offset(0, 3, 4))
            @emitter.emit(ASM.load_immediate(0, COPY_NOW | count))
            @emitter.emit(ASM.str_offset(0, 3, 8))
            @emitter.emit(ASM.store_halfword(2, 1))
          end
        end
      end
    end
  end
end
