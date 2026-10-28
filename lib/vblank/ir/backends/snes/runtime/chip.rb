# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE SUPER FX, PUT TO WORK BY THE CONSOLE (a cartridge with that chip only).
          #
          # The Super FX is a second processor inside the cartridge (SNES::GSU says what it is). The
          # console's processor hands it a program address and lets it go; it runs from the
          # cartridge's ROM and writes into its own RAM, and stops itself with STOP. Two rules make
          # the handing over safe on a real console, both from how the board is wired (fullsnes,
          # "SNES Cart GSU-n Memory Map" and "I/O Ports"; bsnes, sfc/coprocessor/superfx/bus.cpp):
          #
          #   - WHILE IT RUNS IT OWNS THE ROM AND ITS RAM (SCMR's RON and RAN bits). The console's
          #     processor reading the ROM then gets nothing useful (bsnes hands it the same few
          #     bytes, whatever the address), so the console cannot run its own code from the
          #     cartridge while it waits: the waiting loop is copied into work RAM at power-on and
          #     runs from there (rt_chip_wait, at WAIT).
          #   - ITS INTERRUPTS GO ELSEWHERE. While the chip owns the ROM, the console's interrupt
          #     vectors read as $0100 to $010C in work RAM, where this runtime keeps the vertical
          #     blank's direct page. So the vertical blank's interrupt is switched off while the chip
          #     runs, and the waiting loop counts the blanks that go by instead, reading HVBJOY. Once
          #     the chip stops, the frames it took are added to the frame count, and the interrupt is
          #     switched on again; the one blank it would have announced is let go, so it never lands
          #     outside the blank and copies into video memory while the picture is being drawn.
          #
          # The chip runs at 21 MHz (CLSR), and is told not to interrupt the console when it stops
          # (CFGR): the waiting loop sees its GO bit fall instead.
          module Chip
            WAIT = "rt chip wait"
            SEEN = "rt chip seen"
            MISSED = "rt chip missed"
            WAIT_BYTES = 48

            module_function

            def reserve(memory)
              memory.reserve(WAIT, WAIT_BYTES)
              memory.reserve(SEEN, 1)
              memory.reserve(MISSED, 1)
            end

            # rt_chip_start: the chip set up and the waiting loop copied into work RAM, once, at
            # power-on. rt_chip_run: the GSU program at the 24-bit address in R0's low three bytes
            # run to its STOP, with R0's fourth byte the picture's layout bits for SCMR (its colours
            # and height; nought when it plots nothing). Both are called long (JSL) with A, X and Y
            # 16 bits wide, and give them back so. The chip's other registers ($3000-$301D) are the
            # caller's to set before rt_chip_run.
            def emit(asm, memory)
              emit_start(asm, memory)
              emit_run(asm, memory)
            end

            def emit_start(asm, memory)
              h = Console::SNESHardware
              code = wait_code(memory)
              asm.label("rt_chip_start")
              asm.sep(0x20)
              asm.lda(h::GSU_FAST_CLOCK)
              asm.sta(asm.abs(h::GSU_CLSR))
              asm.lda(h::GSU_IRQ_OFF)
              asm.sta(asm.abs(h::GSU_CFGR))
              asm.stz(asm.abs(h::GSU_SCMR))
              # WRIO's top bit lets a read of SLHV latch the line the picture is on, which ChipPaint
              # reads to know how much of the blank is left. It is the bit's power-on value.
              asm.lda(0x80)
              asm.sta(asm.abs(h::WRIO))
              asm.ldx(0)
              asm.label("rt_chip_copy_wait")
              asm.lda(asm.long_x("rt_chip_wait_code"))
              asm.sta(asm.abs_x(memory[WAIT]))
              asm.inx
              asm.cpx(code.bytesize)
              asm.bne("rt_chip_copy_wait")
              asm.rep(0x20)
              asm.rtl
              asm.label("rt_chip_wait_code")
              asm.data_bytes(code.unpack("C*"))
            end

            def emit_run(asm, memory)
              h = Console::SNESHardware
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              asm.label("rt_chip_run")
              asm.sep(0x20)
              asm.stz(asm.abs(h::NMITIMEN))
              asm.lda(asm.abs(h::RDNMI))
              asm.lda(asm.abs(h::HVBJOY))
              asm.and_a(0x80)
              asm.sta(at.call(SEEN))
              asm.stz(at.call(MISSED))
              # The chip sees the cartridge's ROM in banks $00-$3F, where the console sees it in
              # banks $80-$BF as well.
              asm.lda(asm.direct(2))
              asm.and_a(0x3F)
              asm.sta(asm.abs(h::GSU_PBR))
              asm.lda(asm.direct(3))
              asm.ora(h::GSU_OWNS_ROM | h::GSU_OWNS_RAM)
              asm.rep(0x30)
              asm.and_a(0x00FF)
              asm.tax # what SCMR will say, handed to the waiting loop
              asm.lda(asm.direct(0)) # where the program starts, the same
              asm.jsl(asm.long(memory[WAIT]))
              asm.sep(0x20)
              asm.lda(asm.abs(h::RDNMI))
              asm.lda(h::NMI_ON)
              asm.sta(asm.abs(h::NMITIMEN))
              asm.rep(0x20)
              asm.lda(at.call(MISSED))
              asm.and_a(0x00FF)
              asm.clc
              asm.adc(at.call(Frame::FRAMES))
              asm.sta(at.call(Frame::FRAMES))
              asm.bcc("rt_chip_ran")
              asm.inc(at.call(Frame::FRAMES, 2))
              asm.label("rt_chip_ran")
              asm.rtl
            end

            # The waiting loop, as bytes to copy into work RAM. Called long with A, X and Y 16 bits
            # wide, A the program's address and X what SCMR is to say, it hands the chip the ROM and
            # its RAM and starts it, goes round until the chip's GO bit falls, adding one to MISSED
            # each time the vertical blank begins, and takes the ROM and RAM back. All of that is
            # here rather than in the cartridge because from the moment the chip owns the ROM until
            # it gives it back, the console must not read an instruction from there. Its branches
            # are relative and every address it names is fixed, so it runs wherever it is copied to.
            # It gives A back 8 bits wide.
            def wait_code(memory)
              h = Console::SNESHardware
              asm = W65816.new("rt chip wait")
              asm.tay
              asm.sep(0x20)
              asm.txa
              asm.sta(asm.abs(h::GSU_SCMR))
              asm.rep(0x20)
              asm.tya
              # Writing R15's high byte starts the chip: a 16-bit store writes $301E, then $301F.
              asm.sta(asm.abs(h::GSU_R15))
              asm.sep(0x20)
              asm.label("wait")
              asm.lda(asm.abs(h::GSU_SFR))
              asm.and_a(h::GSU_GO)
              asm.beq("stopped")
              asm.lda(asm.abs(h::HVBJOY))
              asm.and_a(0x80)
              asm.cmp(asm.abs(memory[SEEN]))
              asm.beq("wait")
              asm.sta(asm.abs(memory[SEEN]))
              asm.and_a(0x80) # a store leaves the flags as the comparison set them; this sets them anew
              asm.beq("wait") # the blank ended
              asm.inc(asm.abs(memory[MISSED])) # a blank began
              asm.bra("wait")
              asm.label("stopped")
              asm.stz(asm.abs(h::GSU_SCMR)) # the ROM and the RAM are the console's again
              asm.rtl
              code = Linker.new([asm.section]).link.bytes.byteslice(0, asm.here)
              raise "the chip's waiting loop is #{code.bytesize} bytes, over #{WAIT_BYTES}" if code.bytesize > WAIT_BYTES

              code
            end
          end
        end
      end
    end
  end
end
