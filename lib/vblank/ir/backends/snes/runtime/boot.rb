# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # FROM POWER-ON TO THE GAME'S FIRST LINE.
          #
          # The processor wakes up pretending to be a 6502: 8-bit registers, 64K of addresses, and
          # the reset vector read from the end of the cartridge's first bank. The first thing done
          # is to leave that ("native mode": clear the carry, swap it into the emulation flag with
          # XCE), and the next is to jump to the same code in the fast copy of the cartridge (bank
          # $80) and tell the console it can read that copy quickly (MEMSEL).
          #
          # Then everything the console keeps is put in a known state, since nothing of it is
          # cleared at power-on: the stack at the top of the first 8K of work RAM, the direct page
          # at its bottom, the data bank at $80 (so a 16-bit address reaches that 8K, the hardware's
          # registers and the cartridge's first bank alike), every register of the picture chip,
          # all of work RAM, video RAM, the colour memory and the sprite table. The screen stays off
          # ("forced blank") until the end of the first pass of the game, when what the game set up
          # is on it (Runtime::Frame).
          #
          # The copying engine (DMA) does the clearing: told to copy one byte, from a place that
          # does not move, to a port, 64K times, it fills video RAM in a few lines of the screen's
          # time where the processor would take most of a frame.
          module Boot
            module_function

            # The section in the cartridge's first bank: the reset and the interrupts' entry points,
            # each of which jumps on to the fast copy at once.
            def emit_vectors(asm)
              asm.label("rt_reset")
              asm.sei
              asm.clc
              asm.xce # native mode
              asm.jml(asm.long("rt_boot"))
              asm.label("rt_nmi")
              asm.jml(asm.long("rt_vblank_interrupt"))
              asm.label("rt_irq")
              asm.rti
            end

            # rt_boot: the console made ready, then the game's main routine, +main+, for good.
            def emit(asm, main:)
              h = Console::SNESHardware
              asm.label("rt_boot")
              asm.rep(0x30)
              asm.lda(Memory::STACK_TOP)
              asm.tcs
              asm.lda(0)
              asm.tcd
              asm.sep(0x20)
              asm.lda(0x80)
              asm.pha
              asm.plb # the data bank: $80
              asm.lda(1)
              asm.sta(asm.abs(h::MEMSEL)) # the fast copy, read fast
              asm.lda(h::FORCED_BLANK)
              asm.sta(asm.abs(h::INIDISP))
              asm.stz(asm.abs(h::NMITIMEN))
              asm.rep(0x20)
              emit_registers_cleared(asm)
              emit_memories_cleared(asm)
              asm.jsl(asm.long("rt_start"))
              asm.jsl(asm.long(main))
              asm.label("rt_main_returned")
              asm.jml(asm.long("rt_halt"))
            end

            # Every register of the picture chip at nought but the ones that want something else:
            # the screen off, sprites of 8 and 16 pixels, and the video RAM address moving on a word
            # after each write of its high byte.
            def emit_registers_cleared(asm)
              h = Console::SNESHardware
              asm.sep(0x20)
              (h::OBSEL..h::COLDATA).each do |register|
                next if register == h::VMDATAL || register == h::VMDATAH || register == h::CGDATA || register == h::OAMDATA

                asm.stz(asm.abs(register))
                # The scroll and mode 7 registers are written twice, low byte then high.
                asm.stz(asm.abs(register)) if (h::BG1HOFS..h::BG4VOFS).cover?(register) || (h::M7A..h::M7Y).cover?(register)
              end
              asm.lda(h::VMAIN_WORD)
              asm.sta(asm.abs(h::VMAIN))
              asm.lda(0xE0) # colour maths' fixed colour: black, all three
              asm.sta(asm.abs(h::COLDATA))
              asm.stz(asm.abs(h::SETINI))
              asm.stz(asm.abs(h::WRIO))
              asm.stz(asm.abs(h::HDMAEN))
              asm.rep(0x20)
            end

            # Work RAM, video RAM, the colour memory and the sprite table, all noughts, by the copying
            # engine's channel 0 from a byte of nought in the cartridge (rt_zero).
            def emit_memories_cleared(asm)
              h = Console::SNESHardware
              # Video RAM: 64K, the two ports by turns.
              asm.stz(asm.abs(h::VMADDL))
              emit_fill(asm, h::DMA_TO_TWO_PORTS | h::DMA_FIXED_SOURCE, h::VMDATAL & 0xFF, 0)
              # The colour memory: 512 bytes.
              asm.sep(0x20)
              asm.stz(asm.abs(h::CGADD))
              asm.rep(0x20)
              emit_fill(asm, h::DMA_FIXED_SOURCE, h::CGDATA & 0xFF, 512)
              # The sprite table: 544 bytes. A sprite at nought would show at the top left, so every
              # sprite is put below the screen afterwards by the picture's own start (Runtime::Picture).
              asm.stz(asm.abs(h::OAMADDL))
              emit_fill(asm, h::DMA_FIXED_SOURCE, h::OAMDATA & 0xFF, 544)
              # Work RAM, all 128K but the stack in use: through its own port, from $7E:0000, two
              # copies of 64K.
              asm.stz(asm.abs(h::WMADDL))
              asm.sep(0x20)
              asm.stz(asm.abs(h::WMADDL + 2))
              asm.rep(0x20)
              2.times { emit_fill(asm, h::DMA_FIXED_SOURCE, h::WMDATA & 0xFF, 0) }
            end

            # Channel 0 copying the byte at rt_zero to the port $21+port, +count+ times (0 is 65536).
            def emit_fill(asm, mode, port, count)
              h = Console::SNESHardware
              asm.sep(0x20)
              asm.lda(mode)
              asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
              asm.lda(port)
              asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
              asm.lda(asm.bank_of("rt_zero"))
              asm.sta(asm.abs(h::DMA_BASE + h::A1B))
              asm.rep(0x20)
              asm.lda(asm.imm("rt_zero"))
              asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
              asm.lda(count)
              asm.sta(asm.abs(h::DMA_BASE + h::DASL))
              asm.sep(0x20)
              asm.lda(1)
              asm.sta(asm.abs(h::MDMAEN))
              asm.rep(0x20)
            end

            # The byte of nought the fills copy from, and the word of nought beside it.
            def emit_zero(asm)
              asm.label("rt_zero")
              asm.data_words(0)
            end
          end
        end
      end
    end
  end
end
