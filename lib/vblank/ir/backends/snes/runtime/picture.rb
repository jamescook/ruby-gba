# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE PICTURE: the backgrounds and the sprites, set up at power-on and copied to the
          # console in the vertical blank after each pass.
          #
          # WHAT THE CONSOLE IS TOLD TO DRAW. Mode 1 (BGMODE): two background layers of sixteen-colour
          # tiles (BG1 in front of BG2) and a third of four-colour tiles the build does not use, and
          # 128 sprites over all of them. Video RAM, 32K words, is laid out once:
          #
          #   $0000-$3FFF  the backgrounds' tiles, 1024 of them (16 words each)
          #   $4000-$4FFF  BG1's map, up to 64×64 cells (a word each)
          #   $5000-$5FFF  BG2's map
          #   $6000-$7FFF  the sprites' tiles, 512 of them
          #
          # WHAT THE GAME CHANGES IS KEPT IN WORK RAM and copied in the blank (rt_upload): the
          # sprite table, written whole every pass a game places its sprites (a shadow of the
          # console's 544 bytes); a map put up, copied whole from the cartridge; single cells
          # changed (a queue of them); and where each layer is scrolled to. The console takes video
          # RAM and the sprite table only while it is not drawing, so this is all done in the blank
          # with the screen switched off for the copy, so the console takes the writes however long
          # the copy runs. A copy that ends inside the blank switches the screen on again there and
          # nothing shows; one too long for the blank (a map of 64×64 cells is 8K) runs on into the
          # frame and switches the screen on in the next blank, before the pass is said to be shown
          # (Runtime::Frame's SHOWN). The frame drawn while it was off is black, and nothing reads it.
          #
          #   rt_picture_start     at power-on: the registers, the tiles and the colours
          #   rt_picture_prepare   at the end of every pass, before the wait (nothing yet)
          #   rt_upload_whole      the first pass, with the screen still off
          #   rt_upload            what the pass changed, in the blank
          #   rt_sprites_begin     every sprite hidden, ready for a pass's sprites
          #   rt_sprite_place      one sprite placed: its pieces into the sprite table
          #   rt_background_put_up   a map onto a layer, from its corner (or keeping its scroll)
          #   rt_background_scroll   where a layer's view sits
          #   rt_set_cell          one cell of a layer's map changed
          module Picture
            BG_TILES = 0x0000
            LAYER_MAPS = [0x4000, 0x5000].freeze
            SPRITE_TILES = 0x6000

            # The sprite table's shadow (544 bytes: 128 rows of four, then 32 bytes of each row's two
            # top bits), and the sprites the game placed in its last pass, for a reader: how many,
            # then for each, whose (SpriteNames's number), which picture, and where.
            SHADOW_OAM = "rt shadow oam"
            DRAWN = "rt drawn"
            DRAWN_BYTES = 8
            MOST_SPRITES = 128
            # The next row of the sprite table to write, counting down: the back-most sprite is
            # placed first, in the last row, since the console draws a lower row in front.
            NEXT_ROW = "rt next row"
            # Each layer's state: where the map to copy is (three bytes and a spare), how many bytes,
            # whether a copy is waiting, its map register, its grid's columns, and its scroll.
            LAYERS = "rt layers"
            LAYER_SOURCE = 0
            LAYER_BYTES = 4
            LAYER_PENDING = 6
            LAYER_SC = 8
            LAYER_COLUMNS = 10
            LAYER_SCROLL_X = 12
            LAYER_SCROLL_Y = 14
            LAYER_STATE_BYTES = 16
            # Cells changed since the last blank: how many, then each its video RAM address and word.
            CELLS = "rt cells"
            MOST_CELLS = 256

            # A sprite hidden: below the screen, where none of its eight rows shows.
            HIDDEN_Y = 224

            module_function

            def reserve(memory)
              memory.reserve_far(SHADOW_OAM, 544)
              memory.reserve_far(DRAWN, 2 + (MOST_SPRITES * DRAWN_BYTES))
              memory.reserve(NEXT_ROW, 2)
              memory.reserve(LAYERS, LAYER_MAPS.length * LAYER_STATE_BYTES)
              memory.reserve(CELLS, 2 + (MOST_CELLS * 4))
            end

            # +work+ is four words of the direct page the routines use.
            def emit(asm, memory, work:)
              emit_start(asm, memory)
              emit_sprites(asm, memory, work)
              emit_backgrounds(asm, memory, work)
              emit_upload(asm, memory)
              asm.label("rt_picture_prepare")
              asm.rtl
            end

            # The registers, then the tiles and the colours copied in while the screen is off.
            def emit_start(asm, memory)
              h = Console::SNESHardware
              asm.label("rt_picture_start")
              asm.sep(0x20)
              asm.lda(0x01) # mode 1, every tile 8×8
              asm.sta(asm.abs(h::BGMODE))
              asm.stz(asm.abs(h::BG12NBA)) # both layers' tiles at $0000
              asm.lda(SPRITE_TILES >> 13) # sprites' tiles at $6000, the next 256 straight after; 8×8 and 16×16
              asm.sta(asm.abs(h::OBSEL))
              LAYER_MAPS.each_with_index do |at, layer|
                asm.lda((at >> 10) << 2)
                asm.sta(asm.abs(h::BG1SC + layer))
              end
              asm.lda(0x13) # BG1, BG2 and the sprites on the main screen
              asm.sta(asm.abs(h::TM))
              asm.rep(0x20)
              emit_dma_to_vram(asm, BG_TILES, "art background tiles", "art background tiles bytes")
              emit_dma_to_vram(asm, SPRITE_TILES, "art sprite tiles", "art sprite tiles bytes")
              # The colours: 256 of them, from colour 0.
              asm.sep(0x20)
              asm.stz(asm.abs(h::CGADD))
              asm.rep(0x20)
              emit_dma(asm, h::DMA_TO_ONE_PORT, h::CGDATA, asm.imm("art colors"), asm.bank_of("art colors"), 512)
              asm.jsl(asm.long("rt_sprites_begin"))
              asm.rtl
            end

            # A scroll register written with the 16-bit number in A: its low byte, then its high.
            def emit_scroll_register(asm, register)
              asm.sep(0x20)
              asm.sta(asm.abs(register))
              asm.xba
              asm.sta(asm.abs(register))
              asm.rep(0x20)
            end

            # Channel 0 copying from the cartridge to video RAM at +word_address+: +label+'s bytes,
            # as many as the word at +count_label+ says (none for nought).
            def emit_dma_to_vram(asm, word_address, label, count_label)
              h = Console::SNESHardware
              skip = "#{label} none"
              asm.lda(asm.long(count_label))
              asm.beq(skip)
              asm.tax
              asm.lda(word_address)
              asm.sta(asm.abs(h::VMADDL))
              asm.txa
              emit_dma(asm, h::DMA_TO_TWO_PORTS, h::VMDATAL, asm.imm(label), asm.bank_of(label), nil)
              asm.label(skip)
            end

            # Channel 0 copying to the picture chip's port +port+ in +mode+, from +source+ (an
            # immediate operand for the low 16 bits) in bank +bank+ (an immediate operand), +count+
            # bytes — or as many as A holds, for nil.
            def emit_dma(asm, mode, port, source, bank, count)
              h = Console::SNESHardware
              asm.sta(asm.abs(h::DMA_BASE + h::DASL)) if count.nil?
              unless count.nil?
                asm.lda(count)
                asm.sta(asm.abs(h::DMA_BASE + h::DASL))
              end
              asm.lda(source)
              asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
              asm.sep(0x20)
              asm.lda(bank)
              asm.sta(asm.abs(h::DMA_BASE + h::A1B))
              asm.lda(mode)
              asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
              asm.lda(port & 0xFF)
              asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
              asm.lda(1)
              asm.sta(asm.abs(h::MDMAEN))
              asm.rep(0x20)
            end

            # SPRITES. rt_sprites_begin hides every row of the sprite table and forgets the sprites
            # of the last pass. rt_sprite_place(poses, pose, x, y, whose) places one: +poses+ is the
            # 24-bit place of the sprite's table of pictures (how many, then each picture's number),
            # +pose+ which of them it shows — none for a number outside the table — and +whose+ the
            # sprite's number for a reader (SpriteNames). Each piece of the picture is a row of the
            # table, at the sprite's place plus the piece's own; a piece wholly off the screen is not
            # written, and nor is any piece once the table's 128 rows are used.
            #
            # A ROW'S PLACE ON THE SCREEN is nine bits across and eight down, and both come round: a
            # piece at -3 across is kept as 509, which the console draws three columns off the left
            # edge, and one at -3 down as 253, which it draws with its top three rows above the
            # screen. So a piece that reaches the screen is written as its place's low bits, and one
            # that does not is not written at all, where coming round would show it somewhere else.
            def emit_sprites(asm, memory, work)
              r = ->(n) { Memory.register(n) }
              oam = memory[SHADOW_OAM]
              drawn = memory[DRAWN]
              pointer = work # the picture's pieces, three bytes and a spare
              piece_x = work + 4
              piece_y = work + 6

              asm.label("rt_sprites_begin")
              asm.ldx(0)
              asm.label("rt_sprites_begin_row")
              asm.lda(HIDDEN_Y << 8)
              asm.sta(asm.long_x(oam)) # x 0, y below the screen
              asm.lda(0)
              asm.sta(asm.long_x(oam, 2))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.cpx(512)
              asm.bne("rt_sprites_begin_row")
              asm.label("rt_sprites_begin_top_bits")
              asm.sta(asm.long_x(oam)) # A is nought: no row's top bits set
              asm.inx
              asm.inx
              asm.cpx(544)
              asm.bne("rt_sprites_begin_top_bits")
              asm.lda(MOST_SPRITES)
              asm.sta(asm.abs(memory[NEXT_ROW]))
              asm.lda(0)
              asm.sta(asm.long(drawn))
              asm.rtl

              asm.label("rt_sprite_place")
              # The pose: in the table, or no sprite.
              asm.lda(asm.direct(r.call(0)))
              asm.sta(asm.direct(pointer))
              asm.lda(asm.direct(r.call(0) + 2))
              asm.sta(asm.direct(pointer + 2))
              asm.lda(asm.direct(r.call(1) + 2))
              asm.bne("rt_sprite_place_none")
              asm.lda(asm.direct(r.call(1)))
              asm.cmp(asm.ind_long(pointer))
              asm.bcc("rt_sprite_place_posed")
              asm.label("rt_sprite_place_none")
              asm.rtl
              asm.label("rt_sprite_place_posed")
              asm.inc
              asm.asl
              asm.tay
              asm.lda(asm.ind_long_y(pointer)) # the picture's number
              asm.sta(asm.direct(r.call(1)))
              # The reader's row: whose, which picture, where.
              asm.lda(asm.long(drawn))
              asm.cmp(MOST_SPRITES)
              asm.bcs("rt_sprite_place_noted")
              asm.asl
              asm.asl
              asm.asl
              asm.tax
              asm.lda(asm.direct(r.call(4)))
              asm.sta(asm.long_x(drawn, 2))
              asm.lda(asm.direct(r.call(1)))
              asm.sta(asm.long_x(drawn, 4))
              asm.lda(asm.direct(r.call(2)))
              asm.sta(asm.long_x(drawn, 6))
              asm.lda(asm.direct(r.call(3)))
              asm.sta(asm.long_x(drawn, 8))
              asm.lda(asm.long(drawn))
              asm.inc
              asm.sta(asm.long(drawn))
              asm.label("rt_sprite_place_noted")
              # A place outside -512..511 either way is off the screen whatever the piece.
              [r.call(2), r.call(3)].each do |at|
                asm.lda(asm.direct(at))
                asm.clc
                asm.adc(512)
                asm.tax
                asm.lda(asm.direct(at + 2))
                asm.adc(0) # with the carry from the low half: nought for every place in range
                asm.bne("rt_sprite_place_off")
                asm.cpx(1024)
                asm.bcs("rt_sprite_place_off")
              end
              # The picture's pieces.
              asm.lda(asm.direct(r.call(1)))
              asm.asl
              asm.adc(asm.direct(r.call(1))) # × 3: a 24-bit place each
              asm.tax
              asm.lda(asm.long_x("art sprite pictures"))
              asm.sta(asm.direct(pointer))
              asm.lda(asm.long_x("art sprite pictures", 2))
              asm.and_a(0x00FF)
              asm.sta(asm.direct(pointer + 2))
              asm.lda(asm.ind_long(pointer)) # how many pieces
              asm.sta(asm.direct(r.call(5)))
              asm.ldy(2)
              asm.label("rt_sprite_place_piece")
              asm.lda(asm.direct(r.call(5)))
              asm.bne("rt_sprite_place_more")
              asm.label("rt_sprite_place_off")
              asm.rtl
              asm.label("rt_sprite_place_more")
              asm.dec(asm.direct(r.call(5)))
              asm.lda(asm.abs(memory[NEXT_ROW]))
              asm.beq("rt_sprite_place_off") # the table is full
              # Across: -7 to 255 reaches the screen.
              asm.lda(asm.ind_long_y(pointer))
              asm.clc
              asm.adc(asm.direct(r.call(2)))
              asm.sta(asm.direct(piece_x))
              asm.clc
              asm.adc(7)
              asm.cmp(256 + 7)
              asm.bcs("rt_sprite_place_skip")
              # Down: -7 to 223.
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(pointer))
              asm.clc
              asm.adc(asm.direct(r.call(3)))
              asm.sta(asm.direct(piece_y))
              asm.clc
              asm.adc(7)
              asm.cmp(224 + 7)
              asm.bcs("rt_sprite_place_skip_down")
              # The row: the next free, counting down.
              asm.dec(asm.abs(memory[NEXT_ROW]))
              asm.lda(asm.abs(memory[NEXT_ROW]))
              asm.asl
              asm.asl
              asm.tax
              asm.sep(0x20)
              asm.lda(asm.direct(piece_x))
              asm.sta(asm.long_x(oam))
              asm.lda(asm.direct(piece_y))
              asm.sta(asm.long_x(oam, 1))
              asm.rep(0x20)
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(pointer)) # the tile, and its attributes above it
              asm.sta(asm.long_x(oam, 2))
              asm.iny
              asm.iny
              # Across's ninth bit, for a piece left of the screen: in the row's two bits, in the
              # byte of the 32 that holds four rows' each.
              asm.lda(asm.direct(piece_x))
              asm.bpl("rt_sprite_place_piece")
              asm.lda(asm.abs(memory[NEXT_ROW]))
              asm.and_a(3)
              asm.tax
              asm.lda(asm.long_x("rt_sprite_top_bit"))
              asm.and_a(0x00FF)
              asm.sta(asm.direct(piece_y))
              asm.lda(asm.abs(memory[NEXT_ROW]))
              asm.lsr
              asm.lsr
              asm.tax
              asm.sep(0x20)
              asm.lda(asm.long_x(oam, 512))
              asm.ora(asm.direct(piece_y))
              asm.sta(asm.long_x(oam, 512))
              asm.rep(0x20)
              asm.brl("rt_sprite_place_piece")
              asm.label("rt_sprite_place_skip")
              asm.iny
              asm.iny
              asm.label("rt_sprite_place_skip_down")
              asm.iny
              asm.iny
              asm.iny
              asm.iny
              asm.brl("rt_sprite_place_piece")
              asm.label("rt_sprite_top_bit")
              asm.data_bytes(0x01, 0x04, 0x10, 0x40)
            end

            # BACKGROUNDS. rt_background_put_up(layer, grid, from_corner): the grid numbered +grid+
            # (the table "art grids") copied onto +layer+ in the next blank, and with +from_corner+
            # its view at the corner. rt_background_scroll(layer, x, y). rt_set_cell(layer, column,
            # row, word): one cell of the layer's map, in the next blank.
            def emit_backgrounds(asm, memory, work)
              r = ->(n) { Memory.register(n) }
              layers = memory[LAYERS]

              asm.label("rt_layer_state") # X = where layer R0's state starts
              asm.lda(asm.direct(r.call(0)))
              4.times { asm.asl }
              asm.tax
              asm.rts

              asm.label("rt_background_put_up")
              asm.jsr(asm.abs("rt_layer_state"))
              asm.lda(asm.direct(r.call(1)))
              asm.asl
              asm.sta(asm.direct(work))
              asm.asl
              asm.asl
              asm.adc(asm.direct(work)) # × 10: an entry of the grids' table
              asm.tay
              [[0, LAYER_SOURCE], [2, LAYER_SOURCE + 2], [4, LAYER_BYTES], [6, LAYER_SC], [8, LAYER_COLUMNS]].each do |from, to|
                asm.tya
                asm.phx
                asm.tax
                asm.lda(asm.long_x("art grids", from))
                asm.plx
                asm.sta(asm.abs_x(layers + to))
              end
              asm.lda(1)
              asm.sta(asm.abs_x(layers + LAYER_PENDING))
              asm.lda(asm.direct(r.call(2)))
              asm.beq("rt_background_put_up_done")
              asm.stz(asm.abs_x(layers + LAYER_SCROLL_X))
              asm.stz(asm.abs_x(layers + LAYER_SCROLL_Y))
              asm.label("rt_background_put_up_done")
              asm.rtl

              asm.label("rt_background_scroll")
              asm.jsr(asm.abs("rt_layer_state"))
              asm.lda(asm.direct(r.call(1)))
              asm.sta(asm.abs_x(layers + LAYER_SCROLL_X))
              asm.lda(asm.direct(r.call(2)))
              asm.sta(asm.abs_x(layers + LAYER_SCROLL_Y))
              asm.rtl

              # The cell's address: the map's start, the screen of 32×32 it is in (the second across,
              # and below them the third and fourth — or the second, for a map one screen wide), and
              # its row and column in that screen.
              asm.label("rt_set_cell")
              asm.jsr(asm.abs("rt_layer_state"))
              asm.lda(asm.direct(r.call(2)))
              asm.and_a(31)
              5.times { asm.asl }
              asm.sta(asm.direct(work))
              asm.lda(asm.direct(r.call(1)))
              asm.and_a(31)
              asm.ora(asm.direct(work))
              asm.sta(asm.direct(work))
              asm.lda(asm.direct(r.call(1)))
              asm.and_a(32)
              asm.beq("rt_set_cell_left")
              asm.lda(asm.direct(work))
              asm.clc
              asm.adc(1024)
              asm.sta(asm.direct(work))
              asm.label("rt_set_cell_left")
              asm.lda(asm.direct(r.call(2)))
              asm.and_a(32)
              asm.beq("rt_set_cell_top")
              asm.lda(asm.abs_x(layers + LAYER_COLUMNS))
              asm.cmp(64)
              asm.lda(asm.direct(work))
              asm.bcc("rt_set_cell_narrow")
              asm.adc(2048 - 1) # the carry is set
              asm.bra("rt_set_cell_below")
              asm.label("rt_set_cell_narrow")
              asm.adc(1024)
              asm.label("rt_set_cell_below")
              asm.sta(asm.direct(work))
              asm.label("rt_set_cell_top")
              # The layer's map's start: layer 0's, or layer 1's.
              asm.lda(asm.direct(r.call(0)))
              asm.beq("rt_set_cell_first")
              asm.lda(LAYER_MAPS[1] - LAYER_MAPS[0])
              asm.label("rt_set_cell_first")
              asm.clc
              asm.adc(LAYER_MAPS[0])
              asm.adc(asm.direct(work))
              asm.sta(asm.direct(work))
              # Into the queue. A full queue stops the game, saying so (Frame::CELLS_FULL): the cell
              # would otherwise never reach the screen.
              asm.lda(asm.abs(memory[CELLS]))
              asm.cmp(MOST_CELLS)
              asm.bcc("rt_set_cell_room")
              asm.lda(Frame::CELLS_FULL)
              asm.jml(asm.long("rt_fault"))
              asm.label("rt_set_cell_room")
              asm.asl
              asm.asl
              asm.tax
              asm.lda(asm.direct(work))
              asm.sta(asm.abs_x(memory[CELLS] + 2))
              asm.lda(asm.direct(r.call(3)))
              asm.sta(asm.abs_x(memory[CELLS] + 4))
              asm.inc(asm.abs(memory[CELLS]))
              asm.rtl
            end

            # THE COPY IN THE BLANK. The screen is switched off first, so nothing below needs to fit
            # in the blank; then on again — straight away while the blank lasts, or in the next one.
            def emit_upload(asm, memory)
              h = Console::SNESHardware
              layers = memory[LAYERS]
              # The first pass's: the screen is off already, and Frame switches it on.
              asm.label("rt_upload_whole")
              asm.jsr(asm.abs("rt_upload_copy"))
              asm.rtl

              asm.label("rt_upload")
              asm.sep(0x20)
              asm.lda(h::FORCED_BLANK)
              asm.sta(asm.abs(h::INIDISP))
              asm.rep(0x20)
              asm.jsr(asm.abs("rt_upload_copy"))
              # On again: in this blank if it is not over, or the next.
              asm.sep(0x20)
              asm.lda(asm.abs(h::HVBJOY))
              asm.rep(0x20)
              asm.and_a(0x0080)
              asm.bne("rt_upload_on")
              asm.jsr(asm.abs("rt_sleep_until_vblank"))
              asm.label("rt_upload_on")
              asm.sep(0x20)
              asm.lda(h::FULL_BRIGHTNESS)
              asm.sta(asm.abs(h::INIDISP))
              asm.rep(0x20)
              asm.rtl

              asm.label("rt_upload_copy")
              # The sprite table, whole.
              asm.stz(asm.abs(h::OAMADDL))
              emit_dma(asm, h::DMA_TO_ONE_PORT, h::OAMDATA, asm.imm(memory[SHADOW_OAM] & 0xFFFF),
                       memory[SHADOW_OAM] >> 16, 544)
              # Each layer: its map, if one is waiting, and its scroll.
              LAYER_MAPS.each_with_index do |at, layer|
                state = layers + (layer * LAYER_STATE_BYTES)
                done = "rt_upload_layer#{layer}_copied"
                asm.lda(asm.abs(state + LAYER_PENDING))
                asm.beq(done)
                asm.stz(asm.abs(state + LAYER_PENDING))
                asm.lda(at)
                asm.sta(asm.abs(h::VMADDL))
                asm.sep(0x20)
                asm.lda(asm.abs(state + LAYER_SC))
                asm.ora((at >> 10) << 2)
                asm.sta(asm.abs(h::BG1SC + layer))
                asm.rep(0x20)
                asm.lda(asm.abs(state + LAYER_BYTES))
                asm.sta(asm.abs(h::DMA_BASE + h::DASL))
                asm.lda(asm.abs(state + LAYER_SOURCE))
                asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
                asm.sep(0x20)
                asm.lda(asm.abs(state + LAYER_SOURCE + 2))
                asm.sta(asm.abs(h::DMA_BASE + h::A1B))
                asm.lda(h::DMA_TO_TWO_PORTS)
                asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
                asm.lda(h::VMDATAL & 0xFF)
                asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
                asm.lda(1)
                asm.sta(asm.abs(h::MDMAEN))
                asm.rep(0x20)
                asm.label(done)
                # The scroll, each register written twice, its low byte and then its high. The
                # screen's first row is the console's line 1, not line 0, so a layer shows the map
                # row one past its vertical scroll there: the scroll written is one less than the
                # game's, which puts the map's row where the game said.
                asm.lda(asm.abs(state + LAYER_SCROLL_X))
                emit_scroll_register(asm, h::BG1HOFS + (layer * 2))
                asm.lda(asm.abs(state + LAYER_SCROLL_Y))
                asm.dec
                emit_scroll_register(asm, h::BG1VOFS + (layer * 2))
              end
              # The cells changed, each a word at its address.
              asm.ldx(0)
              asm.label("rt_upload_cell")
              asm.lda(asm.abs(memory[CELLS]))
              asm.beq("rt_upload_cells_done")
              asm.dec(asm.abs(memory[CELLS]))
              asm.lda(asm.abs_x(memory[CELLS] + 2))
              asm.sta(asm.abs(h::VMADDL))
              asm.lda(asm.abs_x(memory[CELLS] + 4))
              asm.sta(asm.abs(h::VMDATAL))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.bra("rt_upload_cell")
              asm.label("rt_upload_cells_done")
              asm.rts
            end
          end
        end
      end
    end
  end
end
