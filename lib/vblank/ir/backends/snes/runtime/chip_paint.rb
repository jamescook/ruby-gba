# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # A PAINTED SCREEN ON A SUPER FX CARTRIDGE: what Paint does differently there.
          #
          # The picture is kept where Paint keeps it, laid out the same way (896 tiles of eight bits a
          # pixel, in the order they are shown), but in the Super FX's own RAM, $70:0000 to $70:DFFF,
          # rather than the last bank of work RAM. The console's processor can read and write that RAM
          # whenever the chip is stopped, so every one of Paint's routines paints there unchanged; the
          # chip does the work that is the most of it:
          #
          #   rt_paint_clear  the whole screen in one colour is painted by the chip: 28,672 words,
          #                   from a loop it keeps in its own cache (rt_chip_clear), while the console
          #                   waits (Runtime::Chip)
          #
          # THE COPY TO VIDEO RAM IS SPREAD OVER BLANKS, WITH THE SCREEN ON. A plain cartridge
          # switches the screen off to copy (Picture's rt_upload), so a pass that changed the whole
          # screen shows a black frame. Here the copy goes a row of tiles at a time, each row only
          # while the vertical blank lasts and only while the blank has room for it (BLANK_BYTES),
          # so the screen never goes black: a big change arrives over a few frames, top to bottom.
          # Video RAM can only be written in the blank or with the screen off; written while the
          # picture is being drawn, the writes are lost (fullsnes, "SNES PPU Video Memory").
          #
          # A blank is 37 of the console's lines, each 1364 of its master clock's cycles, and the
          # copying engine takes 8 of those cycles a byte (fullsnes, "SNES Timing" and "SNES DMA");
          # BLANK_BYTES leaves a third of the blank for the interrupt and the setting up.
          module ChipPaint
            COPY = Console::SNESHardware::GSU_RAM_BANK << 16
            BLANK_BYTES = 4096

            module_function

            # The colour at +place+ (R0) as the four words a tile's row keeps it in, a pair of planes
            # each, into the chip's R3 to R6; then the chip paints every tile with them.
            def emit_clear_whole(asm)
              h = Console::SNESHardware
              r = Paint::R
              4.times do |pair|
                asm.stz(asm.direct(r.call(5)))
                2.times do |half|
                  skip = "rt_chip_clear_plane_#{pair}_#{half}"
                  asm.lda(asm.direct(r.call(0)))
                  asm.and_a(1 << ((pair * 2) + half))
                  asm.beq(skip)
                  asm.lda(half.zero? ? 0x00FF : 0xFF00)
                  asm.tsb(asm.direct(r.call(5)))
                  asm.label(skip)
                end
                asm.lda(asm.direct(r.call(5)))
                asm.sta(asm.abs(h::GSU_R0 + ((3 + pair) * 2)))
              end
              asm.lda(asm.imm("rt_chip_clear"))
              asm.sta(asm.direct(r.call(0)))
              asm.lda(asm.bank_of("rt_chip_clear"))
              asm.sta(asm.direct(r.call(0) + 2)) # the bank, and nought: the chip plots nothing
              asm.jsl(asm.long("rt_chip_run"))
            end

            # The chip's program. A tile's 64 bytes are its eight rows' planes 0 and 1, then 2 and 3,
            # then 4 and 5, then 6 and 7 (Paint), so each tile is eight words of R3, eight of R4,
            # eight of R5 and eight of R6. STW writes the source's low byte at R1 and its high byte
            # after it. LOOP counts R12 down and goes back to R13 until it reaches nought; CACHE
            # first keeps the loop in the chip's 512 bytes of cache, which it runs from several times
            # faster than from the ROM.
            def gsu_section
              gsu = GSU.new("rt chip paint")
              gsu.label("rt_chip_clear")
              gsu.iwt(1, 0)
              gsu.iwt(12, Paint::COLUMNS * Paint::ROWS)
              gsu.iwt(13, "rt_chip_clear_tile")
              gsu.cache
              gsu.label("rt_chip_clear_tile")
              4.times do |pair|
                8.times do
                  gsu.from(3 + pair)
                  gsu.stw(1)
                  gsu.inc(1)
                  gsu.inc(1)
                end
              end
              gsu.loop
              gsu.nop
              gsu.stop
              gsu.section
            end

            # rt_paint_upload (JSR, in the blank, the screen on): each row of tiles changed, the
            # stretch from its leftmost changed tile to its rightmost, copied to video RAM — a row
            # only while the blank lasts and has room for it, waiting for the next blank when not.
            def emit_upload(asm, memory, s)
              h = Console::SNESHardware
              dirty = memory[Paint::DIRTY]
              asm.label("rt_paint_upload")
              asm.ldx(0)
              asm.stz(asm.direct(s.row)) # the row's first tile
              asm.stz(asm.direct(s.count)) # the bytes copied in this blank
              asm.label("rt_paint_upload_row")
              asm.lda(asm.abs_x(dirty + 2))
              asm.cmp(asm.abs_x(dirty))
              asm.branch_long(:bcc, "rt_paint_upload_next")
              asm.sec
              asm.sbc(asm.abs_x(dirty))
              asm.inc
              6.times { asm.asl }
              asm.sta(asm.direct(s.chunk))
              # Room in this blank, and still in it? If not, the next blank.
              asm.clc
              asm.adc(asm.direct(s.count))
              asm.cmp(BLANK_BYTES + 1)
              asm.bcs("rt_paint_upload_wait")
              asm.lda(asm.abs(h::HVBJOY))
              asm.and_a(0x0080)
              asm.bne("rt_paint_upload_room")
              asm.label("rt_paint_upload_wait")
              asm.phx
              asm.jsr(asm.abs("rt_sleep_until_vblank"))
              asm.plx
              asm.stz(asm.direct(s.count))
              asm.label("rt_paint_upload_room")
              asm.lda(asm.direct(s.chunk))
              asm.sta(asm.abs(h::DMA_BASE + h::DASL))
              asm.clc
              asm.adc(asm.direct(s.count))
              asm.sta(asm.direct(s.count))
              asm.lda(asm.abs_x(dirty))
              asm.clc
              asm.adc(asm.direct(s.row))
              5.times { asm.asl } # the first tile's word in video RAM
              asm.sta(asm.abs(h::VMADDL))
              asm.asl # ...and its byte in the copy
              asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
              asm.sep(0x20)
              asm.lda(COPY >> 16)
              asm.sta(asm.abs(h::DMA_BASE + h::A1B))
              asm.lda(h::DMA_TO_TWO_PORTS)
              asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
              asm.lda(h::VMDATAL & 0xFF)
              asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
              asm.lda(1)
              asm.sta(asm.abs(h::MDMAEN))
              asm.rep(0x20)
              asm.lda(Paint::NONE_LEFT)
              asm.sta(asm.abs_x(dirty))
              asm.stz(asm.abs_x(dirty + 2))
              asm.label("rt_paint_upload_next")
              asm.lda(asm.direct(s.row))
              asm.clc
              asm.adc(Paint::COLUMNS)
              asm.sta(asm.direct(s.row))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.cpx(Paint::ROWS * 4)
              asm.branch_long(:bne, "rt_paint_upload_row")
              asm.rts
            end
          end
        end
      end
    end
  end
end
