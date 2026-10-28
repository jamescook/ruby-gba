# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # A PAINTED SCREEN on a console that only draws tiles.
          #
          # The Advance has screens that are a picture in memory, a colour for every pixel, which a
          # game paints into (`screen :bitmap`). A Super Nintendo has no such thing: everything it
          # shows is tiles. So a painted screen here is one background of 896 tiles, 32 across and 28
          # down, each shown once, so that together they are the screen: a pixel of the picture is a
          # pixel of one of them. Mode 3 (BGMODE) gives its first layer tiles of eight bits a pixel,
          # so every pixel is any of the 256 colours of the colour memory (SNES::PaintedArt picks
          # them while the game is built). Each tile is 64 bytes, so the 896 of them take 56K of the
          # console's 64K of video RAM:
          #
          #   $0000-$6FFF  the screen's tiles, in the order they are shown, row by row (words)
          #   $7000-$73FF  the layer's map: cell n shows tile n
          #
          # THE GAME PAINTS INTO A COPY in work RAM — the whole upper bank, $7F:0000 to $7F:DFFF, laid
          # out the same way — and the tiles it changed go to video RAM in the blank after the pass
          # (rt_paint_upload). For each row of tiles the copy keeps the leftmost and rightmost tile
          # painted since the last blank (DIRTY), and the tiles between are one stretch of video RAM,
          # so each row is one copy. The screen is switched off for the copy (Runtime::Picture's
          # rt_upload), so a pass that changed the whole screen is copied whole, over the blank and on
          # into the frame after; that frame is black, and the pass counts as shown once it is done.
          #
          # A TILE KEEPS ITS PIXELS IN PLANES. A pixel's colour is a place in the colour memory, eight
          # bits; a tile keeps the first bit of each of its 64 pixels together, a row of eight pixels
          # to a byte, leftmost pixel in the top bit, then the second bit of each, and so on. Its 64
          # bytes are the rows' planes 0 and 1 side by side (row 0's plane 0, row 0's plane 1, row
          # 1's...), then planes 2 and 3, then 4 and 5, then 6 and 7. So painting one pixel touches
          # eight bytes, but painting eight pixels of a row of one tile touches the same eight bytes:
          # everything here paints a row of a tile at a time, a MASK of which of its eight pixels.
          #
          #   rt_paint_start    at power-on: Mode 3, the map, the colours, the whole screen to paint in
          #   rt_paint_area     what follows paints only inside a rectangle (`inside`)
          #   rt_paint_clear    the screen, or the rectangle, in one colour
          #   rt_paint_fill     a rectangle in one colour
          #   rt_paint_blit     a picture (SNES::PaintedArt's) at a place
          #   rt_paint_blit_one_of  one of a list of pictures, by number
          #   rt_paint_save     the patch of the screen under a sprite, kept
          #   rt_paint_restore  the patch put back
          #   rt_paint_upload   in the blank: the tiles changed, row by row
          module Paint
            COLUMNS = 32
            ROWS = 28
            TILE_BYTES = 64
            WIDTH = COLUMNS * 8
            HEIGHT = ROWS * 8
            COPY = 0x7F0000
            COPY_BYTES = COLUMNS * ROWS * TILE_BYTES
            MAP = 0x7000
            # The copy's first byte as the console's work RAM port counts it (its 17-bit address).
            COPY_IN_WORK_RAM = 0x10000

            # Where painting is held to (`inside`): its left, top, right and bottom, right and bottom
            # just past it.
            AREA = "rt paint area"
            # For each row of tiles, the leftmost and rightmost tile changed since the last blank: a
            # word each. A row with none has its leftmost past its rightmost (NONE_LEFT, 0).
            DIRTY = "rt paint dirty"
            NONE_LEFT = COLUMNS

            # The direct page the routines work on.
            Scratch = Data.define(:left, :right, :top, :bottom, :area, :y, :row, :count, :chunk, :last,
                                  :shift, :mask, :not_mask, :planes, :left_planes, :right_planes,
                                  :pointer, :height, :across, :first_x, :temp, :column) do
              def area_left = area
              def area_top = area + 2
              def area_right = area + 4
              def area_bottom = area + 6
            end

            R = ->(n) { Memory.register(n) }

            module_function

            # On a cartridge with a Super FX (+chip+) the copy is the chip's RAM, so work RAM keeps none.
            def reserve(memory, chip: false)
              memory.reserve_last_bank("rt paint copy", COPY_BYTES) unless chip
              memory.reserve(AREA, 8)
              memory.reserve(DIRTY, ROWS * 4)
            end

            def scratch(memory)
              Scratch.new(left: memory.scratch(2), right: memory.scratch(2), top: memory.scratch(2),
                          bottom: memory.scratch(2), area: memory.scratch(8), y: memory.scratch(2),
                          row: memory.scratch(2), count: memory.scratch(2), chunk: memory.scratch(2),
                          last: memory.scratch(2), shift: memory.scratch(2), mask: memory.scratch(2),
                          not_mask: memory.scratch(2), planes: memory.scratch(8), left_planes: memory.scratch(10),
                          right_planes: memory.scratch(10), pointer: memory.scratch(4), height: memory.scratch(2),
                          across: memory.scratch(2), first_x: memory.scratch(2), temp: memory.scratch(4),
                          column: memory.scratch(2))
            end

            # +chip+ for a cartridge with a Super FX: see ChipPaint, which says what changes there.
            def emit(asm, memory, s, chip: false)
              bank = chip ? ChipPaint::COPY >> 16 : COPY >> 16
              emit_start(asm, memory)
              emit_area(asm, memory, s)
              emit_helpers(asm, memory, s)
              emit_clear(asm, memory, s, chip)
              emit_fill(asm, memory, s, bank)
              emit_blit(asm, memory, s, bank)
              emit_patches(asm, memory, s, bank)
              chip ? ChipPaint.emit_upload(asm, memory, s) : emit_upload(asm, memory, s)
              emit_tables(asm)
            end

            # --- power-on ---

            def emit_start(asm, memory)
              h = Console::SNESHardware
              asm.label("rt_paint_start")
              asm.sep(0x20)
              asm.lda(0x03) # mode 3: the first layer's tiles eight bits a pixel
              asm.sta(asm.abs(h::BGMODE))
              asm.stz(asm.abs(h::BG12NBA)) # its tiles from $0000
              asm.lda((MAP >> 10) << 2) # its map at $7000, 32×32 cells
              asm.sta(asm.abs(h::BG1SC))
              asm.lda(0x01) # the first layer alone on the main screen
              asm.sta(asm.abs(h::TM))
              # The screen's first row is the console's line 1 (see Runtime::Picture's scroll), so the
              # layer is scrolled up one: -1 is $3FF in the register's ten bits.
              asm.lda(0xFF)
              asm.sta(asm.abs(h::BG1VOFS))
              asm.lda(0x03)
              asm.sta(asm.abs(h::BG1VOFS))
              asm.rep(0x20)
              # The map: cell n shows tile n, and the four rows of cells below the screen tile 0.
              asm.lda(MAP)
              asm.sta(asm.abs(h::VMADDL))
              asm.ldx(0)
              asm.label("rt_paint_start_cell")
              asm.txa
              asm.cpx(COLUMNS * ROWS)
              asm.bcc("rt_paint_start_shown")
              asm.lda(0)
              asm.label("rt_paint_start_shown")
              asm.sta(asm.abs(h::VMDATAL))
              asm.inx
              asm.cpx(COLUMNS * COLUMNS)
              asm.bne("rt_paint_start_cell")
              # The colours, all 256.
              asm.sep(0x20)
              asm.stz(asm.abs(h::CGADD))
              asm.rep(0x20)
              Picture.emit_dma(asm, h::DMA_TO_ONE_PORT, h::CGDATA, asm.imm("art colors"), asm.bank_of("art colors"), 512)
              # Paint anywhere, and nothing changed yet. The copy and video RAM start all nought,
              # black, as Boot leaves them.
              asm.jsl(asm.long("rt_paint_anywhere"))
              asm.ldx(0)
              asm.label("rt_paint_start_row")
              asm.lda(NONE_LEFT)
              asm.sta(asm.abs_x(memory[DIRTY]))
              asm.stz(asm.abs_x(memory[DIRTY] + 2))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.cpx(ROWS * 4)
              asm.bne("rt_paint_start_row")
              asm.rtl
            end

            # --- the area ---

            # rt_paint_area(x, y, w, h): painting held to the rectangle, as far as it is on the
            # screen. rt_paint_anywhere: the whole screen. The lowering keeps the area there was
            # before an `inside` on the stack and puts it back after (Lowering::Paint).
            def emit_area(asm, memory, s)
              area = memory[AREA]
              asm.label("rt_paint_area")
              # The right and bottom: the left and top plus the width and height.
              [[R.call(0), R.call(2), R.call(4)], [R.call(1), R.call(3), R.call(5)]].each do |at, size, out|
                asm.clc
                asm.lda(asm.direct(at))
                asm.adc(asm.direct(size))
                asm.sta(asm.direct(out))
                asm.lda(asm.direct(at + 2))
                asm.adc(asm.direct(size + 2))
                asm.sta(asm.direct(out + 2))
              end
              asm.stz(asm.direct(s.temp))
              asm.lda(WIDTH)
              asm.sta(asm.direct(s.temp + 2))
              emit_clamp(asm, "area", R.call(0), s.temp, s.temp + 2, s.left)
              emit_clamp(asm, "area", R.call(4), s.temp, s.temp + 2, s.right)
              asm.lda(HEIGHT)
              asm.sta(asm.direct(s.temp + 2))
              emit_clamp(asm, "area", R.call(1), s.temp, s.temp + 2, s.top)
              emit_clamp(asm, "area", R.call(5), s.temp, s.temp + 2, s.bottom)
              [s.left, s.top, s.right, s.bottom].each_with_index do |from, i|
                asm.lda(asm.direct(from))
                asm.sta(asm.abs(area + (i * 2)))
              end
              asm.rtl

              asm.label("rt_paint_anywhere")
              asm.stz(asm.abs(area))
              asm.stz(asm.abs(area + 2))
              asm.lda(WIDTH)
              asm.sta(asm.abs(area + 4))
              asm.lda(HEIGHT)
              asm.sta(asm.abs(area + 6))
              asm.rtl
            end

            # +out+ = the 32-bit number at +at+ held between the words at +low+ and +high+ (two small
            # numbers, nought or more).
            def emit_clamp(asm, routine, at, low, high, out)
              tag = "rt paint clamp #{routine} #{out}"
              asm.lda(asm.direct(at + 2))
              asm.bmi("#{tag} low")
              asm.bne("#{tag} high")
              asm.lda(asm.direct(at))
              asm.cmp(asm.direct(low))
              asm.bcc("#{tag} low")
              asm.cmp(asm.direct(high))
              asm.bcs("#{tag} high")
              asm.bra("#{tag} keep")
              asm.label("#{tag} low")
              asm.lda(asm.direct(low))
              asm.bra("#{tag} keep")
              asm.label("#{tag} high")
              asm.lda(asm.direct(high))
              asm.label("#{tag} keep")
              asm.sta(asm.direct(out))
            end

            # --- what several routines share ---

            def emit_helpers(asm, memory, s)
              area = memory[AREA]
              dirty = memory[DIRTY]

              # rt_paint_take_area (JSR): the area onto the direct page.
              asm.label("rt_paint_take_area")
              4.times do |i|
                asm.lda(asm.abs(area + (i * 2)))
                asm.sta(asm.direct(s.area + (i * 2)))
              end
              asm.rts

              # rt_paint_mark (JSR): rows of pixels +top+ up to +bottom+, tiles +chunk+ to +last+
              # across, said changed.
              asm.label("rt_paint_mark")
              asm.lda(asm.direct(s.bottom))
              asm.dec
              3.times { asm.lsr }
              2.times { asm.asl }
              asm.sta(asm.direct(s.temp))
              asm.lda(asm.direct(s.top))
              3.times { asm.lsr }
              2.times { asm.asl }
              asm.tax
              asm.label("rt_paint_mark_row")
              asm.lda(asm.direct(s.chunk))
              asm.cmp(asm.abs_x(dirty))
              asm.bcs("rt_paint_mark_left_kept")
              asm.sta(asm.abs_x(dirty))
              asm.label("rt_paint_mark_left_kept")
              asm.lda(asm.direct(s.last))
              asm.cmp(asm.abs_x(dirty + 2))
              asm.bcc("rt_paint_mark_right_kept")
              asm.sta(asm.abs_x(dirty + 2))
              asm.label("rt_paint_mark_right_kept")
              asm.cpx(asm.direct(s.temp))
              asm.beq("rt_paint_mark_done")
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.bra("rt_paint_mark_row")
              asm.label("rt_paint_mark_done")
              asm.rts

              # rt_paint_row_start (JSR): A = where row +y+ of pixels starts in the copy, in its first
              # row of tiles: its row of tiles × 2048, and two bytes for each row of pixels down it.
              asm.label("rt_paint_row_start")
              asm.lda(asm.direct(s.y))
              asm.and_a(0x00F8)
              asm.xba
              asm.sta(asm.direct(s.row))
              asm.lda(asm.direct(s.y))
              asm.and_a(0x0007)
              asm.asl
              asm.ora(asm.direct(s.row))
              asm.sta(asm.direct(s.row))
              asm.rts

              # rt_paint_column_mask (JSR): A = the pixels of the tile whose left edge is at A that
              # are between +left+ and +right+ (a byte, top bit leftmost), in both bytes of the word.
              # Uses X, and the tables are read with long addresses, whatever the data bank is.
              asm.label("rt_paint_column_mask")
              asm.sta(asm.direct(s.column))
              asm.lda(asm.direct(s.right))
              asm.sec
              asm.sbc(asm.direct(s.column))
              asm.bmi("rt_paint_column_mask_none")
              asm.beq("rt_paint_column_mask_none")
              asm.cmp(8)
              asm.bcc("rt_paint_column_mask_to")
              asm.lda(8)
              asm.label("rt_paint_column_mask_to")
              asm.asl
              asm.tax
              asm.lda(asm.direct(s.left))
              asm.sec
              asm.sbc(asm.direct(s.column))
              asm.bpl("rt_paint_column_mask_from")
              asm.lda(0)
              asm.label("rt_paint_column_mask_from")
              asm.cmp(8)
              asm.bcs("rt_paint_column_mask_none")
              asm.asl
              asm.pha
              asm.lda(asm.long_x("rt_paint_up_to"))
              asm.plx
              asm.and_a(asm.long_x("rt_paint_from_left"))
              asm.rts
              asm.label("rt_paint_column_mask_none")
              asm.lda(0)
              asm.rts
            end

            # --- clearing ---

            # rt_paint_clear(place, rows): the screen in the colour at +place+, from the cleared row of
            # tiles numbered +rows+ (the table "paint clear rows"). Held to an area, the area alone,
            # painted as a rectangle.
            def emit_clear(asm, memory, s, chip)
              h = Console::SNESHardware
              dirty = memory[DIRTY]
              asm.label("rt_paint_clear")
              asm.jsr(asm.abs("rt_paint_take_area"))
              asm.lda(asm.direct(s.area_left))
              asm.ora(asm.direct(s.area_top))
              asm.bne("rt_paint_clear_area")
              asm.lda(asm.direct(s.area_right))
              asm.cmp(WIDTH)
              asm.bne("rt_paint_clear_area")
              asm.lda(asm.direct(s.area_bottom))
              asm.cmp(HEIGHT)
              asm.beq("rt_paint_clear_whole")
              asm.label("rt_paint_clear_area")
              asm.lda(asm.direct(R.call(0)))
              asm.sta(asm.direct(R.call(4)))
              [[s.area_left, nil, R.call(0)], [s.area_top, nil, R.call(1)],
               [s.area_right, s.area_left, R.call(2)], [s.area_bottom, s.area_top, R.call(3)]].each do |from, less, out|
                asm.lda(asm.direct(from))
                if less
                  asm.sec
                  asm.sbc(asm.direct(less))
                end
                asm.sta(asm.direct(out))
                asm.stz(asm.direct(out + 2))
              end
              asm.brl("rt_paint_fill")

              # The whole screen: on a Super FX cartridge, painted by the chip (ChipPaint); on a plain
              # one, each row of tiles copied from the cartridge into the copy through the work RAM
              # port, which moves on by itself.
              asm.label("rt_paint_clear_whole")
              if chip
                ChipPaint.emit_clear_whole(asm)
              else
                asm.lda(asm.direct(R.call(1)))
                asm.asl
                asm.asl
                asm.tax
                asm.lda(asm.long_x("paint clear rows"))
                asm.sta(asm.direct(s.pointer))
                asm.lda(asm.long_x("paint clear rows", 2))
                asm.sta(asm.direct(s.pointer + 2))
                asm.sep(0x20)
                asm.stz(asm.abs(h::WMADDL))
                asm.stz(asm.abs(h::WMADDL + 1))
                asm.lda(COPY_IN_WORK_RAM >> 16)
                asm.sta(asm.abs(h::WMADDL + 2))
                asm.rep(0x20)
                asm.ldx(ROWS)
                asm.label("rt_paint_clear_row")
                asm.phx
                asm.lda(COLUMNS * TILE_BYTES)
                asm.sta(asm.abs(h::DMA_BASE + h::DASL))
                asm.lda(asm.direct(s.pointer))
                asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
                asm.sep(0x20)
                asm.lda(asm.direct(s.pointer + 2))
                asm.sta(asm.abs(h::DMA_BASE + h::A1B))
                asm.lda(h::DMA_TO_ONE_PORT)
                asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
                asm.lda(h::WMDATA & 0xFF)
                asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
                asm.lda(1)
                asm.sta(asm.abs(h::MDMAEN))
                asm.rep(0x20)
                asm.plx
                asm.dex
                asm.bne("rt_paint_clear_row")
              end
              # Every tile changed.
              asm.ldx(0)
              asm.label("rt_paint_clear_mark")
              asm.stz(asm.abs_x(dirty))
              asm.lda(COLUMNS - 1)
              asm.sta(asm.abs_x(dirty + 2))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.cpx(ROWS * 4)
              asm.bne("rt_paint_clear_mark")
              asm.rtl
            end

            # --- rectangles ---

            # rt_paint_fill(x, y, w, h, place): the rectangle, as far as it is inside the area, in
            # the colour at +place+. Each row of it is a tile's row at the left edge (some of its
            # pixels), the tiles' rows between (all eight), and a tile's row at the right edge.
            def emit_fill(asm, memory, s, bank)
              asm.label("rt_paint_fill")
              asm.jsr(asm.abs("rt_paint_take_area"))
              [[R.call(0), R.call(2), R.call(5)], [R.call(1), R.call(3), R.call(6)]].each do |at, size, out|
                asm.clc
                asm.lda(asm.direct(at))
                asm.adc(asm.direct(size))
                asm.sta(asm.direct(out))
                asm.lda(asm.direct(at + 2))
                asm.adc(asm.direct(size + 2))
                asm.sta(asm.direct(out + 2))
              end
              emit_clamp(asm, "fill", R.call(0), s.area_left, s.area_right, s.left)
              emit_clamp(asm, "fill", R.call(5), s.area_left, s.area_right, s.right)
              emit_clamp(asm, "fill", R.call(1), s.area_top, s.area_bottom, s.top)
              emit_clamp(asm, "fill", R.call(6), s.area_top, s.area_bottom, s.bottom)
              asm.lda(asm.direct(s.left))
              asm.cmp(asm.direct(s.right))
              asm.branch_long(:bcs, "rt_paint_fill_none")
              asm.lda(asm.direct(s.top))
              asm.cmp(asm.direct(s.bottom))
              asm.bcc("rt_paint_fill_some")
              asm.label("rt_paint_fill_none")
              asm.rtl
              asm.label("rt_paint_fill_some")
              # The colour's place as four words, a pair of planes each: $FF in a byte for a bit set.
              4.times do |pair|
                asm.stz(asm.direct(s.planes + (pair * 2)))
                2.times do |half|
                  skip = "rt_paint_fill_plane_#{pair}_#{half}"
                  asm.lda(asm.direct(R.call(4)))
                  asm.and_a(1 << ((pair * 2) + half))
                  asm.beq(skip)
                  asm.lda(half.zero? ? 0x00FF : 0xFF00)
                  asm.tsb(asm.direct(s.planes + (pair * 2)))
                  asm.label(skip)
                end
              end
              # The tiles across: the first and the last, and the pixels of each edge.
              asm.lda(asm.direct(s.left))
              3.times { asm.lsr }
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.direct(s.right))
              asm.dec
              3.times { asm.lsr }
              asm.sta(asm.direct(s.last))
              asm.lda(asm.direct(s.chunk))
              3.times { asm.asl }
              asm.jsr(asm.abs("rt_paint_column_mask"))
              emit_masked_planes(asm, s, s.left_planes)
              asm.lda(asm.direct(s.last))
              3.times { asm.asl }
              asm.jsr(asm.abs("rt_paint_column_mask"))
              emit_masked_planes(asm, s, s.right_planes)
              asm.jsr(asm.abs("rt_paint_mark"))
              emit_into_copy(asm, bank)
              asm.lda(asm.direct(s.top))
              asm.sta(asm.direct(s.y))
              asm.label("rt_paint_fill_row")
              asm.jsr(asm.abs("rt_paint_row_start"))
              asm.lda(asm.direct(s.chunk))
              6.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.tax
              asm.jsr(asm.abs("rt_paint_fill_left"))
              asm.lda(asm.direct(s.last))
              asm.sec
              asm.sbc(asm.direct(s.chunk))
              asm.beq("rt_paint_fill_row_done")
              asm.dec
              asm.sta(asm.direct(s.count))
              asm.beq("rt_paint_fill_right")
              asm.label("rt_paint_fill_middle")
              asm.txa
              asm.clc
              asm.adc(TILE_BYTES)
              asm.tax
              4.times do |pair|
                asm.lda(asm.direct(s.planes + (pair * 2)))
                asm.sta(asm.abs_x(pair * 16))
              end
              asm.dec(asm.direct(s.count))
              asm.bne("rt_paint_fill_middle")
              asm.label("rt_paint_fill_right")
              asm.txa
              asm.clc
              asm.adc(TILE_BYTES)
              asm.tax
              asm.jsr(asm.abs("rt_paint_fill_right_tile"))
              asm.label("rt_paint_fill_row_done")
              asm.inc(asm.direct(s.y))
              asm.lda(asm.direct(s.y))
              asm.cmp(asm.direct(s.bottom))
              asm.branch_long(:bcc, "rt_paint_fill_row")
              asm.plb
              asm.rtl

              # One tile's row at X, through a mask's planes (+planes+: the mask's opposite, then the
              # four pairs of planes held to the mask).
              [["rt_paint_fill_left", s.left_planes], ["rt_paint_fill_right_tile", s.right_planes]].each do |label, planes|
                asm.label(label)
                4.times do |pair|
                  asm.lda(asm.abs_x(pair * 16))
                  asm.and_a(asm.direct(planes))
                  asm.ora(asm.direct(planes + 2 + (pair * 2)))
                  asm.sta(asm.abs_x(pair * 16))
                end
                asm.rts
              end
            end

            # The mask in A (in both bytes) made into +out+: its opposite, then the four pairs of the
            # colour's planes held to it.
            def emit_masked_planes(asm, s, out)
              asm.sta(asm.direct(s.mask))
              asm.eor(0xFFFF)
              asm.sta(asm.direct(out))
              4.times do |pair|
                asm.lda(asm.direct(s.planes + (pair * 2)))
                asm.and_a(asm.direct(s.mask))
                asm.sta(asm.direct(out + 2 + (pair * 2)))
              end
            end

            # The data bank switched to the copy's, +bank+, the one it was kept on the stack: from here an
            # address of 16 bits is a byte of the copy. The direct page is in bank 0 whatever the data
            # bank, so the routines' numbers are where they were.
            def emit_into_copy(asm, bank)
              asm.phb
              asm.sep(0x20)
              asm.lda(bank)
              asm.pha
              asm.plb
              asm.rep(0x20)
            end

            # --- pictures ---

            # rt_paint_blit_one_of(list, which, x, y): the picture numbered +which+ in the list of
            # pictures numbered +list+ (the table "paint picture lists": each a count, then the
            # pictures' numbers), or none for a number outside it. rt_paint_blit(picture, x, y).
            #
            # A picture placed more than 2048 pixels off the screen's left or top, or past its right
            # or bottom, paints nothing, so everything below works in 16 bits; no picture is that big.
            def emit_blit(asm, memory, s, bank)
              asm.label("rt_paint_blit_one_of")
              asm.lda(asm.direct(R.call(0)))
              asm.asl
              asm.asl
              asm.tax
              asm.lda(asm.long_x("paint picture lists"))
              asm.sta(asm.direct(s.pointer))
              asm.lda(asm.long_x("paint picture lists", 2))
              asm.sta(asm.direct(s.pointer + 2))
              asm.lda(asm.direct(R.call(1) + 2))
              asm.branch_long(:bne, "rt_paint_blit_none")
              asm.lda(asm.direct(R.call(1)))
              asm.cmp(asm.ind_long(s.pointer))
              asm.branch_long(:bcs, "rt_paint_blit_none")
              asm.inc
              asm.asl
              asm.tay
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.direct(R.call(0)))
              [[2, 1], [3, 2]].each do |from, to|
                asm.lda(asm.direct(R.call(from)))
                asm.sta(asm.direct(R.call(to)))
                asm.lda(asm.direct(R.call(from) + 2))
                asm.sta(asm.direct(R.call(to) + 2))
              end

              asm.label("rt_paint_blit")
              # Near enough the screen to paint anything at all.
              [[R.call(1), WIDTH], [R.call(2), HEIGHT]].each do |at, edge|
                asm.clc
                asm.lda(asm.direct(at))
                asm.adc(2048)
                asm.tax
                asm.lda(asm.direct(at + 2))
                asm.adc(0)
                asm.branch_long(:bne, "rt_paint_blit_none")
                asm.cpx(2048 + edge)
                asm.branch_long(:bcs, "rt_paint_blit_none")
              end
              # The picture: where its rows' places are, its bytes across and its height.
              asm.lda(asm.direct(R.call(0)))
              3.times { asm.asl }
              asm.tax
              asm.lda(asm.long_x("paint pictures"))
              asm.sta(asm.direct(s.pointer))
              asm.lda(asm.long_x("paint pictures", 2))
              asm.sta(asm.direct(s.pointer + 2))
              asm.lda(asm.long_x("paint pictures", 4))
              asm.sta(asm.direct(s.across))
              asm.lda(asm.long_x("paint pictures", 6))
              asm.sta(asm.direct(s.height))
              asm.jsr(asm.abs("rt_paint_take_area"))
              # The rows painted: the picture's, inside the area.
              asm.lda(asm.direct(R.call(2)))
              asm.bmi("rt_paint_blit_top_area")
              asm.cmp(asm.direct(s.area_top))
              asm.bcs("rt_paint_blit_top")
              asm.label("rt_paint_blit_top_area")
              asm.lda(asm.direct(s.area_top))
              asm.label("rt_paint_blit_top")
              asm.sta(asm.direct(s.top))
              asm.lda(asm.direct(R.call(2)))
              asm.clc
              asm.adc(asm.direct(s.height))
              asm.branch_long(:bmi, "rt_paint_blit_none")
              asm.cmp(asm.direct(s.area_bottom))
              asm.bcc("rt_paint_blit_bottom")
              asm.lda(asm.direct(s.area_bottom))
              asm.label("rt_paint_blit_bottom")
              asm.sta(asm.direct(s.bottom))
              asm.cmp(asm.direct(s.top))
              asm.branch_long(:beq, "rt_paint_blit_none")
              asm.bcs("rt_paint_blit_some")
              asm.label("rt_paint_blit_none")
              asm.rtl
              asm.label("rt_paint_blit_some")
              # The tiles across: the picture's first, at its place across divided by eight (rounded
              # down, so -3 is the tile left of the screen), and one for each byte across, held to the
              # area's.
              asm.lda(asm.direct(R.call(1)))
              asm.and_a(7)
              asm.asl
              asm.tax
              asm.lda(asm.long_x("rt_paint_shifts"))
              asm.sta(asm.direct(s.shift))
              asm.lda(asm.direct(R.call(1)))
              3.times do
                asm.cmp(0x8000)
                asm.ror
              end
              asm.sta(asm.direct(s.first_x))
              asm.clc
              asm.adc(asm.direct(s.across))
              asm.sec
              asm.sbc(2) # past the last: the bytes across and one, from the first
              asm.sta(asm.direct(s.last))
              asm.lda(asm.direct(s.area_right))
              asm.dec
              3.times { asm.lsr }
              asm.cmp(asm.direct(s.last))
              asm.bpl("rt_paint_blit_last")
              asm.sta(asm.direct(s.last))
              asm.label("rt_paint_blit_last")
              asm.lda(asm.direct(s.area_left))
              3.times { asm.lsr }
              asm.cmp(asm.direct(s.first_x))
              asm.bpl("rt_paint_blit_first")
              asm.lda(asm.direct(s.first_x))
              asm.label("rt_paint_blit_first")
              asm.sta(asm.direct(s.chunk))
              asm.cmp(asm.direct(s.last))
              asm.beq("rt_paint_blit_across")
              asm.branch_long(:bpl, "rt_paint_blit_none")
              asm.label("rt_paint_blit_across")
              [[s.area_left, s.left], [s.area_right, s.right]].each do |from, to|
                asm.lda(asm.direct(from))
                asm.sta(asm.direct(to))
              end
              asm.jsr(asm.abs("rt_paint_mark"))
              emit_into_copy(asm, bank)
              asm.lda(asm.direct(s.top))
              asm.sta(asm.direct(s.y))
              asm.label("rt_paint_blit_row")
              # The row of the picture: its place, from the picture's table of rows.
              asm.lda(asm.direct(s.y))
              asm.sec
              asm.sbc(asm.direct(R.call(2)))
              asm.asl
              asm.asl
              asm.tay
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.direct(s.temp))
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.direct(s.temp + 2))
              asm.jsr(asm.abs("rt_paint_row_start"))
              asm.lda(asm.direct(s.chunk))
              asm.sta(asm.direct(s.count))
              asm.label("rt_paint_blit_tile")
              # The tile's eight pixels the area allows, and of them the ones the picture draws.
              asm.lda(asm.direct(s.count))
              3.times { asm.asl }
              asm.jsr(asm.abs("rt_paint_column_mask"))
              asm.sta(asm.direct(s.not_mask))
              # Its byte of the picture: the bytes across, less two, less how far this tile is from
              # the picture's first, into each row of bytes (see SNES::PaintedArt).
              asm.lda(asm.direct(s.across))
              asm.sec
              asm.sbc(2)
              asm.clc
              asm.adc(asm.direct(s.first_x))
              asm.sec
              asm.sbc(asm.direct(s.count))
              asm.tay
              asm.lda(asm.ind_long_y(s.temp))
              asm.jsr(asm.abs("rt_paint_shift"))
              asm.and_a(asm.direct(s.not_mask))
              asm.and_a(0x00FF)
              asm.branch_long(:beq, "rt_paint_blit_next_tile")
              asm.sta(asm.direct(s.mask))
              asm.eor(0x00FF)
              asm.sta(asm.direct(s.not_mask))
              asm.lda(asm.direct(s.count))
              6.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.tax
              8.times do |plane|
                at = ((plane / 2) * 16) + (plane % 2)
                asm.tya
                asm.clc
                asm.adc(asm.direct(s.across))
                asm.tay
                asm.lda(asm.ind_long_y(s.temp))
                asm.jsr(asm.abs("rt_paint_shift"))
                asm.and_a(asm.direct(s.mask))
                asm.sta(asm.direct(s.left_planes))
                asm.sep(0x20)
                asm.lda(asm.abs_x(at))
                asm.and_a(asm.direct(s.not_mask))
                asm.ora(asm.direct(s.left_planes))
                asm.sta(asm.abs_x(at))
                asm.rep(0x20)
              end
              asm.label("rt_paint_blit_next_tile")
              asm.lda(asm.direct(s.count))
              asm.cmp(asm.direct(s.last))
              asm.beq("rt_paint_blit_row_done")
              asm.inc(asm.direct(s.count))
              asm.brl("rt_paint_blit_tile")
              asm.label("rt_paint_blit_row_done")
              asm.inc(asm.direct(s.y))
              asm.lda(asm.direct(s.y))
              asm.cmp(asm.direct(s.bottom))
              asm.bcs("rt_paint_blit_done")
              asm.brl("rt_paint_blit_row")
              asm.label("rt_paint_blit_done")
              asm.plb
              asm.rtl

              # rt_paint_shift (JSR): A shifted right by the picture's place across, modulo eight —
              # straight into the run of shifts at the place for that many (rt_paint_shifts).
              asm.label("rt_paint_shift")
              asm.jmp(asm.ind_abs(s.shift))
              asm.label("rt_paint_shift_7")
              7.downto(1) do |n|
                asm.label("rt_paint_shift_#{n}") unless n == 7
                asm.lsr
              end
              asm.label("rt_paint_shift_0")
              asm.rts
            end

            # --- a sprite's patch ---

            # rt_paint_save(buffer, x, y, w, h): the patch of the screen at (x, y), w by h, kept at
            # +buffer+ (24 bits; Lowering::Paint sizes it, #patch_bytes): a word saying it was kept,
            # then for each row of the patch each tile's row it touches, eight bytes. A row or a tile
            # off the screen is not kept, and is off the screen again when the patch is put back.
            # rt_paint_restore(buffer, x, y, w, h): the patch put back at the place it was kept from,
            # inside the area, its own pixels alone — nothing if none was kept.
            def emit_patches(asm, memory, s, bank)
              asm.label("rt_paint_save")
              asm.jsr(asm.abs("rt_paint_patch_start"))
              asm.branch_long(:bcc, "rt_paint_save_some")
              asm.rtl
              asm.label("rt_paint_save_some")
              asm.lda(1)
              asm.sta(asm.ind_long(s.pointer))
              emit_into_copy(asm, bank)
              asm.ldy(2)
              asm.label("rt_paint_save_row")
              asm.lda(asm.direct(s.y))
              asm.cmp(HEIGHT) # nought to the screen's height, unsigned
              asm.branch_long(:bcs, "rt_paint_save_row_off")
              asm.jsr(asm.abs("rt_paint_row_start"))
              asm.lda(asm.direct(s.first_x))
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.direct(s.across))
              asm.sta(asm.direct(s.count))
              asm.label("rt_paint_save_tile")
              asm.lda(asm.direct(s.chunk))
              asm.cmp(COLUMNS)
              asm.branch_long(:bcs, "rt_paint_save_tile_off")
              6.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.tax
              4.times do |pair|
                asm.lda(asm.abs_x(pair * 16))
                asm.sta(asm.ind_long_y(s.pointer))
                asm.iny
                asm.iny
              end
              asm.bra("rt_paint_save_tile_next")
              asm.label("rt_paint_save_tile_off")
              4.times do
                asm.iny
                asm.iny
              end
              asm.label("rt_paint_save_tile_next")
              asm.inc(asm.direct(s.chunk))
              asm.dec(asm.direct(s.count))
              asm.branch_long(:bne, "rt_paint_save_tile")
              asm.bra("rt_paint_save_row_next")
              asm.label("rt_paint_save_row_off")
              asm.tya
              asm.clc
              asm.adc(asm.direct(s.temp + 2)) # a row of the patch's bytes
              asm.tay
              asm.label("rt_paint_save_row_next")
              asm.inc(asm.direct(s.y))
              asm.dec(asm.direct(s.height))
              asm.branch_long(:bne, "rt_paint_save_row")
              asm.plb
              asm.rtl

              asm.label("rt_paint_restore")
              asm.jsr(asm.abs("rt_paint_patch_start"))
              asm.branch_long(:bcc, "rt_paint_restore_kept")
              asm.label("rt_paint_restore_none")
              asm.rtl
              asm.label("rt_paint_restore_kept")
              asm.lda(asm.ind_long(s.pointer))
              asm.branch_long(:beq, "rt_paint_restore_none")
              # The columns put back: the patch's, inside the area.
              asm.jsr(asm.abs("rt_paint_take_area"))
              asm.lda(asm.direct(R.call(1)))
              asm.branch_long(:bmi, "rt_paint_restore_left_area")
              asm.cmp(asm.direct(s.area_left))
              asm.branch_long(:bcs, "rt_paint_restore_left")
              asm.label("rt_paint_restore_left_area")
              asm.lda(asm.direct(s.area_left))
              asm.label("rt_paint_restore_left")
              asm.sta(asm.direct(s.left))
              asm.lda(asm.direct(R.call(1)))
              asm.clc
              asm.adc(asm.direct(R.call(3)))
              asm.branch_long(:bmi, "rt_paint_restore_none")
              asm.cmp(asm.direct(s.area_right))
              asm.branch_long(:bcc, "rt_paint_restore_right")
              asm.lda(asm.direct(s.area_right))
              asm.label("rt_paint_restore_right")
              asm.sta(asm.direct(s.right))
              # The rows: every one of the patch's inside the area, said changed with the tiles.
              asm.lda(asm.direct(R.call(2)))
              asm.branch_long(:bmi, "rt_paint_restore_top_area")
              asm.cmp(asm.direct(s.area_top))
              asm.branch_long(:bcs, "rt_paint_restore_top")
              asm.label("rt_paint_restore_top_area")
              asm.lda(asm.direct(s.area_top))
              asm.label("rt_paint_restore_top")
              asm.sta(asm.direct(s.top))
              asm.lda(asm.direct(R.call(2)))
              asm.clc
              asm.adc(asm.direct(s.height))
              asm.branch_long(:bmi, "rt_paint_restore_none")
              asm.cmp(asm.direct(s.area_bottom))
              asm.branch_long(:bcc, "rt_paint_restore_bottom")
              asm.lda(asm.direct(s.area_bottom))
              asm.label("rt_paint_restore_bottom")
              asm.sta(asm.direct(s.bottom))
              asm.cmp(asm.direct(s.top))
              asm.branch_long(:beq, "rt_paint_restore_none")
              asm.branch_long(:bcc, "rt_paint_restore_none")
              asm.lda(asm.direct(s.left))
              asm.cmp(asm.direct(s.right))
              asm.branch_long(:bcs, "rt_paint_restore_none")
              asm.lda(asm.direct(s.first_x))
              asm.pha
              asm.lda(asm.direct(s.left))
              3.times { asm.lsr }
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.direct(s.right))
              asm.dec
              3.times { asm.lsr }
              asm.sta(asm.direct(s.last))
              asm.jsr(asm.abs("rt_paint_mark"))
              asm.pla
              asm.sta(asm.direct(s.first_x))
              emit_into_copy(asm, bank)
              # Each row of the patch, from its first; the ones outside the area are passed over.
              asm.ldy(2)
              asm.label("rt_paint_restore_row")
              asm.lda(asm.direct(s.y))
              asm.cmp(asm.direct(s.top))
              asm.branch_long(:bmi, "rt_paint_restore_row_off")
              asm.cmp(asm.direct(s.bottom))
              asm.branch_long(:bpl, "rt_paint_restore_row_off")
              asm.jsr(asm.abs("rt_paint_row_start"))
              asm.lda(asm.direct(s.first_x))
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.direct(s.across))
              asm.sta(asm.direct(s.count))
              asm.label("rt_paint_restore_tile")
              asm.lda(asm.direct(s.chunk))
              asm.cmp(COLUMNS)
              asm.branch_long(:bcs, "rt_paint_restore_tile_off")
              3.times { asm.asl }
              asm.phy
              asm.jsr(asm.abs("rt_paint_column_mask"))
              asm.ply
              asm.sta(asm.direct(s.mask))
              asm.eor(0xFFFF)
              asm.sta(asm.direct(s.not_mask))
              asm.lda(asm.direct(s.chunk))
              6.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.tax
              4.times do |pair|
                asm.lda(asm.ind_long_y(s.pointer))
                asm.and_a(asm.direct(s.mask))
                asm.sta(asm.direct(s.left_planes))
                asm.lda(asm.abs_x(pair * 16))
                asm.and_a(asm.direct(s.not_mask))
                asm.ora(asm.direct(s.left_planes))
                asm.sta(asm.abs_x(pair * 16))
                asm.iny
                asm.iny
              end
              asm.bra("rt_paint_restore_tile_next")
              asm.label("rt_paint_restore_tile_off")
              4.times do
                asm.iny
                asm.iny
              end
              asm.label("rt_paint_restore_tile_next")
              asm.inc(asm.direct(s.chunk))
              asm.dec(asm.direct(s.count))
              asm.branch_long(:bne, "rt_paint_restore_tile")
              asm.bra("rt_paint_restore_row_next")
              asm.label("rt_paint_restore_row_off")
              asm.tya
              asm.clc
              asm.adc(asm.direct(s.temp + 2))
              asm.tay
              asm.label("rt_paint_restore_row_next")
              asm.inc(asm.direct(s.y))
              asm.dec(asm.direct(s.height))
              asm.branch_long(:bne, "rt_paint_restore_row")
              asm.plb
              asm.rtl

              # rt_paint_patch_start (JSR): the buffer's place, and the patch's first row, its height,
              # its first tile across and how many tiles across it touches (+first_x+, +across+), and
              # the bytes of a row of it; the carry set for a patch too far off the screen to touch it.
              asm.label("rt_paint_patch_start")
              asm.lda(asm.direct(R.call(0)))
              asm.sta(asm.direct(s.pointer))
              asm.lda(asm.direct(R.call(0) + 2))
              asm.sta(asm.direct(s.pointer + 2))
              [[R.call(1), WIDTH], [R.call(2), HEIGHT]].each do |at, edge|
                asm.clc
                asm.lda(asm.direct(at))
                asm.adc(2048)
                asm.tax
                asm.lda(asm.direct(at + 2))
                asm.adc(0)
                asm.bne("rt_paint_patch_far")
                asm.cpx(2048 + edge)
                asm.bcs("rt_paint_patch_far")
              end
              asm.lda(asm.direct(R.call(2)))
              asm.sta(asm.direct(s.y))
              asm.lda(asm.direct(R.call(4)))
              asm.sta(asm.direct(s.height))
              asm.beq("rt_paint_patch_far")
              asm.lda(asm.direct(R.call(1)))
              3.times do
                asm.cmp(0x8000)
                asm.ror
              end
              asm.sta(asm.direct(s.first_x))
              asm.lda(asm.direct(R.call(1)))
              asm.clc
              asm.adc(asm.direct(R.call(3)))
              asm.dec
              3.times do
                asm.cmp(0x8000)
                asm.ror
              end
              asm.sec
              asm.sbc(asm.direct(s.first_x))
              asm.inc
              asm.sta(asm.direct(s.across))
              3.times { asm.asl } # ... × 8 bytes: a row of the patch
              asm.sta(asm.direct(s.temp + 2))
              asm.clc
              asm.rts
              asm.label("rt_paint_patch_far")
              asm.sec
              asm.rts
            end

            # The bytes a patch of +width+ by +height+ keeps: the word saying it was kept, and eight
            # bytes for each tile's row it can touch, wherever it is placed across.
            def patch_bytes(width, height) = 2 + (height * (((width + 7) / 8) + 1) * 8)

            # --- the blank ---

            # rt_paint_upload (JSR, in the blank with the screen off): each row of tiles changed, the
            # stretch from its leftmost changed tile to its rightmost, copied to video RAM.
            def emit_upload(asm, memory, s)
              h = Console::SNESHardware
              dirty = memory[DIRTY]
              asm.label("rt_paint_upload")
              asm.ldx(0)
              asm.stz(asm.direct(s.row)) # the row's first tile
              asm.label("rt_paint_upload_row")
              asm.lda(asm.abs_x(dirty + 2))
              asm.cmp(asm.abs_x(dirty))
              asm.bcc("rt_paint_upload_next")
              asm.sec
              asm.sbc(asm.abs_x(dirty))
              asm.inc
              6.times { asm.asl }
              asm.sta(asm.abs(h::DMA_BASE + h::DASL))
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
              asm.lda(NONE_LEFT)
              asm.sta(asm.abs_x(dirty))
              asm.stz(asm.abs_x(dirty + 2))
              asm.label("rt_paint_upload_next")
              asm.lda(asm.direct(s.row))
              asm.clc
              asm.adc(COLUMNS)
              asm.sta(asm.direct(s.row))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.cpx(ROWS * 4)
              asm.bne("rt_paint_upload_row")
              asm.rts
            end

            # The masks of a tile's row from a pixel to its right end (rt_paint_from_left, nine: from
            # pixel 0 to past pixel 7) and from its left end up to a pixel (rt_paint_up_to, nine), and
            # where in the run of shifts each place across modulo eight starts.
            def emit_tables(asm)
              asm.label("rt_paint_from_left")
              asm.data_words(*(0..8).map { |from| (0xFF >> from) * 0x0101 })
              asm.label("rt_paint_up_to")
              asm.data_words(*(0..8).map { |to| ((0xFF00 >> to) & 0xFF) * 0x0101 })
              asm.label("rt_paint_shifts")
              asm.data_words(*(0..7).map { |n| "rt_paint_shift_#{n}" })
            end
          end
        end
      end
    end
  end
end
