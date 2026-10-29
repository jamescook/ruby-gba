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
          # console's 64K of video RAM (word addresses, as the console counts them):
          #
          #   $0000-$6FFF  the screen's tiles, in the order they are shown, row by row
          #   $7000-$77FF  the layer's map, 32 cells across and 64 down: which tile each cell shows
          #   $7860-$787F  the CLEAR TILE, every pixel the colour the screen was last cleared to
          #   $7880-$78BF  the SEE-THROUGH TILE, every pixel nought, never written (Boot leaves it so)
          #
          # The map's rows past the picture's 28 show the see-through tile, so a view moved down or
          # up past the picture (`camera`) shows the backdrop there, colour 0 of the colour memory,
          # which is black and fades with the picture (Tint) as the interpreter's backdrop does. The
          # map is 32 cells across, as wide as the screen, so a view moved across wraps round; the
          # console's first WINDOW hides the layer outside the columns where the picture is
          # (rt_paint_camera), and the backdrop shows there.
          #
          # THE GAME PAINTS INTO A COPY in work RAM — $7F:0000 to $7F:DFFF of its upper bank, laid out
          # the same way — and the tiles it changed go to video RAM after the pass (rt_paint_upload).
          # On a cartridge with a Super FX the copy is the chip's RAM instead (ChipPaint).
          #
          # A CLEAR WRITES NOTHING. Copying the whole screen is 57344 bytes, fourteen blanks' worth,
          # and a game that clears every pass would pay that every pass. Instead the clear moves the
          # screen on a GENERATION, and a tile last painted in an older generation is the clear
          # colour throughout, whatever the copy holds there (the Game Boy Color's painted screen does
          # the same). Such a tile is shown by pointing its cell of the map at the clear tile, two
          # bytes instead of 64. The first paint of a tile in a generation fills it with the clear
          # colour first and points its cell back at its own tile (rt_paint_ready). So each tile
          # keeps the generation it was last made ready in (GENERATIONS, a byte a tile), and work RAM
          # keeps the whole map as it is to be once the pass is shown (MAP_COPY).
          #
          # WHAT A PASS SENDS. The tiles painted in the pass, where they are in this generation: for
          # each row of tiles the copy keeps the leftmost and rightmost tile painted since the last
          # blank (DIRTY), and as the pass ends (rt_paint_prepare) each row's tiles of this generation
          # between them are put on a list of RUNS, side by side in video RAM and in the copy, a copy
          # each. Then, if they changed, the clear tile, the map and the colours of a fade or tint.
          #
          # THE COPY TO VIDEO RAM IS SPREAD OVER BLANKS, WITH THE SCREEN ON (Blank says how): the
          # runs go one at a time, each when the blank has room and time for it. The map, the clear
          # tile and the colours go last, all in one blank: until then a tile that was the clear
          # colour still shows the clear tile, so a tile sent early is not seen early, and the
          # colours never show with the last pass's tiles. A tile painted in both passes shows as it
          # arrives; a pass that changes more than a blank holds of such tiles still shows them
          # coming in down the screen.
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
          #   rt_paint_camera   the view moved over the picture (`camera`)
          #   rt_paint_clear    the screen, or the rectangle, in one colour
          #   rt_paint_fill     a rectangle in one colour
          #   rt_paint_blit     a picture (SNES::PaintedArt's) at a place
          #   rt_paint_blit_one_of  one of a list of pictures, by number
          #   rt_paint_save     the patch of the screen under a sprite, kept
          #   rt_paint_restore  the patch put back
          #   rt_paint_prepare  as a pass ends: the runs of tiles to send
          #   rt_paint_upload   in the blank: the runs, then the map, the clear tile and the colours
          module Paint
            COLUMNS = 32
            ROWS = 28
            TILES = COLUMNS * ROWS
            TILE_BYTES = 64
            WIDTH = COLUMNS * 8
            HEIGHT = ROWS * 8
            COPY = 0x7F0000
            COPY_BYTES = TILES * TILE_BYTES
            MAP = 0x7000
            MAP_BYTES = TILES * 2
            # Work RAM's first byte, where the work RAM port counts from.
            WORK_RAM = 0x7E0000

            # THE CLEAR TILE is tile 963, at $7860, past the map, where no tile of the screen is. A
            # cell of the map is a word: the tile's number in its low ten bits, and above them its
            # colours' group, its priority and whether it is drawn flipped across or down. The cell
            # that shows the clear tile is drawn flipped both ways, which a tile of one colour does
            # not show, so that both of its bytes are $C3 — and so the whole map can be pointed at
            # it by the copying engine sending one byte over and over (DMA_FIXED_SOURCE).
            CLEAR_TILE = 963
            CLEAR_TILE_AT = CLEAR_TILE * TILE_BYTES / 2
            CLEAR_CELL = 0xC3C3
            # The cell that shows the see-through tile, the tile after the clear tile.
            SEE_THROUGH_CELL = CLEAR_TILE + 1
            # The map's rows: the picture's, then the see-through ones to its foot.
            MAP_ROWS = 64
            # BG1SC's size bits for a map 32 cells across and 64 down.
            MAP_32_BY_64 = 0x02
            # Where the camera puts the view: how far it is scrolled across, how far down (one less,
            # for the screen's first row, see rt_paint_start), the window's left and right columns
            # as WH0 and WH1 take them (a byte each, the left lowest), whether they changed since
            # the last blank sent them, and the place the game gave, 32 bits each way, for a reader
            # of the run (SNES::HeadlessRun).
            CAMERA = "rt paint camera"
            CAMERA_ACROSS = 0
            CAMERA_DOWN = 2
            CAMERA_WINDOW = 4
            CAMERA_CHANGED = 6
            CAMERA_X = 8
            CAMERA_Y = 12
            CAMERA_BYTES = 16
            # The window when the picture shows across the whole screen, and when none of it does
            # (its left past its right: no columns).
            WHOLE_WINDOW = 0xFF00
            NO_WINDOW = 0x00FF

            # Where painting is held to (`inside`): its left, top, right and bottom, right and bottom
            # just past it.
            AREA = "rt paint area"
            # For each row of tiles, the leftmost and rightmost tile changed since the last blank: a
            # word each. A row with none has its leftmost past its rightmost (NONE_LEFT, 0).
            DIRTY = "rt paint dirty"
            NONE_LEFT = COLUMNS
            # For each tile column, which of its pixels the painting at hand may touch: worked out
            # once a picture or a patch (rt_paint_column_masks), not for every row of it.
            COLUMN_MASKS = "rt paint column masks"
            # The screen's generation, from 0 to one short of NO_GENERATION, and each tile's, a byte
            # each: the generation the tile was made ready in. Coming round, every tile is put in
            # NO_GENERATION, which the screen is never in, so no tile is taken for the new one.
            GENERATION = "rt paint generation"
            GENERATIONS = "rt paint generations"
            NO_GENERATION = 0xFF
            # The colour the screen was last cleared to (its place), its four words of planes as a
            # tile's row keeps them (rt_paint_planes), and the clear tile made of them, in work RAM.
            CLEAR_PLACE = "rt paint clear place"
            CLEAR_PLANES = "rt paint clear planes"
            CLEAR_TILE_COPY = "rt paint clear tile"
            # The map as the pass leaves it: a word for each of the screen's cells.
            MAP_COPY = "rt paint map"
            # Whether the map, or the clear tile, changed since the last blank sent them.
            MAP_CHANGED = "rt paint map changed"
            CLEAR_CHANGED = "rt paint clear changed"
            # The runs of tiles to send, each its first tile and how many, a word each: from the
            # start, the runs of tiles not on the screen now, to RUNS_END; and from the end back to
            # IN_PLACE_START, the runs of tiles that are (see SHOWN_IN). A run is a tile or more,
            # so there are never more runs than tiles.
            RUNS = "rt paint runs"
            RUNS_END = "rt paint runs end"
            IN_PLACE_START = "rt paint in place start"
            MOST_RUNS = TILES
            # WHICH TILES ARE ON THE SCREEN NOW: for each tile, the generation it was last sent in
            # (written as a pass is prepared), and the generation the screen shows (SHOWN_GENERATION,
            # a word: nothing, past any byte, at power-on). A tile whose two match has its cell
            # pointing at its own slot of video RAM in the map on the screen, so whatever is copied
            # into that slot is seen as it arrives; such tiles go last, with the map. Each pass is
            # shown before the next is prepared, so the generation shown is the one the last pass
            # was prepared in. Readying and clearing leave these alone, so a pass that clears twice,
            # or as the generations come round, still knows. When a byte's generations come round
            # to one a tile was last sent in long ago, that tile is taken to be on the screen when
            # it is not: it goes last when it need not, which is only later.
            SHOWN_IN = "rt paint shown in"
            SHOWN_GENERATION = "rt paint shown generation"
            NOTHING_SHOWN = 0xFFFF

            # The direct page the routines work on.
            Scratch = Data.define(:left, :right, :top, :bottom, :area, :y, :row, :count, :chunk, :last,
                                  :shift, :mask, :not_mask, :planes, :left_planes, :right_planes,
                                  :pointer, :height, :across, :first_x, :temp, :column, :tile, :mark_row,
                                  :mark_count) do
              def area_left = area
              def area_top = area + 2
              def area_right = area + 4
              def area_bottom = area + 6
            end

            R = Ractor.make_shareable(->(n) { Memory.register(n) })

            module_function

            # On a cartridge with a Super FX (+chip+) the copy is the chip's RAM, so work RAM keeps
            # none, and what the painted screen keeps beside it goes with the rest of work RAM's far
            # places; on a plain one it goes in the last bank, after the copy.
            def reserve(memory, chip: false)
              memory.reserve_last_bank("rt paint copy", COPY_BYTES) unless chip
              far = chip ? memory.method(:reserve_far) : memory.method(:reserve_last_bank)
              far.call(GENERATIONS, TILES)
              far.call(MAP_COPY, MAP_BYTES)
              far.call(CLEAR_TILE_COPY, TILE_BYTES)
              far.call(RUNS, MOST_RUNS * 4)
              far.call(SHOWN_IN, TILES)
              memory.reserve(AREA, 8)
              memory.reserve(DIRTY, ROWS * 4)
              memory.reserve(COLUMN_MASKS, COLUMNS * 2)
              memory.reserve(GENERATION, 2)
              memory.reserve(CLEAR_PLACE, 2)
              memory.reserve(CLEAR_PLANES, 8)
              memory.reserve(MAP_CHANGED, 2)
              memory.reserve(CLEAR_CHANGED, 2)
              memory.reserve(RUNS_END, 2)
              memory.reserve(IN_PLACE_START, 2)
              memory.reserve(SHOWN_GENERATION, 2)
              memory.reserve(CAMERA, CAMERA_BYTES)
            end

            def scratch(memory)
              Scratch.new(left: memory.scratch(2), right: memory.scratch(2), top: memory.scratch(2),
                          bottom: memory.scratch(2), area: memory.scratch(8), y: memory.scratch(2),
                          row: memory.scratch(2), count: memory.scratch(2), chunk: memory.scratch(2),
                          last: memory.scratch(2), shift: memory.scratch(2), mask: memory.scratch(2),
                          not_mask: memory.scratch(2), planes: memory.scratch(8), left_planes: memory.scratch(10),
                          right_planes: memory.scratch(10), pointer: memory.scratch(4), height: memory.scratch(2),
                          across: memory.scratch(2), first_x: memory.scratch(2), temp: memory.scratch(4),
                          column: memory.scratch(2), tile: memory.scratch(2), mark_row: memory.scratch(2),
                          mark_count: memory.scratch(2))
            end

            # +chip+ for a cartridge with a Super FX: see ChipPaint, which says what changes there.
            def emit(asm, memory, s, chip: false)
              bank = chip ? ChipPaint::COPY >> 16 : COPY >> 16
              emit_start(asm, memory)
              emit_area(asm, memory, s)
              emit_camera(asm, memory, s)
              emit_helpers(asm, memory, s, bank)
              emit_clear(asm, memory, s)
              emit_fill(asm, memory, s, bank)
              emit_blit(asm, memory, s, bank)
              emit_patches(asm, memory, s, bank)
              emit_prepare(asm, memory, s)
              emit_upload(asm, memory, s, bank)
              emit_send_run(asm, memory, bank)
              emit_send_runs(asm, memory, s)
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
              asm.lda(((MAP >> 10) << 2) | MAP_32_BY_64) # its map at $7000, 32 cells across and 64 down
              asm.sta(asm.abs(h::BG1SC))
              # The first window hides the layer outside its columns (W12SEL: the window on, its
              # outside the part hidden; TMW: on the main screen), every column at power-on.
              asm.stz(asm.abs(h::WH0))
              asm.lda(0xFF)
              asm.sta(asm.abs(h::WH1))
              asm.lda(0x03)
              asm.sta(asm.abs(h::W12SEL))
              asm.lda(0x01)
              asm.sta(asm.abs(h::TMW))
              asm.lda(0x01) # the first layer alone on the main screen
              asm.sta(asm.abs(h::TM))
              # The screen's first row is the console's line 1 (see Runtime::Picture's scroll), so the
              # layer is scrolled up one: -1 is $3FF in the register's ten bits.
              asm.lda(0xFF)
              asm.sta(asm.abs(h::BG1VOFS))
              asm.lda(0x03)
              asm.sta(asm.abs(h::BG1VOFS))
              asm.rep(0x20)
              # The map: every cell of the picture shows the clear tile, black at power-on, as the
              # screen starts, and every cell past it the see-through tile.
              asm.lda(MAP)
              asm.sta(asm.abs(h::VMADDL))
              asm.ldx(0)
              asm.label("rt_paint_start_cell")
              asm.lda(CLEAR_CELL)
              asm.cpx(TILES)
              asm.bcc("rt_paint_start_cell_shown")
              asm.lda(SEE_THROUGH_CELL)
              asm.label("rt_paint_start_cell_shown")
              asm.sta(asm.abs(h::VMDATAL))
              asm.inx
              asm.cpx(COLUMNS * MAP_ROWS)
              asm.bne("rt_paint_start_cell")
              # The colours, all 256.
              asm.sep(0x20)
              asm.stz(asm.abs(h::CGADD))
              asm.rep(0x20)
              Picture.emit_dma(asm, h::DMA_TO_ONE_PORT, h::CGDATA, asm.imm("art colors"), asm.bank_of("art colors"), 512)
              # Paint anywhere, and nothing changed yet. The screen starts cleared to place 0, black,
              # in generation 0, which no tile is in yet; the copy, the clear tile in video RAM and the
              # clear colour's planes start all nought, as Boot leaves them.
              asm.jsl(asm.long("rt_paint_anywhere"))
              emit_fill_work_ram(asm, memory[GENERATIONS], TILES, "rt_paint_no_generation")
              emit_fill_work_ram(asm, memory[SHOWN_IN], TILES, "rt_paint_no_generation")
              emit_fill_work_ram(asm, memory[MAP_COPY], MAP_BYTES, "rt_paint_clear_cell")
              [GENERATION, CLEAR_PLACE, MAP_CHANGED, CLEAR_CHANGED, RUNS_END].each do |name|
                asm.stz(asm.abs(memory[name]))
              end
              asm.lda(NOTHING_SHOWN)
              asm.sta(asm.abs(memory[SHOWN_GENERATION]))
              asm.lda(MOST_RUNS * 4)
              asm.sta(asm.abs(memory[IN_PLACE_START]))
              asm.stz(asm.abs(memory[CAMERA] + CAMERA_ACROSS))
              asm.lda(0x03FF)
              asm.sta(asm.abs(memory[CAMERA] + CAMERA_DOWN))
              asm.lda(WHOLE_WINDOW)
              asm.sta(asm.abs(memory[CAMERA] + CAMERA_WINDOW))
              [CAMERA_CHANGED, CAMERA_X, CAMERA_X + 2, CAMERA_Y, CAMERA_Y + 2].each do |at|
                asm.stz(asm.abs(memory[CAMERA] + at))
              end
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

            # +bytes+ of work RAM from +address+ (24 bits) all the byte at +label+, by the copying
            # engine's channel 0 sending that one byte (DMA_FIXED_SOURCE) to the work RAM port,
            # which moves on by itself. The port counts work RAM's 128K from nought, $7E:0000, in 17
            # bits. The engine moves a byte in one of the processor's slow cycles, where a loop of
            # 16-bit stores takes eight of them a byte.
            def emit_fill_work_ram(asm, address, bytes, label)
              h = Console::SNESHardware
              offset = address - WORK_RAM
              asm.lda(offset & 0xFFFF)
              asm.sta(asm.abs(h::WMADDL))
              asm.sep(0x20)
              asm.lda(offset >> 16)
              asm.sta(asm.abs(h::WMADDL + 2))
              asm.rep(0x20)
              Picture.emit_dma(asm, h::DMA_TO_ONE_PORT | h::DMA_FIXED_SOURCE, h::WMDATA, asm.imm(label),
                               asm.bank_of(label), bytes)
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

            # --- the camera ---

            # rt_paint_camera(x, y): screen (0, 0) shows what was painted at (x, y) from the next
            # blank on, and the backdrop past the picture's edges. A view the picture's width or
            # more across, or its height or more down, shows nothing of it, so the place is held to
            # those first and the rest is worked in 16 bits:
            #
            #   across: the layer scrolled across by x; the window keeps the columns from -x (or 0)
            #           to 255 - x (or 255), the ones the picture is in, and hides the rest — all of
            #           them when x is 256 or -256, the window's left then past its right
            #   down:   the layer scrolled down by y, one less for the screen's first row; the map's
            #           rows past the picture show the see-through tile, 288 rows of them, enough for
            #           a view from 224 above the picture to 224 below it
            def emit_camera(asm, memory, s)
              camera = memory[CAMERA]
              asm.label("rt_paint_camera")
              [[R.call(0), CAMERA_X], [R.call(1), CAMERA_Y]].each do |from, to|
                asm.lda(asm.direct(from))
                asm.sta(asm.abs(camera + to))
                asm.lda(asm.direct(from + 2))
                asm.sta(asm.abs(camera + to + 2))
              end
              emit_clamp_signed(asm, R.call(0), WIDTH, s.left)
              emit_clamp_signed(asm, R.call(1), HEIGHT, s.top)
              asm.lda(asm.direct(s.left))
              asm.sta(asm.abs(camera + CAMERA_ACROSS))
              asm.lda(asm.direct(s.top))
              asm.dec
              asm.sta(asm.abs(camera + CAMERA_DOWN))
              # The window's left: -x for a view moved left, else the first column.
              asm.lda(asm.direct(s.left))
              asm.bpl("rt_paint_camera_from_first")
              asm.eor(0xFFFF)
              asm.inc
              asm.bra("rt_paint_camera_left")
              asm.label("rt_paint_camera_from_first")
              asm.lda(0)
              asm.label("rt_paint_camera_left")
              asm.cmp(WIDTH)
              asm.bcs("rt_paint_camera_none")
              asm.sta(asm.direct(s.temp))
              # ...and its right: 255 - x for a view moved right, else the last column.
              asm.lda(WIDTH - 1)
              asm.sec
              asm.sbc(asm.direct(s.left))
              asm.bit(asm.direct(s.left))
              asm.bpl("rt_paint_camera_right")
              asm.lda(WIDTH - 1)
              asm.label("rt_paint_camera_right")
              asm.cmp(0)
              asm.bmi("rt_paint_camera_none")
              asm.xba
              asm.ora(asm.direct(s.temp))
              asm.bra("rt_paint_camera_window")
              asm.label("rt_paint_camera_none")
              asm.lda(NO_WINDOW)
              asm.label("rt_paint_camera_window")
              asm.sta(asm.abs(camera + CAMERA_WINDOW))
              asm.lda(1)
              asm.sta(asm.abs(camera + CAMERA_CHANGED))
              asm.rtl
            end

            # +out+ = the 32-bit number at +at+ held between -+limit+ and +limit+, as 16 bits.
            def emit_clamp_signed(asm, at, limit, out)
              tag = "rt paint clamp signed #{at}"
              asm.lda(asm.direct(at + 2))
              asm.bmi("#{tag} below")
              asm.bne("#{tag} high")
              asm.lda(asm.direct(at))
              asm.cmp(limit + 1)
              asm.bcc("#{tag} keep")
              asm.label("#{tag} high")
              asm.lda(limit)
              asm.bra("#{tag} keep")
              asm.label("#{tag} below")
              asm.cmp(0xFFFF)
              asm.bne("#{tag} low")
              asm.lda(asm.direct(at))
              asm.cmp(0x10000 - limit)
              asm.bcs("#{tag} keep")
              asm.label("#{tag} low")
              asm.lda(0x10000 - limit)
              asm.label("#{tag} keep")
              asm.sta(asm.direct(out))
            end

            # --- what several routines share ---

            def emit_helpers(asm, memory, s, bank)
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
              # across, said changed, and each of those tiles made ready to paint in this generation.
              asm.label("rt_paint_mark")
              asm.lda(asm.direct(s.bottom))
              asm.dec
              3.times { asm.lsr }
              asm.sta(asm.direct(s.temp))
              asm.lda(asm.direct(s.top))
              3.times { asm.lsr }
              asm.sta(asm.direct(s.mark_row))
              asm.label("rt_paint_mark_row")
              asm.asl
              asm.asl
              asm.tax
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
              # The row's tiles, each of an older generation made ready.
              asm.lda(asm.direct(s.mark_row))
              5.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.chunk))
              asm.sta(asm.direct(s.tile))
              asm.lda(asm.direct(s.last))
              asm.sec
              asm.sbc(asm.direct(s.chunk))
              asm.inc
              asm.sta(asm.direct(s.mark_count))
              asm.label("rt_paint_mark_tile")
              asm.ldx(asm.direct(s.tile))
              asm.lda(asm.long_x(memory[GENERATIONS]))
              asm.and_a(0x00FF)
              asm.cmp(asm.abs(memory[GENERATION]))
              asm.beq("rt_paint_mark_ready")
              asm.jsr(asm.abs("rt_paint_ready"))
              asm.label("rt_paint_mark_ready")
              asm.inc(asm.direct(s.tile))
              asm.dec(asm.direct(s.mark_count))
              asm.bne("rt_paint_mark_tile")
              asm.lda(asm.direct(s.mark_row))
              asm.cmp(asm.direct(s.temp))
              asm.beq("rt_paint_mark_done")
              asm.inc
              asm.sta(asm.direct(s.mark_row))
              asm.bra("rt_paint_mark_row")
              asm.label("rt_paint_mark_done")
              asm.rts

              # rt_paint_ready (JSR): tile +tile+, of an older generation and so the clear colour
              # throughout, made so in the copy — eight rows of the clear colour's four words of
              # planes — and put in this generation, its cell of the map pointed back at it.
              asm.label("rt_paint_ready")
              asm.ldx(asm.direct(s.tile))
              asm.sep(0x20)
              asm.lda(asm.abs(memory[GENERATION]))
              asm.sta(asm.long_x(memory[GENERATIONS]))
              asm.rep(0x20)
              asm.txa
              asm.asl
              asm.tax
              asm.lda(asm.direct(s.tile))
              asm.sta(asm.long_x(memory[MAP_COPY]))
              6.times { asm.asl }
              asm.tax
              4.times do |pair|
                asm.lda(asm.abs(memory[CLEAR_PLANES] + (pair * 2)))
                8.times { |row| asm.sta(asm.long_x((bank << 16) + (pair * 16) + (row * 2))) }
              end
              asm.lda(1)
              asm.sta(asm.abs(memory[MAP_CHANGED]))
              asm.rts

              # rt_paint_planes (JSR): the colour at the place in A as four words, a pair of planes
              # each, into +planes+: $FF in a byte for a bit set.
              asm.label("rt_paint_planes")
              asm.sta(asm.direct(s.column))
              4.times do |pair|
                asm.stz(asm.direct(s.planes + (pair * 2)))
                2.times do |half|
                  skip = "rt_paint_planes_#{pair}_#{half}"
                  asm.lda(asm.direct(s.column))
                  asm.and_a(1 << ((pair * 2) + half))
                  asm.beq(skip)
                  asm.lda(half.zero? ? 0x00FF : 0xFF00)
                  asm.tsb(asm.direct(s.planes + (pair * 2)))
                  asm.label(skip)
                end
              end
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

              # rt_paint_column_masks (JSR): each column +tile+ to +mark_count+ (0 to 31, the first no
              # further on than the last) its rt_paint_column_mask, into COLUMN_MASKS.
              asm.label("rt_paint_column_masks")
              asm.lda(asm.direct(s.tile))
              3.times { asm.asl }
              asm.jsr(asm.abs("rt_paint_column_mask"))
              asm.pha
              asm.lda(asm.direct(s.tile))
              asm.asl
              asm.tax
              asm.pla
              asm.sta(asm.long_x(memory[COLUMN_MASKS]))
              asm.lda(asm.direct(s.tile))
              asm.cmp(asm.direct(s.mark_count))
              asm.inc(asm.direct(s.tile)) # INC leaves the carry as the comparison set it
              asm.bcc("rt_paint_column_masks")
              asm.rts
            end

            # --- clearing ---

            # rt_paint_clear(place): the screen in the colour at +place+, by moving on a generation
            # (see the top). Held to an area, the area alone, painted as a rectangle.
            def emit_clear(asm, memory, s)
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

              # The whole screen. A colour other than the last clear's makes the clear tile again:
              # its planes, kept for making tiles ready, and its 64 bytes, for the blank to send.
              asm.label("rt_paint_clear_whole")
              asm.lda(asm.direct(R.call(0)))
              asm.cmp(asm.abs(memory[CLEAR_PLACE]))
              asm.branch_long(:beq, "rt_paint_clear_same_colour")
              asm.sta(asm.abs(memory[CLEAR_PLACE]))
              asm.jsr(asm.abs("rt_paint_planes"))
              4.times do |pair|
                asm.lda(asm.direct(s.planes + (pair * 2)))
                asm.sta(asm.abs(memory[CLEAR_PLANES] + (pair * 2)))
                8.times { |row| asm.sta(asm.long(memory[CLEAR_TILE_COPY] + (pair * 16) + (row * 2))) }
              end
              asm.lda(1)
              asm.sta(asm.abs(memory[CLEAR_CHANGED]))
              asm.label("rt_paint_clear_same_colour")
              # The next generation; coming round, every tile put in none first.
              asm.lda(asm.abs(memory[GENERATION]))
              asm.inc
              asm.cmp(NO_GENERATION)
              asm.bcc("rt_paint_clear_generation")
              emit_fill_work_ram(asm, memory[GENERATIONS], TILES, "rt_paint_no_generation")
              asm.lda(0)
              asm.label("rt_paint_clear_generation")
              asm.sta(asm.abs(memory[GENERATION]))
              # Every cell shows the clear tile, and nothing painted before is to be sent.
              emit_fill_work_ram(asm, memory[MAP_COPY], MAP_BYTES, "rt_paint_clear_cell")
              asm.lda(1)
              asm.sta(asm.abs(memory[MAP_CHANGED]))
              asm.ldx(0)
              asm.label("rt_paint_clear_rows")
              asm.lda(NONE_LEFT)
              asm.sta(asm.abs_x(dirty))
              asm.stz(asm.abs_x(dirty + 2))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.cpx(ROWS * 4)
              asm.bne("rt_paint_clear_rows")
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
              # The colour's place as four words, a pair of planes each.
              asm.lda(asm.direct(R.call(4)))
              asm.jsr(asm.abs("rt_paint_planes"))
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
              # The picture: where its rows' places are, its columns and its height.
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
              # down, so -3 is the tile left of the screen), and its columns from there, held to the
              # area's.
              asm.lda(asm.direct(R.call(1)))
              3.times do
                asm.cmp(0x8000)
                asm.ror
              end
              asm.sta(asm.direct(s.first_x))
              asm.clc
              asm.adc(asm.direct(s.across))
              asm.dec # the last: the columns, from the first
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
              # Which of each row's eight runs of columns: the one for the place across modulo eight,
              # the columns × ten bytes on for each (SNES::PaintedArt), in +shift+.
              asm.lda(asm.direct(s.across))
              asm.asl
              asm.sta(asm.direct(s.shift))
              asm.asl
              asm.asl
              asm.clc
              asm.adc(asm.direct(s.shift))
              asm.sta(asm.direct(s.shift)) # a run's bytes
              asm.lda(asm.direct(R.call(1)))
              asm.and_a(7)
              asm.tax
              asm.lda(0)
              asm.label("rt_paint_blit_run")
              asm.cpx(0)
              asm.beq("rt_paint_blit_run_found")
              asm.clc
              asm.adc(asm.direct(s.shift))
              asm.dex
              asm.bra("rt_paint_blit_run")
              asm.label("rt_paint_blit_run_found")
              asm.sta(asm.direct(s.shift))
              [[s.area_left, s.left], [s.area_right, s.right]].each do |from, to|
                asm.lda(asm.direct(from))
                asm.sta(asm.direct(to))
              end
              asm.jsr(asm.abs("rt_paint_mark"))
              asm.lda(asm.direct(s.chunk))
              asm.sta(asm.direct(s.tile))
              asm.lda(asm.direct(s.last))
              asm.sta(asm.direct(s.mark_count))
              asm.jsr(asm.abs("rt_paint_column_masks"))
              emit_into_copy(asm, bank)
              asm.lda(asm.direct(s.top))
              asm.sta(asm.direct(s.y))
              asm.label("rt_paint_blit_row")
              # The row of the picture: its place, from the picture's table of rows, and its run.
              asm.lda(asm.direct(s.y))
              asm.sec
              asm.sbc(asm.direct(R.call(2)))
              asm.asl
              asm.asl
              asm.tay
              asm.lda(asm.ind_long_y(s.pointer))
              asm.clc
              asm.adc(asm.direct(s.shift)) # a row is in one bank, so this never carries
              asm.sta(asm.direct(s.temp))
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(s.pointer))
              asm.sta(asm.direct(s.temp + 2))
              asm.jsr(asm.abs("rt_paint_row_start"))
              asm.lda(asm.direct(s.chunk))
              asm.sta(asm.direct(s.count))
              asm.label("rt_paint_blit_tile")
              # The tile's eight pixels the area allows, and of them the ones the picture draws: its
              # column, ten bytes for each tile from the picture's first.
              asm.lda(asm.direct(s.count))
              asm.asl
              asm.tax
              asm.lda(asm.long_x(memory[COLUMN_MASKS]))
              asm.sta(asm.direct(s.not_mask))
              asm.lda(asm.direct(s.count))
              asm.sec
              asm.sbc(asm.direct(s.first_x))
              asm.asl
              asm.sta(asm.direct(s.right_planes))
              asm.asl
              asm.asl
              asm.clc
              asm.adc(asm.direct(s.right_planes))
              asm.tay
              asm.lda(asm.ind_long_y(s.temp))
              asm.and_a(asm.direct(s.not_mask))
              asm.beq("rt_paint_blit_next_tile")
              asm.sta(asm.direct(s.mask))
              asm.eor(0xFFFF)
              asm.sta(asm.direct(s.not_mask))
              asm.lda(asm.direct(s.count))
              6.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.tax
              # Each pair of planes into the tile's row: a word of the column, held to the mask.
              4.times do |pair|
                asm.iny
                asm.iny
                asm.lda(asm.ind_long_y(s.temp))
                asm.and_a(asm.direct(s.mask))
                asm.sta(asm.direct(s.left_planes))
                asm.lda(asm.abs_x(pair * 16))
                asm.and_a(asm.direct(s.not_mask))
                asm.ora(asm.direct(s.left_planes))
                asm.sta(asm.abs_x(pair * 16))
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
              # The tiles it reads, as far as they are on the screen, made ready: one of an older
              # generation is the clear colour, whatever the copy holds there.
              asm.lda(asm.direct(s.y))
              asm.bpl("rt_paint_save_top")
              asm.lda(0)
              asm.label("rt_paint_save_top")
              asm.sta(asm.direct(s.top))
              asm.lda(asm.direct(s.y))
              asm.clc
              asm.adc(asm.direct(s.height))
              asm.bmi("rt_paint_save_marked")
              asm.cmp(HEIGHT)
              asm.bcc("rt_paint_save_bottom")
              asm.lda(HEIGHT)
              asm.label("rt_paint_save_bottom")
              asm.sta(asm.direct(s.bottom))
              asm.cmp(asm.direct(s.top))
              asm.beq("rt_paint_save_marked")
              asm.bcc("rt_paint_save_marked")
              asm.lda(asm.direct(s.first_x))
              asm.bpl("rt_paint_save_first")
              asm.lda(0)
              asm.label("rt_paint_save_first")
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.direct(s.first_x))
              asm.clc
              asm.adc(asm.direct(s.across))
              asm.dec
              asm.bmi("rt_paint_save_marked")
              asm.cmp(COLUMNS)
              asm.bcc("rt_paint_save_last")
              asm.lda(COLUMNS - 1)
              asm.label("rt_paint_save_last")
              asm.sta(asm.direct(s.last))
              asm.cmp(asm.direct(s.chunk))
              asm.bcc("rt_paint_save_marked")
              asm.jsr(asm.abs("rt_paint_mark"))
              asm.label("rt_paint_save_marked")
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
              # The masks of the patch's columns on the screen, from its first (or the screen's)
              # to its last (or the screen's).
              asm.bpl("rt_paint_restore_masks_from")
              asm.lda(0)
              asm.label("rt_paint_restore_masks_from")
              asm.sta(asm.direct(s.tile))
              asm.lda(asm.direct(s.first_x))
              asm.clc
              asm.adc(asm.direct(s.across))
              asm.dec
              asm.cmp(COLUMNS)
              asm.bcc("rt_paint_restore_masks_to")
              asm.lda(COLUMNS - 1)
              asm.label("rt_paint_restore_masks_to")
              asm.sta(asm.direct(s.mark_count))
              asm.jsr(asm.abs("rt_paint_column_masks"))
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
              asm.asl
              asm.tax
              asm.lda(asm.long_x(memory[COLUMN_MASKS]))
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

            # --- the end of a pass ---

            # rt_paint_prepare (JSL, as a pass ends, before its wait): each row's tiles changed and
            # in this generation put on the runs to send, a run for each stretch of them side by
            # side — of tiles on the screen now, or of tiles that are not (SHOWN_IN), each on its own
            # list. A tile of an older generation between them is not sent: its cell shows the
            # clear tile. The rows are said unchanged again, and this generation is the one shown.
            #
            # A PASS THAT FITS IN ONE BLANK, as near as the rows changed say (rt_paint_prepare_whole),
            # is not split: every run goes on the list that is sent last, with the map, so the whole
            # pass arrives in one blank, in as few runs as it has. Only a bigger pass is split, its
            # tiles on the screen held back to go with the map.
            # (+mask+ is the kind of the run started, +not_mask+ the tile's: 0 not on the screen, 1
            # on, or held back with the map; +temp+ 1 for a pass that is not split.)
            def emit_prepare(asm, memory, s)
              dirty = memory[DIRTY]
              tint_changed = memory[Tint::STATE] + Tint::CHANGED
              asm.label("rt_paint_prepare")
              asm.stz(asm.abs(memory[RUNS_END]))
              asm.lda(MOST_RUNS * 4)
              asm.sta(asm.abs(memory[IN_PLACE_START]))
              # The pass's bytes at most: each changed row's tiles from its leftmost to its rightmost
              # and a run's setting up, then what goes with the map.
              asm.stz(asm.direct(s.count))
              asm.stz(asm.direct(s.temp))
              asm.ldx(0)
              asm.label("rt_paint_prepare_measure")
              asm.lda(asm.abs_x(dirty + 2))
              asm.sec
              asm.sbc(asm.abs_x(dirty))
              asm.bcc("rt_paint_prepare_measured_row") # a row with none
              asm.inc
              6.times { asm.asl }
              asm.clc
              asm.adc(RUN_SETTING_UP)
              asm.clc
              asm.adc(asm.direct(s.count))
              asm.sta(asm.direct(s.count))
              asm.cmp(Blank::BLANK_BYTES + 1)
              asm.bcs("rt_paint_prepare_split") # too big already
              asm.label("rt_paint_prepare_measured_row")
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.cpx(ROWS * 4)
              asm.bne("rt_paint_prepare_measure")
              [[memory[MAP_CHANGED], MAP_BYTES], [memory[CLEAR_CHANGED], TILE_BYTES], [tint_changed, 512]].each do |flag, bytes|
                skip = "rt_paint_prepare_count_#{bytes}"
                asm.lda(asm.abs(flag))
                asm.beq(skip)
                asm.lda(asm.direct(s.count))
                asm.clc
                asm.adc(bytes)
                asm.sta(asm.direct(s.count))
                asm.label(skip)
              end
              asm.lda(asm.direct(s.count))
              asm.cmp(Blank::BLANK_BYTES + 1)
              asm.bcs("rt_paint_prepare_split")
              asm.inc(asm.direct(s.temp)) # all of it with the map
              asm.label("rt_paint_prepare_split")
              asm.stz(asm.direct(s.row)) # the row's first tile
              asm.ldx(0)
              asm.label("rt_paint_prepare_row")
              asm.lda(asm.abs_x(dirty + 2))
              asm.cmp(asm.abs_x(dirty))
              asm.bcc("rt_paint_prepare_next_row")
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.sta(asm.direct(s.last))
              asm.lda(asm.abs_x(dirty))
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.sta(asm.direct(s.tile))
              asm.lda(NONE_LEFT)
              asm.sta(asm.abs_x(dirty))
              asm.stz(asm.abs_x(dirty + 2))
              asm.phx
              asm.lda(0xFFFF) # no run started
              asm.sta(asm.direct(s.chunk))
              asm.label("rt_paint_prepare_tile")
              asm.ldx(asm.direct(s.tile))
              asm.lda(asm.long_x(memory[GENERATIONS]))
              asm.and_a(0x00FF)
              asm.cmp(asm.abs(memory[GENERATION]))
              asm.bne("rt_paint_prepare_older")
              # On the screen now, or not (or the whole pass with the map); and from this pass,
              # sent in this generation.
              asm.lda(asm.direct(s.temp))
              asm.bne("rt_paint_prepare_kind")
              asm.lda(asm.long_x(memory[SHOWN_IN]))
              asm.and_a(0x00FF)
              asm.cmp(asm.abs(memory[SHOWN_GENERATION]))
              asm.bne("rt_paint_prepare_off_screen")
              asm.lda(1)
              asm.bra("rt_paint_prepare_kind")
              asm.label("rt_paint_prepare_off_screen")
              asm.lda(0)
              asm.label("rt_paint_prepare_kind")
              asm.sta(asm.direct(s.not_mask))
              asm.sep(0x20)
              asm.lda(asm.abs(memory[GENERATION]))
              asm.sta(asm.long_x(memory[SHOWN_IN]))
              asm.rep(0x20)
              # A run of the other kind is ended first.
              asm.lda(asm.direct(s.chunk))
              asm.bmi("rt_paint_prepare_start")
              asm.lda(asm.direct(s.not_mask))
              asm.cmp(asm.direct(s.mask))
              asm.beq("rt_paint_prepare_next_tile")
              asm.jsr(asm.abs("rt_paint_run_end"))
              asm.label("rt_paint_prepare_start")
              asm.lda(asm.direct(s.tile))
              asm.sta(asm.direct(s.chunk))
              asm.lda(asm.direct(s.not_mask))
              asm.sta(asm.direct(s.mask))
              asm.bra("rt_paint_prepare_next_tile")
              asm.label("rt_paint_prepare_older")
              asm.jsr(asm.abs("rt_paint_run_end"))
              asm.label("rt_paint_prepare_next_tile")
              asm.lda(asm.direct(s.tile))
              asm.cmp(asm.direct(s.last))
              asm.inc(asm.direct(s.tile)) # INC leaves the carry as the comparison set it
              asm.bcc("rt_paint_prepare_tile")
              asm.jsr(asm.abs("rt_paint_run_end"))
              asm.plx
              asm.label("rt_paint_prepare_next_row")
              asm.lda(asm.direct(s.row))
              asm.clc
              asm.adc(COLUMNS)
              asm.sta(asm.direct(s.row))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.cpx(ROWS * 4)
              asm.branch_long(:bne, "rt_paint_prepare_row")
              asm.lda(asm.abs(memory[GENERATION]))
              asm.sta(asm.abs(memory[SHOWN_GENERATION]))
              asm.rtl

              # rt_paint_run_end (JSR): the run started at +chunk+, if one is, ended before +tile+
              # and put on its list: the runs of tiles not on the screen from the start, the others
              # from the end back.
              asm.label("rt_paint_run_end")
              asm.lda(asm.direct(s.chunk))
              asm.bmi("rt_paint_run_end_none")
              asm.lda(asm.direct(s.mask))
              asm.bne("rt_paint_run_end_in_place")
              asm.ldx(asm.abs(memory[RUNS_END]))
              asm.txa
              asm.clc
              asm.adc(4)
              asm.sta(asm.abs(memory[RUNS_END]))
              asm.bra("rt_paint_run_end_put")
              asm.label("rt_paint_run_end_in_place")
              asm.lda(asm.abs(memory[IN_PLACE_START]))
              asm.sec
              asm.sbc(4)
              asm.sta(asm.abs(memory[IN_PLACE_START]))
              asm.tax
              asm.label("rt_paint_run_end_put")
              asm.lda(asm.direct(s.chunk))
              asm.sta(asm.long_x(memory[RUNS]))
              asm.lda(asm.direct(s.tile))
              asm.sec
              asm.sbc(asm.direct(s.chunk))
              asm.sta(asm.long_x(memory[RUNS] + 2))
              asm.lda(0xFFFF)
              asm.sta(asm.direct(s.chunk))
              asm.label("rt_paint_run_end_none")
              asm.rts
            end

            # --- the blank ---

            # rt_paint_upload (JSR, in the blank, the screen on — or off, before the first pass is
            # shown): the runs of tiles not on the screen, as many at a time as each blank has room
            # for (rt_paint_send_runs); then, all in one blank so they show together, the tiles on
            # the screen now (SHOWN_IN), the clear tile, the map and the colours of a fade or tint,
            # those of them that changed. More than a blank holds of those, the tiles go first, as
            # the others did, and the rest in the blank after.
            def emit_upload(asm, memory, s, bank)
              h = Console::SNESHardware
              tint_changed = memory[Tint::STATE] + Tint::CHANGED
              asm.label("rt_paint_upload")
              asm.lda(asm.abs(memory[RUNS_END]))
              asm.sta(asm.direct(s.last))
              asm.ldx(0)
              asm.jsr(asm.abs("rt_paint_send_runs"))

              # +height+ is the bytes of the clear tile, the map and the colours; +chunk+ those and
              # the tiles on the screen, each run counted RUN_SETTING_UP more for setting it going.
              asm.label("rt_paint_upload_last")
              asm.stz(asm.abs(memory[RUNS_END]))
              asm.stz(asm.direct(s.height))
              [[memory[MAP_CHANGED], MAP_BYTES], [memory[CLEAR_CHANGED], TILE_BYTES], [tint_changed, 512]].each do |flag, bytes|
                skip = "rt_paint_upload_count_#{bytes}"
                asm.lda(asm.abs(flag))
                asm.beq(skip)
                asm.lda(asm.direct(s.height))
                asm.clc
                asm.adc(bytes)
                asm.sta(asm.direct(s.height))
                asm.label(skip)
              end
              asm.lda(asm.direct(s.height))
              asm.sta(asm.direct(s.chunk))
              asm.ldx(asm.abs(memory[IN_PLACE_START]))
              asm.label("rt_paint_upload_count_in_place")
              asm.cpx(MOST_RUNS * 4)
              asm.bcs("rt_paint_upload_counted")
              emit_add_run_bytes(asm, memory, s)
              asm.bra("rt_paint_upload_count_in_place")
              asm.label("rt_paint_upload_counted")
              # Nothing to copy, the camera alone moved: a line of the blank for its registers.
              asm.lda(asm.direct(s.chunk))
              asm.bne("rt_paint_upload_copies")
              asm.lda(asm.abs(memory[CAMERA] + CAMERA_CHANGED))
              asm.branch_long(:beq, "rt_paint_upload_done")
              asm.jsr(asm.abs("rt_blank_time"))
              asm.brl("rt_paint_upload_camera")
              asm.label("rt_paint_upload_copies")
              asm.cmp(Blank::BLANK_BYTES + 1)
              asm.bcs("rt_paint_upload_apart")
              asm.jsr(asm.abs("rt_blank_room"))
              asm.ldx(asm.abs(memory[IN_PLACE_START]))
              asm.label("rt_paint_upload_in_place")
              asm.cpx(MOST_RUNS * 4)
              asm.bcs("rt_paint_upload_rest")
              asm.jsr(asm.abs("rt_paint_send_run"))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.bra("rt_paint_upload_in_place")
              asm.label("rt_paint_upload_apart")
              asm.lda(MOST_RUNS * 4)
              asm.sta(asm.direct(s.last))
              asm.ldx(asm.abs(memory[IN_PLACE_START]))
              asm.jsr(asm.abs("rt_paint_send_runs"))
              asm.lda(asm.direct(s.height))
              asm.jsr(asm.abs("rt_blank_room"))
              asm.label("rt_paint_upload_rest")
              asm.lda(MOST_RUNS * 4)
              asm.sta(asm.abs(memory[IN_PLACE_START]))
              [[CLEAR_CHANGED, CLEAR_TILE_COPY, CLEAR_TILE_AT, TILE_BYTES],
               [MAP_CHANGED, MAP_COPY, MAP, MAP_BYTES]].each do |flag, from, to, bytes|
                skip = "rt_paint_upload_#{to}_sent"
                asm.lda(asm.abs(memory[flag]))
                asm.beq(skip)
                asm.stz(asm.abs(memory[flag]))
                asm.lda(to)
                asm.sta(asm.abs(h::VMADDL))
                asm.lda(bytes)
                asm.sta(asm.abs(h::DMA_BASE + h::DASL))
                asm.lda(memory[from] & 0xFFFF)
                asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
                asm.sep(0x20)
                asm.lda(memory[from] >> 16)
                emit_copy_to_video_ram(asm)
                asm.label(skip)
              end
              asm.jsr(asm.abs("rt_tint_upload"))
              # The camera: the layer's scroll, each register written twice, its low byte and then
              # its high, and the window's columns.
              asm.label("rt_paint_upload_camera")
              asm.lda(asm.abs(memory[CAMERA] + CAMERA_CHANGED))
              asm.beq("rt_paint_upload_done")
              asm.stz(asm.abs(memory[CAMERA] + CAMERA_CHANGED))
              asm.lda(asm.abs(memory[CAMERA] + CAMERA_ACROSS))
              Picture.emit_scroll_register(asm, h::BG1HOFS)
              asm.lda(asm.abs(memory[CAMERA] + CAMERA_DOWN))
              Picture.emit_scroll_register(asm, h::BG1VOFS)
              asm.lda(asm.abs(memory[CAMERA] + CAMERA_WINDOW))
              asm.sep(0x20)
              asm.sta(asm.abs(h::WH0))
              asm.xba
              asm.sta(asm.abs(h::WH1))
              asm.rep(0x20)
              asm.label("rt_paint_upload_done")
              asm.rts
            end

            # rt_paint_send_runs (JSR): the runs of RUNS from X up to +last+, as many at a time as
            # the blank has room and time for (Blank's rt_blank_left), each counted RUN_SETTING_UP
            # more; when not even the next fits, in the next blank. One check of the blank for each
            # handful of runs rather than for each run, which costs as much as copying a tile.
            # (+tile+ is where the handful starts, +mark_count+ where it ends, +chunk+ the room,
            # +count+ the handful's bytes.)
            def emit_send_runs(asm, memory, s)
              asm.label("rt_paint_send_runs")
              asm.stx(asm.direct(s.tile))
              asm.cpx(asm.direct(s.last))
              asm.bcs("rt_paint_send_runs_done")
              asm.jsr(asm.abs("rt_blank_left"))
              asm.sta(asm.direct(s.chunk))
              asm.stz(asm.direct(s.count))
              asm.label("rt_paint_send_runs_scan")
              asm.cpx(asm.direct(s.last))
              asm.bcs("rt_paint_send_runs_scanned")
              asm.lda(asm.long_x(memory[RUNS] + 2))
              6.times { asm.asl }
              asm.clc
              asm.adc(RUN_SETTING_UP)
              asm.clc
              asm.adc(asm.direct(s.count))
              asm.cmp(asm.direct(s.chunk))
              asm.beq("rt_paint_send_runs_take")
              asm.bcs("rt_paint_send_runs_scanned")
              asm.label("rt_paint_send_runs_take")
              asm.sta(asm.direct(s.count))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.bra("rt_paint_send_runs_scan")
              asm.label("rt_paint_send_runs_scanned")
              asm.stx(asm.direct(s.mark_count))
              asm.ldx(asm.direct(s.tile))
              asm.lda(asm.direct(s.count))
              asm.bne("rt_paint_send_runs_go")
              asm.jsr(asm.abs("rt_blank_next"))
              asm.bra("rt_paint_send_runs")
              asm.label("rt_paint_send_runs_go")
              asm.jsr(asm.abs("rt_blank_room"))
              asm.label("rt_paint_send_runs_one")
              asm.cpx(asm.direct(s.mark_count))
              asm.bcs("rt_paint_send_runs")
              asm.jsr(asm.abs("rt_paint_send_run"))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.bra("rt_paint_send_runs_one")
              asm.label("rt_paint_send_runs_done")
              asm.rts
            end

            # rt_paint_send_run (JSR): the run at X of RUNS copied to video RAM from the copy in
            # +bank+, its tiles to their own slots. Keeps X.
            def emit_send_run(asm, memory, bank)
              h = Console::SNESHardware
              asm.label("rt_paint_send_run")
              asm.lda(asm.long_x(memory[RUNS] + 2))
              6.times { asm.asl }
              asm.sta(asm.abs(h::DMA_BASE + h::DASL))
              asm.lda(asm.long_x(memory[RUNS]))
              5.times { asm.asl } # the first tile's word in video RAM
              asm.sta(asm.abs(h::VMADDL))
              asm.asl # ...and its byte in the copy
              asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
              asm.sep(0x20)
              asm.lda(bank)
              emit_copy_to_video_ram(asm)
              asm.rts
            end

            # What setting a run going costs the blank, counted as bytes copied: two thirds of a
            # line as Blank counts them (about 146 bytes), for the hundred or so cycles of code that
            # start its copy.
            RUN_SETTING_UP = 96

            # The run at X of RUNS added to +chunk+, as its bytes and RUN_SETTING_UP; X on to the next.
            def emit_add_run_bytes(asm, memory, s)
              asm.lda(asm.long_x(memory[RUNS] + 2))
              6.times { asm.asl }
              asm.clc
              asm.adc(RUN_SETTING_UP)
              asm.clc
              asm.adc(asm.direct(s.chunk))
              asm.sta(asm.direct(s.chunk))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
            end

            # The copying engine's channel 0 sending to video RAM's two ports, from the bank in A (8
            # bits wide), the address and count already set; A back to 16 bits.
            def emit_copy_to_video_ram(asm)
              h = Console::SNESHardware
              asm.sta(asm.abs(h::DMA_BASE + h::A1B))
              asm.lda(h::DMA_TO_TWO_PORTS)
              asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
              asm.lda(h::VMDATAL & 0xFF)
              asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
              asm.lda(1)
              asm.sta(asm.abs(h::MDMAEN))
              asm.rep(0x20)
            end

            # The masks of a tile's row from a pixel to its right end (rt_paint_from_left, nine: from
            # pixel 0 to past pixel 7) and from its left end up to a pixel (rt_paint_up_to, nine); and
            # the bytes the copying engine fills work RAM with: a generation no tile is in, and either
            # byte of a cell showing the clear tile.
            def emit_tables(asm)
              asm.label("rt_paint_from_left")
              asm.data_words(*(0..8).map { |from| (0xFF >> from) * 0x0101 })
              asm.label("rt_paint_up_to")
              asm.data_words(*(0..8).map { |to| ((0xFF00 >> to) & 0xFF) * 0x0101 })
              asm.label("rt_paint_no_generation")
              asm.data_bytes(NO_GENERATION)
              asm.label("rt_paint_clear_cell")
              asm.data_bytes(CLEAR_CELL & 0xFF)
            end
          end
        end
      end
    end
  end
end
