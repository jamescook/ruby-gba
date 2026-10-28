# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE ROOM IN A BLANK, for copying to video RAM with the screen on.
          #
          # Video RAM, the colour memory and the sprite table can only be written in the vertical
          # blank or with the screen switched off; written while the picture is being drawn, the
          # writes are lost (fullsnes, "SNES PPU Video Memory"). Switching the screen off for a big
          # change shows a black frame. So what a pass changed is copied with the screen on, a piece
          # at a time, each piece only when the line the picture is on says it can be sent before the
          # blank ends, and only while the blank has room for it: a change bigger than one blank
          # holds arrives over several, and the pass counts as shown once it is all there.
          #
          # A blank is 37 of the console's lines, each 1364 of its master clock's cycles, and the
          # copying engine takes 8 of those cycles a byte (fullsnes, "SNES Timing" and "SNES DMA");
          # BLANK_BYTES leaves a third of the blank for the interrupt and the setting up. With the
          # screen still off, before the first pass is shown, there is always room.
          #
          #   rt_blank_begin  as a blank's copying starts (JSR): nothing sent in it yet
          #   rt_blank_room   before each piece (JSR): A is its bytes; returns once there is room
          #   rt_blank_time   before a write that is not a copy (JSR): returns once the blank has a
          #                   line left for it
          module Blank
            BLANK_BYTES = 4096
            # The lines of a North American frame, 0 to 261; the blank is 225 to 261.
            LINES = 262
            FIRST_BLANK_LINE = 225

            # The direct page it works on: the piece's bytes, the bytes sent in this blank, and
            # the line the picture is on.
            Scratch = Data.define(:wanted, :sent, :line)

            module_function

            def scratch(memory) = Scratch.new(wanted: memory.scratch(2), sent: memory.scratch(2), line: memory.scratch(2))

            # Each routine keeps X and Y; A is not kept.
            def emit(asm, memory, s)
              asm.label("rt_blank_begin")
              asm.stz(asm.direct(s.sent))
              asm.rts

              asm.label("rt_blank_room")
              asm.sta(asm.direct(s.wanted))
              asm.lda(asm.abs(memory[Frame::DISPLAY_ON]))
              asm.beq("rt_blank_room_there")
              asm.lda(asm.direct(s.wanted))
              asm.clc
              asm.adc(asm.direct(s.sent))
              asm.cmp(BLANK_BYTES + 1)
              asm.bcs("rt_blank_room_wait")
              emit_line_now(asm)
              asm.cmp(FIRST_BLANK_LINE)
              asm.bcc("rt_blank_room_wait")
              asm.sta(asm.direct(s.line))
              asm.lda(asm.direct(s.wanted))
              7.times { asm.lsr } # the lines it takes: a line copies 170 bytes, so this is more than enough
              asm.sec # and one line more
              asm.adc(asm.direct(s.line))
              asm.cmp(LINES - 1)
              asm.bcc("rt_blank_room_there")
              asm.label("rt_blank_room_wait")
              emit_next_blank(asm, s)
              asm.label("rt_blank_room_there")
              asm.lda(asm.direct(s.wanted))
              asm.clc
              asm.adc(asm.direct(s.sent))
              asm.sta(asm.direct(s.sent))
              asm.rts

              # A single write takes far less than a line, so a line left before the blank ends is
              # time enough for it.
              asm.label("rt_blank_time")
              asm.lda(asm.abs(memory[Frame::DISPLAY_ON]))
              asm.beq("rt_blank_time_there")
              emit_line_now(asm)
              asm.cmp(FIRST_BLANK_LINE)
              asm.bcc("rt_blank_time_wait")
              asm.cmp(LINES - 1)
              asm.bcc("rt_blank_time_there")
              asm.label("rt_blank_time_wait")
              emit_next_blank(asm, s)
              asm.label("rt_blank_time_there")
              asm.rts
            end

            # The next blank waited for, and nothing sent in it yet; X and Y kept.
            def emit_next_blank(asm, s)
              asm.phx
              asm.phy
              asm.jsr(asm.abs("rt_sleep_until_vblank"))
              asm.ply
              asm.plx
              asm.stz(asm.direct(s.sent))
            end

            # A = the line the picture is on now (OPVCT, nine bits), latched by reading SLHV, which
            # latches only while WRIO's top bit is set (rt_picture_start sets it). STAT78 is read
            # first so OPVCT gives its low byte, then its ninth bit. (fullsnes, "SNES PPU Timers and
            # Status".) Leaves A 16 bits wide.
            def emit_line_now(asm)
              h = Console::SNESHardware
              asm.sep(0x20)
              asm.lda(asm.abs(h::STAT78))
              asm.lda(asm.abs(h::SLHV))
              asm.lda(asm.abs(h::OPVCT))
              asm.xba
              asm.lda(asm.abs(h::OPVCT))
              asm.and_a(0x01)
              asm.xba
              asm.rep(0x20)
            end
          end
        end
      end
    end
  end
end
