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
          # The copy to video RAM is Paint's rt_paint_upload, a blank at a time with the screen on,
          # from the chip's RAM rather than work RAM.
          module ChipPaint
            COPY = Console::SNESHardware::GSU_RAM_BANK << 16

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
          end
        end
      end
    end
  end
end
