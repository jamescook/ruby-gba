# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # SAVE MEMORY: 32K of RAM on the cartridge that a battery keeps while the console is off,
          # which is what a game saves in. The interpreter's save memory is the Advance's
          # battery-backed one, also 32K and also written a byte at a time (IR::SaveLayout), so the
          # same bytes land in the same places on both, and a save made by one starts the other.
          #
          # On a plain LoROM cartridge the console sees that RAM at $70:0000-$70:7FFF, all of it in
          # one bank, so a place in save memory is simply how far into bank $70 it is. Nothing has to
          # be switched on first or banked in, as on the Game Boy Color: the cartridge answers there
          # from power-on. Every routine reads it through a pointer on the direct page that holds
          # $70:0000, with the place in Y — the long indirect address [pointer],Y.
          #
          # rt_save_read(at, width) and rt_save_write(at, value, width) take one, two or four bytes,
          # lowest first; rt_save_sum(at, length) is SaveLayout.checksum's two 16-bit sums;
          # rt_save_erase does nothing, battery-backed RAM needing no wiping before it is written. A
          # place outside the 32K stops the game in the interpreter's words (Faults.save_outside).
          module Saving
            SIZE = 0x8000

            R0 = Memory.register(0)
            R1 = Memory.register(1)
            R2 = Memory.register(2)

            # The direct page the routines work on: the pointer to save memory (three bytes and a
            # spare), the bytes still to go, and the fault's code while it is being said.
            Scratch = Data.define(:pointer, :left, :fault)

            module_function

            def scratch(memory) = Scratch.new(pointer: memory.scratch(4), left: memory.scratch(2), fault: memory.scratch(2))

            def emit(asm, memory, s)
              emit_read(asm, s)
              emit_write(asm, s)
              emit_sum(asm, s)
              asm.label("rt_save_erase")
              asm.rtl
              emit_point_or_stop(asm, memory, s)
            end

            # rt_save_read: R0 = the +width+ (R1) bytes at +at+ (R0), lowest first, the rest nought.
            def emit_read(asm, s)
              asm.label("rt_save_read")
              asm.lda(Frame::SAVE_READ_OUTSIDE)
              asm.ldx(R1)
              asm.jsr(asm.abs("rt_save_point_or_stop"))
              asm.stz(asm.direct(R0))
              asm.stz(asm.direct(R0 + 2))
              asm.ldx(0)
              asm.sep(0x20)
              asm.label("rt_save_read_byte")
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.direct_x(R0))
              asm.iny
              asm.inx
              asm.cpx(asm.direct(R1))
              asm.bne("rt_save_read_byte")
              asm.rep(0x20)
              asm.rtl
            end

            # rt_save_write: the low +width+ (R2) bytes of +value+ (R1) at +at+ (R0), lowest first.
            def emit_write(asm, s)
              asm.label("rt_save_write")
              asm.lda(Frame::SAVE_WRITE_OUTSIDE)
              asm.ldx(R2)
              asm.jsr(asm.abs("rt_save_point_or_stop"))
              asm.ldx(0)
              asm.sep(0x20)
              asm.label("rt_save_write_byte")
              asm.lda(asm.direct_x(R1))
              asm.sta(asm.ind_long_y(s.pointer))
              asm.iny
              asm.inx
              asm.cpx(asm.direct(R2))
              asm.bne("rt_save_write_byte")
              asm.rep(0x20)
              asm.rtl
            end

            # rt_save_sum: R0 = SaveLayout.checksum of the +length+ (R1) bytes at +at+ (R0): a running
            # total of the bytes and a running total of those totals, each kept to 16 bits, the second
            # in R0's high half. A length below nought sums no bytes, as the interpreter's empty range.
            def emit_sum(asm, s)
              asm.label("rt_save_sum")
              asm.lda(Frame::SAVE_READ_OUTSIDE)
              asm.ldx(R1)
              asm.jsr(asm.abs("rt_save_point_or_stop"))
              asm.stz(asm.direct(R0))
              asm.stz(asm.direct(R0 + 2))
              asm.lda(asm.direct(R1 + 2))
              asm.bmi("rt_save_sum_done")
              asm.lda(asm.direct(R1)) # inside the 32K, so the length's low half is all of it
              asm.sta(asm.direct(s.left))
              asm.label("rt_save_sum_byte")
              asm.lda(asm.direct(s.left))
              asm.beq("rt_save_sum_done")
              asm.dec(asm.direct(s.left))
              asm.lda(asm.ind_long_y(s.pointer))
              asm.and_a(0x00FF)
              asm.clc
              asm.adc(asm.direct(R0))
              asm.sta(asm.direct(R0))
              asm.clc
              asm.adc(asm.direct(R0 + 2))
              asm.sta(asm.direct(R0 + 2))
              asm.iny
              asm.bra("rt_save_sum_byte")
              asm.label("rt_save_sum_done")
              asm.rtl
            end

            # rt_save_point_or_stop (JSR): +at+ in R0 and a count of bytes in the working number X
            # names, both 32 bits; A the fault to stop with when they do not fit. They fit, as
            # SaveImage has it, when +at+ is nought or more and +at+ + count is no more than the 32K.
            # Then the pointer holds $70:0000 and Y is +at+. Otherwise the game stops, the place and
            # the size as the fault's two numbers. A count below nought (only a sum's length can be)
            # fits wherever it ends up no further than the 32K, even from a place far past it, and
            # reads no bytes, so Y need not hold all of such a place.
            def emit_point_or_stop(asm, memory, s)
              asm.label("rt_save_point_or_stop")
              asm.sta(asm.direct(s.fault))
              asm.lda(asm.direct(R0 + 2))
              asm.bmi("rt_save_outside") # below nought: never inside
              asm.lda(asm.direct(R0))
              asm.clc
              asm.adc(asm.direct_x(0))
              asm.tay # the end's low half, kept while its high half is worked out
              asm.lda(asm.direct(R0 + 2))
              asm.adc(asm.direct_x(2))
              asm.bvs("rt_save_outside") # a count so big the end came round past the top
              asm.bmi("rt_save_inside") # a count below nought ends before the place: no bytes
              asm.bne("rt_save_outside")
              asm.cpy(SIZE + 1)
              asm.bcs("rt_save_outside")
              asm.label("rt_save_inside")
              asm.stz(asm.direct(s.pointer))
              asm.lda(Console::SNESHardware::SRAM_BANK)
              asm.sta(asm.direct(s.pointer + 2))
              asm.ldy(asm.direct(R0))
              asm.rts
              asm.label("rt_save_outside")
              asm.lda(asm.direct(R0))
              asm.sta(asm.abs(memory[Frame::FAULT], Frame::FAULT_FIRST))
              asm.lda(asm.direct(R0 + 2))
              asm.sta(asm.abs(memory[Frame::FAULT], Frame::FAULT_FIRST + 2))
              asm.lda(SIZE)
              asm.sta(asm.abs(memory[Frame::FAULT], Frame::FAULT_SECOND))
              asm.stz(asm.abs(memory[Frame::FAULT], Frame::FAULT_SECOND + 2))
              asm.lda(asm.direct(s.fault))
              asm.jml(asm.long("rt_fault"))
            end
          end
        end
      end
    end
  end
end
