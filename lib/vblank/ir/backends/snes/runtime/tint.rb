# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # FADES AND TINTS. A Super Nintendo's colour maths can add or subtract a colour, or halve
          # the result, as it draws, but it cannot move a picture a fraction of the way toward
          # another colour; so a fade here is the colours in the colour memory (CGRAM) moved — all
          # 256, from the game's own ("art colors") into a copy in work RAM (SHADOW) that the blank
          # sends — by +steps+ thirty-seconds of the way toward black, white or a colour, by the
          # interpreter's rule for a fade that walks the colours (Reference::Framebuffer#walked_toward
          # and #mixed), each of a colour's three five-bit channels apart:
          #
          #   toward black: c - c × steps / 32
          #   toward white: c + (31 - c) × steps / 32
          #   toward a colour t: (c × (32 - steps) + t × steps) / 32
          #
          # A channel is one of only 32 numbers, so the routine works out what each of them
          # becomes first — 32 for each channel, a table of 96 — with the console's own 8×8
          # multiplier (WRMPYA and WRMPYB, the product at RDMPYL eight cycles later), and then
          # moves each colour by looking its three channels up. Colour 0 is moved too: it is what
          # shows where nothing is drawn, so it fades with the picture.
          #
          #   rt_tint(toward, color, steps)   nothing, when nothing changed (most frames of a game
          #                                   that says its fade every frame)
          #   rt_tint_upload                  in the blank (JSR): the moved colours, if they changed
          module Tint
            TOWARD_BLACK = 0
            TOWARD_WHITE = 1
            TOWARD_COLOR = 2
            STEPS = 32
            CHANNEL_MAX = 31

            # The colours moved (512 bytes), and the fade in force: toward what, the colour, the
            # steps, whether the copy changed since the blank last sent it, and the table of what
            # each channel's 32 numbers become.
            SHADOW = "rt tint shadow"
            STATE = "rt tint"
            TOWARD = 0
            COLOR = 2
            STEPS_AT = 4
            CHANGED = 6
            TABLE = 8
            STATE_BYTES = TABLE + (3 * 32)

            R = ->(n) { Memory.register(n) }

            # The direct page the routine works on.
            Scratch = Data.define(:channel, :target, :factor, :product)

            module_function

            def reserve(memory)
              memory.reserve_far(SHADOW, 512)
              memory.reserve(STATE, STATE_BYTES)
            end

            def scratch(memory)
              Scratch.new(channel: memory.scratch(2), target: memory.scratch(2), factor: memory.scratch(2),
                          product: memory.scratch(2))
            end

            def emit(asm, memory, s)
              emit_tint(asm, memory, s)
              emit_table(asm, memory, s)
              emit_apply(asm, memory)
              emit_upload(asm, memory)
            end

            # The steps held to 0..32 and, when the fade is not the one in force, the colours moved.
            def emit_tint(asm, memory, s)
              state = memory[STATE]
              asm.label("rt_tint")
              asm.lda(asm.direct(R.call(2) + 2))
              asm.bmi("rt_tint_none")
              asm.bne("rt_tint_all")
              asm.lda(asm.direct(R.call(2)))
              asm.cmp(STEPS + 1)
              asm.bcc("rt_tint_held")
              asm.label("rt_tint_all")
              asm.lda(STEPS)
              asm.bra("rt_tint_held")
              asm.label("rt_tint_none")
              asm.lda(0)
              asm.label("rt_tint_held")
              asm.sta(asm.direct(R.call(2)))
              # The same as before: nothing to do. No steps at all is the colours as they are,
              # whatever they were moved toward.
              asm.cmp(asm.abs(state + STEPS_AT))
              asm.bne("rt_tint_changed")
              asm.cmp(0)
              asm.beq("rt_tint_same")
              asm.lda(asm.direct(R.call(0)))
              asm.cmp(asm.abs(state + TOWARD))
              asm.bne("rt_tint_changed")
              asm.lda(asm.direct(R.call(1)))
              asm.cmp(asm.abs(state + COLOR))
              asm.bne("rt_tint_changed")
              asm.label("rt_tint_same")
              asm.rtl
              asm.label("rt_tint_changed")
              [[R.call(0), TOWARD], [R.call(1), COLOR], [R.call(2), STEPS_AT]].each do |from, to|
                asm.lda(asm.direct(from))
                asm.sta(asm.abs(state + to))
              end
              asm.jsr(asm.abs("rt_tint_table"))
              asm.jsr(asm.abs("rt_tint_apply"))
              asm.lda(1)
              asm.sta(asm.abs(state + CHANGED))
              asm.rtl

              # rt_tint_times (JSR): A = the byte at +channel+ times the byte at +factor+, by the
              # console's multiplier.
              asm.label("rt_tint_times")
              asm.sep(0x20)
              asm.lda(asm.direct(s.channel))
              asm.sta(asm.abs(Console::SNESHardware::WRMPYA))
              asm.lda(asm.direct(s.factor))
              asm.sta(asm.abs(Console::SNESHardware::WRMPYB))
              4.times { asm.nop } # the eight cycles the multiplier takes
              asm.rep(0x20)
              asm.lda(asm.abs(Console::SNESHardware::RDMPYL))
              asm.rts
            end

            # rt_tint_table (JSR): what each channel's 32 numbers become, for red, green and blue in
            # turn (the colour moved toward has a channel of each), by the fade in force.
            def emit_table(asm, memory, s)
              state = memory[STATE]
              asm.label("rt_tint_table")
              asm.ldx(0)
              3.times do |channel|
                asm.lda(asm.abs(state + COLOR))
                (channel * 5).times { asm.lsr }
                asm.and_a(CHANNEL_MAX)
                asm.sta(asm.direct(s.target))
                asm.stz(asm.direct(s.channel))
                asm.label("rt_tint_table_#{channel}")
                asm.lda(asm.abs(state + TOWARD))
                asm.cmp(TOWARD_WHITE)
                asm.beq("rt_tint_table_#{channel}_white")
                asm.bcs("rt_tint_table_#{channel}_color")
                # Toward black: the channel less its share.
                asm.lda(asm.abs(state + STEPS_AT))
                asm.sta(asm.direct(s.factor))
                asm.jsr(asm.abs("rt_tint_times"))
                5.times { asm.lsr }
                asm.sta(asm.direct(s.product))
                asm.lda(asm.direct(s.channel))
                asm.sec
                asm.sbc(asm.direct(s.product))
                asm.bra("rt_tint_table_#{channel}_kept")
                # Toward white: the channel and its share of the room above it.
                asm.label("rt_tint_table_#{channel}_white")
                asm.lda(asm.direct(s.channel))
                asm.pha
                asm.eor(CHANNEL_MAX) # 31 less it, for a number of five bits
                asm.sta(asm.direct(s.channel))
                asm.lda(asm.abs(state + STEPS_AT))
                asm.sta(asm.direct(s.factor))
                asm.jsr(asm.abs("rt_tint_times"))
                5.times { asm.lsr }
                asm.sta(asm.direct(s.product))
                asm.pla
                asm.sta(asm.direct(s.channel))
                asm.clc
                asm.adc(asm.direct(s.product))
                asm.bra("rt_tint_table_#{channel}_kept")
                # Toward a colour: the channel's share and the colour's, added, then divided.
                asm.label("rt_tint_table_#{channel}_color")
                asm.lda(STEPS)
                asm.sec
                asm.sbc(asm.abs(state + STEPS_AT))
                asm.sta(asm.direct(s.factor))
                asm.jsr(asm.abs("rt_tint_times"))
                asm.sta(asm.direct(s.product))
                asm.lda(asm.direct(s.channel))
                asm.pha
                asm.lda(asm.direct(s.target))
                asm.sta(asm.direct(s.channel))
                asm.lda(asm.abs(state + STEPS_AT))
                asm.sta(asm.direct(s.factor))
                asm.jsr(asm.abs("rt_tint_times"))
                asm.clc
                asm.adc(asm.direct(s.product))
                5.times { asm.lsr }
                asm.sta(asm.direct(s.product))
                asm.pla
                asm.sta(asm.direct(s.channel))
                asm.lda(asm.direct(s.product))
                asm.label("rt_tint_table_#{channel}_kept")
                asm.sep(0x20)
                asm.sta(asm.abs_x(state + TABLE))
                asm.rep(0x20)
                asm.inx
                asm.inc(asm.direct(s.channel))
                asm.lda(asm.direct(s.channel))
                asm.cmp(32)
                asm.branch_long(:bcc, "rt_tint_table_#{channel}")
              end
              asm.rts
            end

            # rt_tint_apply (JSR): every colour of the game's moved into the copy, through the table.
            def emit_apply(asm, memory)
              state = memory[STATE]
              shadow = memory[SHADOW]
              asm.label("rt_tint_apply")
              asm.ldx(0)
              asm.label("rt_tint_apply_color")
              asm.lda(0)
              asm.sta(asm.long_x(shadow))
              3.times do |channel|
                asm.lda(asm.long_x("art colors"))
                (channel * 5).times { asm.lsr }
                asm.and_a(CHANNEL_MAX)
                asm.phx
                asm.tax
                asm.lda(asm.abs_x(state + TABLE + (channel * 32)))
                asm.plx
                asm.and_a(CHANNEL_MAX)
                (channel * 5).times { asm.asl }
                asm.ora(asm.long_x(shadow))
                asm.sta(asm.long_x(shadow))
              end
              asm.inx
              asm.inx
              asm.cpx(512)
              asm.bne("rt_tint_apply_color")
              asm.rts
            end

            # rt_tint_upload (JSR, in the blank): the moved colours, if they changed since the last
            # blank. A tiled screen sends them first; a painted screen sends them with the last of
            # its tiles, counted against the blank's room with them (Paint's rt_paint_upload), so
            # a faded colour never shows on the last pass's tiles.
            def emit_upload(asm, memory)
              h = Console::SNESHardware
              state = memory[STATE]
              shadow = memory[SHADOW]
              asm.label("rt_tint_upload")
              asm.lda(asm.abs(state + CHANGED))
              asm.beq("rt_tint_upload_none")
              asm.stz(asm.abs(state + CHANGED))
              asm.sep(0x20)
              asm.stz(asm.abs(h::CGADD))
              asm.rep(0x20)
              Picture.emit_dma(asm, h::DMA_TO_ONE_PORT, h::CGDATA, asm.imm(shadow & 0xFFFF), shadow >> 16, 512)
              asm.label("rt_tint_upload_none")
              asm.rts
            end
          end
        end
      end
    end
  end
end
