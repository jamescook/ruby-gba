# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # A PAINTED SCREEN on a console that only draws tiles.
          #
          # The Advance has screens that are a picture in memory, a colour for every pixel, which a
          # game paints into (`screen :bitmap`). A Game Boy Color has no such thing: everything it
          # shows is tiles. So a painted screen here is 360 tiles, 20 across and 18 down, each the
          # background's own and each shown once, so that together they are the screen: a pixel of
          # the picture is a pixel of one of them. A tile's pixels are two bits, so each 8×8 square
          # of the picture holds four colours — the palette its cell of the grid names, one of the
          # background's last, which the build picks for every square and fills with the colours
          # that can be painted there (GBC::SquareColors), black first.
          #
          # The game paints into a copy of the 360 tiles in work memory (the FRAME, in work memory's
          # banks 2 to 4, 120 tiles to a bank), and the copy goes into the console between passes.
          # Copying all of it, 5760 bytes, takes three blanks, so only the tiles that changed go:
          #
          # - CLEARING the screen writes nothing. It moves the frame on a GENERATION, and a tile
          #   last painted in an earlier generation is the clearing colour throughout. The first
          #   paint of a tile in a generation fills it with that colour before painting.
          # - A tile is DIRTY once painted, and at the end of the pass (rt_paint_scan) each dirty
          #   tile is held against the copy last sent to the console, kept beside it. Only one that
          #   differs is sent.
          # - A tile that is the clearing colour throughout is not sent at all: its cell of the
          #   grid is pointed at the CLEAR tile instead, which is two bytes rather than sixteen.
          #   Every cell not showing its own tile shows the clearing colour, so a clear in another
          #   colour is the clear tile's sixteen bytes rewritten, whatever the screen holds.
          #
          # What has to go is a list (LIST), made when the pass ends, and the blank works down it
          # (rt_paint_upload), as far as the blank lasts; the pass counts as shown once it is done.
          module Paint
            # Which kind of screen is up: a painted one, or one drawn from tiles.
            TILED = 0
            PAINTED = 1

            # Where the frame lives: a bank of work memory for every six rows of tiles, and in each
            # bank the tiles as painted, the tiles as last sent, a byte of state a tile (its
            # generation, and DIRTY), and what its cell of the grid shows now (a colour, or OWN).
            BANKS = [2, 3, 4].freeze
            CELLS_A_BANK = 120
            ROWS_A_BANK = 6
            COLUMNS = 20
            ROWS = 18
            CELLS = COLUMNS * ROWS
            PAINTED_AT = 0xD000
            SENT_AT = 0xD780
            STATE_AT = 0xDF00
            SHOWN_AT = 0xDF78
            DIRTY = 0x80
            OWN = 0xFF
            # The generation no tile is ever in (see rt_paint_clear).
            NO_GENERATION = 0x7F

            # Where the console shows it: the second grid, its tiles in the background's tile memory
            # past what a tiled screen's art may use — bank 0 from 0x8800 and bank 1 from 0x8800 on
            # round to 0x9000 — and two tiles of a single colour after the last of them: black, for
            # the cells of the grid past the screen's edges (which a shake shows), and the CLEAR
            # tile, in the clearing colour, for every cell of the screen not showing its own tile.
            GRID = 0x9C00
            SOLID_TILE = 104
            SOLID_AT = 0x9680
            CLEAR_TILE = SOLID_TILE + 1
            CLEAR_AT = SOLID_AT + 16
            # The cells past the screen's edges are drawn from the background's last palette, the
            # painted screen's first (Art#painted_palettes), which like all of them holds black at
            # place 0. A cell of the screen is drawn from its square's (GBC::SquareColors).
            PALETTE = 7
            # The bit of a cell's attributes saying its tile is in video memory's second bank.
            TILE_BANK_BIT = Console::GBCHardware::ATTR_TILE_BANK.bit_length - 1

            # In the bank byte of an entry of the list to send: a cell pointed at the clear tile —
            # or, for the clear tile itself (CLEAR_TILE_ENTRY), the tile rewritten in the colour in
            # the two bits above the bank's number.
            SOLID = 0x80
            # In the bank byte of an entry for a tile's own picture: its cell of the grid shows it
            # already, so only the tile is sent. Most of a picture painted again is such tiles.
            KEEPS_CELL_BIT = 6
            KEEPS_CELL = 1 << KEEPS_CELL_BIT
            # In the tile byte of a SOLID entry: no cell, but the clear tile itself, rewritten in
            # the entry's colour. No bank holds this many tiles.
            CLEAR_TILE_ENTRY = 0xFF

            # AN ENTRY OF THE LIST TO SEND is a RUN of tiles side by side along a row of the
            # screen, sent the same way: their cells are next to each other in the frame's work
            # memory, in video memory and in the grid, so the console's copy takes the whole run at
            # once, and its cells are written in a short loop. A word of text is a run, where it
            # would be a tile at a time. The entry is worked out as the pass ends (rt_paint_send),
            # so the blank has as little to do for it as can be: two bytes, the first cell's number
            # (its low byte, and its top bit in bit 0 of the second), how many cells less one in
            # the five bits above that, and in the top two bits what is sent — the tiles and their
            # cells (none), the tiles alone (SENDS_KEEPING_CELL), or the cells pointed at the clear
            # tile (SENDS_SOLID). The clear tile rewritten is its colour and SENDS_CLEAR_TILE.
            # LIST_END in the second byte ends the list.
            #
            # A run never crosses the end of a row (where the next cell is not the next one in the
            # grid) or cell 128, where video memory's first bank ends. Each bank of work memory holds
            # six whole rows, so those banks end at a row's end too.
            SENDS_KEEPING_CELL = KEEPS_CELL
            SENDS_SOLID = SOLID
            SENDS_CLEAR_TILE = 0xC0
            LIST_END = 0xFF
            RUN_LENGTH_SHIFT = 1
            RUN_LENGTH_MASK = 0x1F
            VIDEO_BANK_CELLS = 128

            # The runtime's own places: the kind of screen up; the three lists — what to send in
            # the blank (entries as above, and LIST_END after the last), the tiles painted since
            # the last pass, the tiles whose cells show their own picture — each a count and then
            # two bytes an entry (for the last two, a tile's number in its bank and the bank's
            # among BANKS); where the blank has got to down the first (the place of its next
            # entry); the last two runs put on the list to send, which a cell painted next to
            # either is added to (RUNS, as #emit_send keeps them; NO_BANK for none yet); whether
            # the screen was cleared since the last pass,
            # and the colour every cell not showing its own picture shows; and the area painting
            # is held to (rt_paint_area), its left, top, right and bottom. For a game whose scenes
            # draw their squares from different palettes (GBC::SquareColors#maps), where the map of
            # the scene up now is (rt_paint_map), and the attributes of the run being sent.
            SCREEN_KIND = "rt paint screen kind"
            MAP = "rt paint map"
            RUN_ATTRIBUTES = "rt paint run attributes"
            LIST = "rt paint list"
            DIRTY_LIST = "rt paint dirty list"
            OWN_LIST = "rt paint own list"
            LIST_DONE = "rt paint list done"
            RUNS = "rt paint runs"
            NO_BANK = 0xFF
            CLEARED = "rt paint cleared"
            LAST_SOLID = "rt paint last solid"
            AREA = "rt paint area"
            SCRATCH = "rt paint scratch"

            # The area painting is held to when nothing holds it anywhere else: the whole screen.
            WHOLE_SCREEN = [0, 0, Console::GBCHardware::SCREEN_WIDTH, Console::GBCHardware::SCREEN_HEIGHT].freeze

            module_function

            def reserve(memory, painting:)
              memory.reserve(SCREEN_KIND, 1)
              return unless painting

              # The list to send holds a cell at most once, the clear tile, and its end.
              memory.reserve(LIST, 2 + ((CELLS + 2) * 2))
              [DIRTY_LIST, OWN_LIST].each { |list| memory.reserve(list, 2 + (CELLS * 2)) }
              memory.reserve(LIST_DONE, 2)
              memory.reserve(RUNS, 2 * RUN_BYTES)
              memory.reserve(CLEARED, 1)
              memory.reserve(LAST_SOLID, 1)
              memory.reserve(AREA, 4)
              memory.reserve(SCRATCH, 20)
              memory.reserve(MAP, 2)
              memory.reserve(RUN_ATTRIBUTES, 1)
            end

            # +map_count+ is how many maps of the screen's squares the game's scenes show between them
            # (GBC::SquareColors#maps).
            def emit(asm, memory, painting:, map_count: 1)
              emit_screen(asm, memory, painting: painting)
              return emit_nothing_painted(asm) unless painting

              quick = Quick.new(generation: memory.quick(1), clear: memory.quick(1), clear_low: memory.quick(1),
                                clear_high: memory.quick(1), ink_low: memory.quick(1), ink_high: memory.quick(1),
                                bank_index: memory.quick(1), bits_mask: memory.quick(1), bits_stride: memory.quick(1))
              emit_start(asm, memory, quick)
              emit_tables(asm)
              emit_tables_in_view(asm)
              emit_cell(asm, memory, quick)
              emit_area(asm, memory)
              emit_clear(asm, memory, quick)
              emit_rect(asm, memory, quick)
              emit_bits(asm, memory, quick)
              emit_patches(asm, memory, quick)
              emit_scan(asm, memory, quick)
              emit_map(asm, memory, map_count)
              emit_upload(asm, memory, map_count)
            end

            # What the painting keeps in the processor's quick memory: the generation, the clearing
            # colour and its two bytes a row, the colour being painted's two, and the bank of the
            # tile being painted, by its number among BANKS; and while a picture of one colour is
            # painted (rt_paint_bits), the pixels of the column of tiles it is painting and the
            # bytes a row of the picture takes.
            Quick = Data.define(:generation, :clear, :clear_low, :clear_high, :ink_low, :ink_high, :bank_index,
                                :bits_mask, :bits_stride)

            # rt_screen(kind): the screen up is a painted one (PAINTED) or one of tiles. 1 when
            # that is a change of kind, which replaces the whole display: a painted screen comes
            # up black, and a tiled one with nothing up. Either way with the console's sprite layer
            # off. The interpreter never puts the sprites of a game's tiled screens on a painted
            # picture, though it counts them as drawn, and on a tiled screen arrived at it puts
            # them up at the next sprite pass (rt_sprites_end) — or at once, over the scenery a
            # scene brings of its own (Lowering::Picture#emit_scene_arrival,
            # Reference#redraw_sprites_over_arrived_scenery). The table is kept, so what the game
            # placed this pass is still what it placed. 0, and nothing changes, for the kind
            # already up.
            def emit_screen(asm, memory, painting:)
              h = Console::GBCHardware
              asm.label("rt_screen")
              asm.load_hl_sp(2)
              asm.load(:a, [:hl])
              asm.load(:hl, memory[SCREEN_KIND])
              asm.cp_a([:hl])
              asm.jump_relative(:nz, "rt_screen_change")
              asm.load(:bc, 0)
              asm.load(:de, 0)
              asm.ret
              asm.label("rt_screen_change")
              asm.load([:hl], :a)
              asm.and_a(:a)
              asm.load(:a, [memory[Picture::LCDC_WANTED]])
              asm.jump_relative(:z, "rt_screen_tiled")
              asm.or_a(h::LCDC_BG_MAP1)
              asm.load([memory[Picture::LCDC_WANTED]], :a)
              if painting
                asm.xor_a(:a)
                asm.call("rt_paint_clear_to") # black, as the interpreter's crossing leaves it
              end
              asm.jump_relative("rt_screen_changed")
              asm.label("rt_screen_tiled")
              asm.and_a(~h::LCDC_BG_MAP1 & 0xFF)
              asm.load([memory[Picture::LCDC_WANTED]], :a)
              asm.call("rt_picture_take_down")
              asm.label("rt_screen_changed")
              asm.call("rt_sprites_off")
              asm.load(:bc, 0)
              asm.load(:de, 1)
              asm.ret
            end

            # A game that never paints has nothing to scan or send.
            def emit_nothing_painted(asm)
              asm.label("rt_paint_start")
              asm.label("rt_paint_scan")
              asm.and_a(:a)
              asm.ret
              asm.label("rt_paint_upload")
              asm.and_a(:a) # carry clear: nothing left to send
              asm.ret
            end

            # At power-on, with the screen off: the frame's three banks cleared (every tile black,
            # in generation 0, and shown as the single colour black), the black tile and the clear
            # tile, both black, and the second grid pointed at the clear tile on the screen and at
            # the black one past its edges.
            def emit_start(asm, memory, quick)
              h = Console::GBCHardware
              asm.label("rt_paint_start")
              BANKS.each do |bank|
                asm.load(:a, bank)
                asm.load_high(h::SVBK, :a)
                asm.load(:hl, PAINTED_AT)
                asm.load(:bc, h::WRAM_BANK_SIZE)
                asm.call("rt_clear")
              end
              asm.load(:a, 1)
              asm.load_high(h::SVBK, :a)
              asm.load_high(h::VBK, :a)
              asm.load(:hl, SOLID_AT)
              asm.xor_a(:a)
              32.times { asm.load([:hli], :a) } # the black tile and the clear tile, both black
              [[1, h::ATTR_TILE_BANK | PALETTE], [0, SOLID_TILE]].each do |bank, byte|
                asm.load(:a, bank)
                asm.load_high(h::VBK, :a)
                asm.load(:hl, GRID)
                asm.load(:bc, 1024)
                asm.label("rt_paint_start_grid_#{bank}")
                asm.load(:a, byte)
                asm.load([:hli], :a)
                asm.dec(:bc)
                asm.load(:a, :b)
                asm.or_a(:c)
                asm.jump_relative(:nz, "rt_paint_start_grid_#{bank}")
              end
              # ...and the screen's own cells at the clear tile.
              asm.load(:hl, GRID)
              asm.load(:de, Art::GRID_CELLS - COLUMNS)
              asm.load(:c, ROWS)
              asm.load(:a, CLEAR_TILE)
              asm.label("rt_paint_start_screen_row")
              asm.load(:b, COLUMNS)
              asm.label("rt_paint_start_screen_cell")
              asm.load([:hli], :a)
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_paint_start_screen_cell")
              asm.add_hl(:de)
              asm.dec(:c)
              asm.jump_relative(:nz, "rt_paint_start_screen_row")
              # ...in their squares' palettes, which they keep, whichever tile they show.
              asm.call("rt_paint_tables_in_view")
              asm.load(:a, 1)
              asm.load_high(h::VBK, :a)
              asm.load(:hl, "rt_paint_cells")
              asm.load(:de, ATTRIBUTES_AT)
              asm.add_hl(:de)
              asm.load(:d, :h)
              asm.load(:e, :l)
              asm.load(:hl, GRID)
              asm.load(:c, ROWS)
              asm.label("rt_paint_start_square_row")
              asm.load(:b, COLUMNS)
              asm.label("rt_paint_start_square")
              asm.load(:a, [:de])
              asm.or_a(h::ATTR_TILE_BANK)
              asm.load([:hli], :a)
              asm.load(:a, :e)
              asm.add_a(CELL_ENTRY_BYTES)
              asm.load(:e, :a)
              asm.jump_relative(:nc, "rt_paint_start_square_carried")
              asm.inc(:d)
              asm.label("rt_paint_start_square_carried")
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_paint_start_square")
              asm.push(:de)
              asm.load(:de, Art::GRID_CELLS - COLUMNS)
              asm.add_hl(:de)
              asm.pop(:de)
              asm.dec(:c)
              asm.jump_relative(:nz, "rt_paint_start_square_row")
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              asm.call("rt_bank_back")
              asm.xor_a(:a)
              %i[generation clear clear_low clear_high].each { |name| asm.load_high(quick.public_send(name), :a) }
              [DIRTY_LIST, OWN_LIST].each do |list|
                asm.load(:hl, memory[list])
                asm.load([:hli], :a)
                asm.load([:hl], :a)
              end
              asm.push(:af)
              asm.call("rt_paint_map_first")
              asm.pop(:af)
              asm.call("rt_paint_list_open")
              asm.load([memory[CLEARED]], :a)
              asm.load([memory[LAST_SOLID]], :a)
              asm.load(:hl, memory[AREA])
              WHOLE_SCREEN.each do |edge|
                asm.load(:a, edge)
                asm.load([:hli], :a)
              end
              # A game that powers on painting starts on a painted screen, with no sprite on it
              # (rt_screen).
              asm.load(:a, PAINTED)
              asm.load([memory[SCREEN_KIND]], :a)
              asm.load(:a, [memory[Picture::LCDC_WANTED]])
              asm.or_a(h::LCDC_BG_MAP1)
              asm.and_a(~h::LCDC_SPRITES_ON & 0xFF)
              asm.load([memory[Picture::LCDC_WANTED]], :a)
              asm.ret
            end

            # Tables the painting reads: for each row of tiles (eight bytes each) its bank of work
            # memory, where its first tile is there, that tile's number in the bank, and the bank's
            # number among BANKS; and the masks of a span. The rest are in a bank of their own
            # (#table_sections).
            def emit_tables(asm)
              asm.label("rt_paint_rows")
              ROWS.times do |row|
                in_bank = row % ROWS_A_BANK
                asm.data_bytes(BANKS.fetch(row / ROWS_A_BANK))
                asm.data_words(PAINTED_AT + (in_bank * COLUMNS * 16))
                asm.data_bytes(in_bank * COLUMNS, row / ROWS_A_BANK, 0, 0, 0)
              end
              # The pixels from x on, and the pixels before x: a tile row's mask for a span.
              asm.label("rt_paint_from_masks")
              asm.data_bytes((0..7).map { |x| 0xFF >> x })
              asm.label("rt_paint_before_masks")
              asm.data_bytes((0..8).map { |x| (~(0xFF >> x)) & 0xFF })
            end

            # THE TABLES OF HOW EACH CELL IS SENT, which are most of the painted screen's bytes, in
            # a bank of the cartridge of their own rather than in the part always in view, where a
            # game's own code and tables need the room. The blank and the end of the pass put the
            # bank in view while they read them (rt_paint_tables_in_view) and the game's back after
            # (rt_bank_back). For each cell, how it is sent (#emit_upload); how many cells a run
            # can grow by after it and before it, along its row and within its bank of video
            # memory; and for each length of run, the last line of the blank it may start on.
            # None for a game that never paints.
            #
            # +maps+ are the maps of the screen's squares the game's scenes show (GBC::SquareColors,
            # Art#square_maps), each the palette every cell's square is drawn from by the console's
            # number, and none for a game that never paints. A run is all one palette in every map, so
            # its attributes are written as one; a game of more than one map has each map's
            # attributes for every cell besides (rt_paint_map_N), which the blank writes a run's
            # cells from.
            def table_sections(maps:)
              return [] if maps.empty?

              asm = SM83.new("paint tables", home: :banked)
              asm.label("rt_paint_cells")
              CELLS.times { |cell| asm.data_bytes(cell_entry(cell, maps.first)) }
              asm.label("rt_paint_room_after")
              asm.data_bytes((0...CELLS).map { |cell| maps.map { |map| room_after(cell, map) }.min })
              asm.label("rt_paint_room_before")
              asm.data_bytes((0...CELLS).map { |cell| maps.map { |map| room_before(cell, map) }.min })
              asm.label("rt_paint_run_last_lines")
              asm.data_bytes((0..RUN_LENGTH_MASK).map { |less_one| run_last_line(less_one + 1, map_count: maps.length) })
              if maps.length > 1
                maps.each_with_index do |map, i|
                  asm.label("rt_paint_map_#{i}")
                  asm.data_bytes((0...CELLS).map { |cell| cell_entry(cell, map).last })
                end
              end
              [asm.section]
            end

            # The bank holding the tables, in view.
            def emit_tables_in_view(asm)
              asm.label("rt_paint_tables_in_view")
              asm.load_bank_of(:a, "rt_paint_cells")
              asm.load([Console::GBCHardware::MBC_ROM_BANK_LOW], :a)
              asm.ret
            end

            # THE LAST LINE A RUN OF +length+ TILES MAY START ON, so that it is done before the
            # blank is. The blank is lines 144 to 153, and one started on a line has the lines after
            # it, so a run that takes two lines starts on 151 at the latest. What a run costs is
            # counted from #emit_upload's instructions, generously: RUN_CYCLES for the entry and
            # the copy's set-up, TILE_CYCLES for each tile's sixteen bytes and its cell's two
            # writes. A line is LINE_CYCLES of the processor at the double speed the game runs at.
            # A game of more than one map looks its run's attributes up and writes them for every
            # run, MAP_RUN_CYCLES more a run and MAP_TILE_CYCLES more a tile.
            RUN_CYCLES = 170
            TILE_CYCLES = 40
            MAP_RUN_CYCLES = 60
            MAP_TILE_CYCLES = 8
            LINE_CYCLES = 228
            LAST_BLANK_LINE = 153
            def run_last_line(length, map_count: 1)
              run, tile = map_count > 1 ? [RUN_CYCLES + MAP_RUN_CYCLES, TILE_CYCLES + MAP_TILE_CYCLES] : [RUN_CYCLES, TILE_CYCLES]
              LAST_BLANK_LINE - ((run + (tile * length)) / LINE_CYCLES.to_f).ceil
            end

            # The cells after +cell+ in its row, short of the end of video memory's first bank and of
            # a cell drawn from another palette.
            def room_after(cell, map)
              room = COLUMNS - 1 - (cell % COLUMNS)
              room = [room, VIDEO_BANK_CELLS - 1 - cell].min if cell < VIDEO_BANK_CELLS
              (1..room).find { |on| map.fetch(cell + on) != map.fetch(cell) }&.pred || room
            end

            # The cells before +cell+ in its row, short of the start of video memory's second bank
            # and of a cell drawn from another palette.
            def room_before(cell, map)
              room = cell % COLUMNS
              room = [room, cell - VIDEO_BANK_CELLS].min if cell >= VIDEO_BANK_CELLS
              (1..room).find { |back| map.fetch(cell - back) != map.fetch(cell) }&.pred || room
            end

            # HOW TILE +cell+ IS SENT, in the order the blank writes it (#emit_upload), so the blank
            # only reads it along: the bank of work memory it is painted in, where it is there (high
            # byte first, as the console's copy takes it), its bank of video memory, where it goes
            # there; then for its cell of the grid, the cell's place, the number the grid shows the
            # tile by, and the cell's attributes (that bank, and its square's palette).
            CELL_ENTRY_BYTES = 10
            ATTRIBUTES_AT = 9
            def cell_entry(cell, map)
              h = Console::GBCHardware
              row, column = cell.divmod(COLUMNS)
              bank = BANKS.fetch(row / ROWS_A_BANK)
              in_bank = cell % CELLS_A_BANK
              from = PAINTED_AT + (in_bank * 16)
              video_bank, slot = cell < 128 ? [0, cell] : [1, cell - 128]
              to = 0x8800 + (slot * 16)
              number = (slot + 128) & 0xFF
              grid = GRID + (row * Art::GRID_CELLS) + column
              [bank, from >> 8, from & 0xFF, video_bank, to >> 8, to & 0xFF,
               grid & 0xFF, grid >> 8, number, (video_bank * h::ATTR_TILE_BANK) | map.fetch(cell)]
            end

            # rt_paint_cell: the tile pixel (D, E) is in, ready to paint: its bank of work memory in
            # view, filled with the clearing colour if it is the first paint of this generation,
            # and marked dirty — onto the dirty list, the first time. HL = the first of the
            # pixel's row's two bytes. Keeps D and E.
            #
            # rt_paint_find, the first half: the tile pixel (D, E) is in, found and nothing done to
            # it — its bank in view, HL = its state, BC = the tile. Keeps D and E.
            def emit_cell(asm, memory, quick)
              h = Console::GBCHardware
              asm.label("rt_paint_find")
              asm.load(:a, :e)
              asm.and_a(0xF8) # the row of tiles × 8, an entry of rt_paint_rows
              asm.load(:c, :a)
              asm.load(:b, 0)
              asm.load(:hl, "rt_paint_rows")
              asm.add_hl(:bc)
              asm.load(:a, [:hli])
              asm.load_high(h::SVBK, :a)
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.load(:b, :a) # BC = the row's first tile
              asm.load(:a, :d)
              3.times { asm.rrca }
              asm.and_a(0x1F) # the column of tiles
              asm.push(:af)
              asm.add_a([:hl])
              asm.inc(:hl)
              asm.push(:af)
              asm.load(:a, [:hl])
              asm.load_high(quick.bank_index, :a)
              asm.pop(:af)
              asm.load(:l, :a)
              asm.load(:h, STATE_AT >> 8) # HL = the tile's state
              asm.pop(:af)
              asm.push(:hl)
              asm.load(:l, :a)
              asm.load(:h, 0)
              4.times { asm.add_hl(:hl) }
              asm.add_hl(:bc)
              asm.load(:b, :h)
              asm.load(:c, :l) # BC = the tile
              asm.pop(:hl)
              asm.ret
              asm.label("rt_paint_cell")
              asm.call("rt_paint_find")
              asm.push(:de)
              asm.load(:a, [:hl])
              asm.and_a(~DIRTY & 0xFF)
              asm.load(:e, :a)
              asm.load_high(:a, quick.generation)
              asm.cp_a(:e)
              asm.jump_relative(:z, "rt_paint_cell_ready")
              asm.load(:e, :a)
              asm.load(:a, [:hl])
              asm.and_a(DIRTY)
              asm.or_a(:e)
              asm.load([:hl], :a) # this generation, dirty as it was
              asm.push(:hl)
              asm.load_high(:a, quick.clear_low)
              asm.load(:d, :a)
              asm.load_high(:a, quick.clear_high)
              asm.load(:e, :a)
              asm.load(:h, :b)
              asm.load(:l, :c)
              8.times do
                asm.load(:a, :d)
                asm.load([:hli], :a)
                asm.load(:a, :e)
                asm.load([:hli], :a)
              end
              asm.pop(:hl)
              asm.label("rt_paint_cell_ready")
              asm.bit(7, [:hl])
              asm.jump_relative(:nz, "rt_paint_cell_dirty")
              asm.set(7, [:hl])
              asm.load(:a, :l) # onto the dirty list: the tile in its bank, and the bank
              asm.load(:d, :a)
              asm.load_high(:a, quick.bank_index)
              asm.load(:e, :a)
              asm.push(:hl)
              asm.push(:bc)
              asm.load(:hl, memory[DIRTY_LIST])
              asm.call("rt_paint_list_add")
              asm.pop(:bc)
              asm.pop(:hl)
              asm.label("rt_paint_cell_dirty")
              asm.pop(:de)
              asm.load(:a, :e)
              asm.and_a(7)
              asm.add_a(:a)
              asm.add_a(:c)
              asm.load(:l, :a)
              asm.load(:a, :b)
              asm.adc_a(0)
              asm.load(:h, :a)
              asm.ret

              # Onto the end of the list at HL (its count, then its entries): D, the tile in its
              # bank, then E, the bank and anything said with it.
              asm.label("rt_paint_list_add")
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:a, [:hld])
              asm.load(:b, :a)
              asm.inc(:bc)
              asm.load(:a, :c)
              asm.load([:hli], :a)
              asm.load(:a, :b)
              asm.load([:hli], :a)
              asm.dec(:bc)
              asm.sla(:c)
              asm.rl(:b)
              asm.add_hl(:bc)
              asm.load(:a, :d)
              asm.load([:hli], :a)
              asm.load(:a, :e)
              asm.load([:hl], :a)
              asm.ret
            end

            # rt_paint_area(area): painting is held to +area+ from now — its left, top, right
            # and bottom a byte each, lowest first, worked out when the game was built — and the
            # area it was held to before comes back the same way, for the game to put back when
            # the drawing inside is done (Reference#exec_inside).
            def emit_area(asm, memory)
              area = memory[AREA]
              asm.label("rt_paint_area")
              asm.load_hl_sp(2)
              asm.load(:b, 4)
              asm.call("rt_take_args")
              asm.load(:hl, area)
              %i[e d c b].each do |byte|
                asm.load(:a, [:hli])
                asm.load(byte, :a)
              end
              asm.load(:hl, area)
              4.times do |i|
                asm.load_high(:a, Calls.arg(memory, 0, 1) + i)
                asm.load([:hli], :a)
              end
              asm.ret

              # A span from B up to C, held to the area: HL = the area for a span across, one on
              # for a span down. Carry set when anything of it is left.
              asm.label("rt_paint_held_to_area")
              asm.load(:a, [:hli])
              asm.cp_a(:b)
              asm.jump_relative(:c, "rt_paint_held_to_area_start")
              asm.load(:b, :a)
              asm.label("rt_paint_held_to_area_start")
              asm.inc(:hl)
              asm.load(:a, [:hl])
              asm.cp_a(:c)
              asm.jump_relative(:nc, "rt_paint_held_to_area_end")
              asm.load(:c, :a)
              asm.label("rt_paint_held_to_area_end")
              asm.load(:a, :b)
              asm.cp_a(:c)
              asm.ret
            end


            # rt_paint_clear(color): the whole screen the colour, by moving on a generation.
            # Generations count round from 0 to one short of NO_GENERATION; going round, every tile
            # is put in NO_GENERATION first, so none can be taken for this one.
            #
            # Held to an area smaller than the screen (rt_paint_area), it is the area painted
            # in the colour instead, as a rectangle (Framebuffer#clear).
            def emit_clear(asm, memory, quick)
              h = Console::GBCHardware
              asm.label("rt_paint_clear")
              asm.load_hl_sp(2)
              asm.load(:a, [:hl])
              asm.and_a(3)
              asm.load(:c, :a)
              asm.load(:hl, memory[AREA])
              WHOLE_SCREEN.each do |edge|
                asm.load(:a, [:hli])
                asm.cp_a(edge)
                asm.jump_relative(:nz, "rt_paint_clear_area")
              end
              asm.load(:a, :c)
              asm.jump_relative("rt_paint_clear_to")
              asm.label("rt_paint_clear_area")
              asm.load(:a, :c)
              asm.call("rt_paint_ink")
              asm.load(:hl, memory[AREA])
              4.times do |i|
                asm.load(:a, [:hli])
                asm.load([memory[SCRATCH] + i], :a) # rt_paint_rect's left, top, right and bottom
              end
              asm.jump("rt_paint_rect_inked")
              asm.label("rt_paint_clear_to") # A = the colour
              asm.and_a(3)
              asm.push(:af)
              asm.load(:a, 1)
              asm.load([memory[CLEARED]], :a)
              asm.pop(:af)
              asm.load_high(quick.clear, :a)
              asm.call("rt_paint_ink_bytes")
              asm.load(:a, :d)
              asm.load_high(quick.clear_low, :a)
              asm.load(:a, :e)
              asm.load_high(quick.clear_high, :a)
              asm.load_high(:a, quick.generation)
              asm.inc(:a)
              asm.cp_a(NO_GENERATION)
              asm.jump_relative(:z, "rt_paint_clear_round")
              asm.load_high(quick.generation, :a)
              asm.ret
              asm.label("rt_paint_clear_round")
              BANKS.each do |bank|
                asm.load(:a, bank)
                asm.load_high(h::SVBK, :a)
                asm.load(:hl, STATE_AT)
                asm.load(:b, CELLS_A_BANK)
                asm.label("rt_paint_clear_round_#{bank}")
                asm.load(:a, [:hl]) # dirty as it was: it is on the dirty list already
                asm.and_a(DIRTY)
                asm.or_a(NO_GENERATION)
                asm.load([:hli], :a)
                asm.dec(:b)
                asm.jump_relative(:nz, "rt_paint_clear_round_#{bank}")
              end
              asm.load(:a, 1)
              asm.load_high(h::SVBK, :a)
              asm.xor_a(:a)
              asm.load_high(quick.generation, :a)
              asm.ret

              # D, E = a tile row's two bytes all in colour A.
              asm.label("rt_paint_ink_bytes")
              asm.load(:d, 0)
              asm.load(:e, 0)
              asm.bit(0, :a)
              asm.jump_relative(:z, "rt_paint_ink_bytes_high")
              asm.dec(:d)
              asm.label("rt_paint_ink_bytes_high")
              asm.bit(1, :a)
              asm.ret(:z)
              asm.dec(:e)
              asm.ret

              # The colour being painted is A.
              asm.label("rt_paint_ink")
              asm.call("rt_paint_ink_bytes")
              asm.load(:a, :d)
              asm.load_high(quick.ink_low, :a)
              asm.load(:a, :e)
              asm.load_high(quick.ink_high, :a)
              asm.ret

              # A = the 32-bit number at HL held between nought and B, which is past the screen.
              asm.label("rt_paint_clamp")
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hl])
              asm.bit(7, :a)
              asm.jump_relative(:nz, "rt_paint_clamp_low")
              asm.or_a(:d)
              asm.or_a(:e)
              asm.jump_relative(:nz, "rt_paint_clamp_high")
              asm.load(:a, :c)
              asm.cp_a(:b)
              asm.ret(:c)
              asm.label("rt_paint_clamp_high")
              asm.load(:a, :b)
              asm.ret
              asm.label("rt_paint_clamp_low")
              asm.xor_a(:a)
              asm.ret
            end

            # rt_paint_rect(left, top, right, bottom, color): every pixel from (left, top) up to
            # but not including (right, bottom), held to the screen. A tile at a time: each tile row
            # the rectangle crosses is written as a mask of the pixels it covers there.
            def emit_rect(asm, memory, quick)
              h = Console::GBCHardware
              at = memory[SCRATCH]
              left = at
              top = at + 1
              right = at + 2
              bottom = at + 3
              x_now = at + 4
              y_now = at + 5
              y_next = at + 6
              arg = ->(i) { Calls.arg(memory, i, 5) }
              asm.label("rt_paint_rect")
              asm.load_hl_sp(2)
              asm.load(:b, 20)
              asm.call("rt_take_args")
              [[0, left, h::SCREEN_WIDTH], [1, top, h::SCREEN_HEIGHT], [2, right, h::SCREEN_WIDTH],
               [3, bottom, h::SCREEN_HEIGHT]].each do |i, to, past|
                asm.load(:hl, arg.call(i))
                asm.load(:b, past)
                asm.call("rt_paint_clamp")
                asm.load([to], :a)
              end
              asm.load_high(:a, arg.call(4))
              asm.and_a(3)
              asm.call("rt_paint_ink")
              # Held to the area, from (left, top) up to (right, bottom) in the scratch, the
              # colour being painted chosen: nothing is painted when nothing of it is left.
              asm.label("rt_paint_rect_inked")
              [[left, right, 0], [top, bottom, 1]].each do |from, to, edge|
                asm.load(:a, [from])
                asm.load(:b, :a)
                asm.load(:a, [to])
                asm.load(:c, :a)
                asm.load(:hl, memory[AREA] + edge)
                asm.call("rt_paint_held_to_area")
                asm.ret(:nc)
                asm.load(:a, :b)
                asm.load([from], :a)
                asm.load(:a, :c)
                asm.load([to], :a)
              end
              asm.load(:a, [top])
              asm.load([y_now], :a)
              asm.label("rt_paint_rect_rows")
              # This tile row's lines: from y up to the next row of tiles or the bottom.
              asm.load(:a, [y_now])
              asm.or_a(7)
              asm.inc(:a)
              asm.load(:b, :a)
              asm.load(:a, [bottom])
              asm.cp_a(:b)
              asm.jump_relative(:c, "rt_paint_rect_bottom")
              asm.load(:a, :b)
              asm.label("rt_paint_rect_bottom")
              asm.load([y_next], :a)
              asm.load(:a, [left])
              asm.load([x_now], :a)
              asm.label("rt_paint_rect_columns")
              # This tile's pixels: from x up to the next tile or the right edge.
              asm.load(:a, [x_now])
              asm.or_a(7)
              asm.inc(:a)
              asm.load(:b, :a)
              asm.load(:a, [right])
              asm.cp_a(:b)
              asm.jump_relative(:c, "rt_paint_rect_right")
              asm.load(:a, :b)
              asm.label("rt_paint_rect_right")
              asm.push(:af) # where this tile's span ends
              asm.load(:b, :a)
              asm.load(:a, [x_now])
              asm.and_a(0xF8)
              asm.load(:c, :a)
              asm.load(:a, :b)
              asm.sub_a(:c) # how far into the tile it ends: 1..8
              asm.load(:c, :a)
              asm.load(:b, 0)
              asm.load(:hl, "rt_paint_before_masks")
              asm.add_hl(:bc)
              asm.load(:a, [:hl])
              asm.push(:af)
              asm.load(:a, [x_now])
              asm.and_a(7)
              asm.load(:c, :a)
              asm.load(:hl, "rt_paint_from_masks")
              asm.add_hl(:bc)
              asm.pop(:af)
              asm.and_a([:hl])
              asm.push(:af) # the mask
              asm.load(:a, [x_now])
              asm.load(:d, :a)
              asm.load(:a, [y_now])
              asm.load(:e, :a)
              asm.call("rt_paint_cell")
              asm.pop(:af)
              asm.load(:c, :a)
              asm.load(:a, [y_next])
              asm.load(:b, :a)
              asm.load(:a, [y_now])
              asm.load(:d, :a)
              asm.load(:a, :b)
              asm.sub_a(:d)
              asm.load(:b, :a) # how many lines
              asm.load_high(:a, quick.ink_low)
              asm.load(:d, :a)
              asm.load_high(:a, quick.ink_high)
              asm.load(:e, :a)
              asm.label("rt_paint_rect_lines")
              [:d, :e].each do |ink|
                asm.load(:a, [:hl])
                asm.xor_a(ink)
                asm.and_a(:c)
                asm.xor_a([:hl])
                asm.load([:hli], :a)
              end
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_paint_rect_lines")
              asm.pop(:af)
              asm.load([x_now], :a)
              asm.load(:b, :a)
              asm.load(:a, [right])
              asm.cp_a(:b)
              asm.jump_relative(:nz, "rt_paint_rect_columns")
              asm.load(:a, [y_next])
              asm.load([y_now], :a)
              asm.load(:b, :a)
              asm.load(:a, [bottom])
              asm.cp_a(:b)
              asm.jump(:nz, "rt_paint_rect_rows")
              asm.load(:a, 1)
              asm.load_high(h::SVBK, :a)
              asm.ret
            end

            # THE ROWS OF ONE TILE A PICTURE OF ONE COLOUR COVERS, painted by rt_paint_bits_rows_N for
            # a picture N pixels to the left of the tile's edge: B rows, from the picture's byte for
            # the first at DE into the tile's row at HL. A row's eight pixels in the tile are the
            # picture's byte there and the next shifted left N, so each N has a routine of its own,
            # the shift written out N times: a loop counting the shift would cost more than the
            # painting. Each colour bit of the tile's row takes the ink's where the mask is set,
            # and keeps its own elsewhere. They end at rt_paint_bits_band_done with DE moved on
            # past the rows painted.
            #
            # And each of the four colours has its own eight, rt_paint_bits_rows_I_N for colour I:
            # a colour's bit is set where the mask is (an OR) or cleared there (an AND with the
            # mask turned over), which is one instruction a bit where mixing the colour's byte in
            # under the mask, for any colour, is three. A tile's rows are most of what painting
            # costs, and a line of text is mostly rows.
            def emit_bits_rows(asm, quick)
              steps = (0...4).flat_map { |ink| (0...8).map { |n| [ink, n, "rt_paint_bits_rows_#{ink}_#{n}"] } }
              steps.each do |ink, n, label|
                asm.label(label)
                if n.positive?
                  asm.inc(:de)
                  asm.load(:a, [:de])
                  asm.load(:c, :a) # the byte after
                  asm.dec(:de)
                end
                asm.load(:a, [:de])
                n.times do
                  asm.sla(:c)
                  asm.rla
                end
                asm.load(:c, :a)
                asm.load_high(:a, quick.bits_mask)
                asm.and_a(:c)
                asm.load(:c, :a) # the mask
                2.times do |plane|
                  if ink[plane] == 1
                    asm.load(:a, [:hl])
                    asm.or_a(:c)
                  else
                    asm.load(:a, :c)
                    asm.cpl
                    asm.and_a([:hl])
                  end
                  asm.load([:hli], :a)
                end
                asm.load_high(:a, quick.bits_stride)
                asm.add_a(:e)
                asm.load(:e, :a)
                asm.jump_relative(:nc, "#{label}_carried")
                asm.inc(:d)
                asm.label("#{label}_carried")
                asm.dec(:b)
                asm.jump_relative(:nz, label)
                asm.jump("rt_paint_bits_band_done")
              end
              asm.label("rt_paint_bits_rows") # by colour × 8 + shift
              steps.each { |_ink, _n, label| asm.data_words(label) }
            end

            # rt_paint_bits(x, y, color, bits, stride, rows): a picture of one colour, a bit a
            # pixel — a line of text, a digit, a pixel — with its top left at (x, y). The build
            # worked the bits out (GBC::Picture#bits_of): +rows+ rows of +stride+ bytes, the
            # leftmost pixel in the top bit, with a byte of nothing either side of each row so a
            # tile's eight pixels can be read from any place along it, at +bits+ in the bank of the
            # cartridge named in its third byte. Held to the screen.
            #
            # It is painted a tile at a time, down each column of tiles the picture crosses: the
            # tile is found once for the rows of it the picture covers, and each of those rows is
            # the eight bits of the picture's row that fall in the tile, written as a mask.
            def emit_bits(asm, memory, quick)
              h = Console::GBCHardware
              at = memory[SCRATCH]
              x = at        # 16 bits
              y = at + 2    # 16 bits
              stride = at + 4
              top = at + 5
              bottom = at + 6
              column = at + 7 # the column of tiles being painted
              last_column = at + 8
              shift = at + 9
              from = at + 10 # 16 bits: the picture's byte for this tile's row
              row = at + 12
              band_end = at + 13
              left = at + 14
              right = at + 15
              column_mask = at + 16 # the pixels of this column of tiles within left and right
              rows_routine = at + 17 # 16 bits: rt_paint_bits_rows_I_N for the colour and this column's shift
              ink = at + 19 # the colour, 0 to 3
              arg = ->(i) { Calls.arg(memory, i, 6) }
              asm.label("rt_paint_bits")
              asm.load_hl_sp(2)
              asm.load(:b, 24)
              asm.call("rt_take_args")
              [[0, x], [1, y]].each do |i, to|
                asm.load(:hl, arg.call(i))
                asm.call("rt_paint_fits_half")
                asm.ret(:nc)
                asm.load(:a, :e)
                asm.load([to], :a)
                asm.load(:a, :d)
                asm.load([to + 1], :a)
              end
              asm.load_high(:a, arg.call(4))
              asm.load([stride], :a)
              asm.load_high(quick.bits_stride, :a)
              # Across: from max(x, 0) to min(x + 8 × (stride - 2), 160), as columns of tiles.
              asm.sub_a(2)
              asm.load(:l, :a)
              asm.load(:h, 0)
              3.times { asm.add_hl(:hl) }
              asm.call("rt_paint_bits_span_x")
              asm.ret(:nc)
              asm.load(:hl, memory[AREA])
              asm.call("rt_paint_held_to_area")
              asm.ret(:nc)
              asm.load(:a, :c)
              asm.load([right], :a)
              asm.load(:a, :b)
              asm.load([left], :a)
              3.times { asm.srl(:a) }
              asm.load([column], :a)
              asm.load(:a, :c)
              asm.dec(:a)
              3.times { asm.srl(:a) }
              asm.load([last_column], :a)
              # Down: from max(y, 0) to min(y + rows, 144).
              asm.load_high(:a, arg.call(5))
              asm.load(:l, :a)
              asm.load_high(:a, arg.call(5) + 1)
              asm.load(:h, :a)
              asm.call("rt_paint_bits_span_y")
              asm.ret(:nc)
              asm.load(:hl, memory[AREA] + 1)
              asm.call("rt_paint_held_to_area")
              asm.ret(:nc)
              asm.load(:a, :b)
              asm.load([top], :a)
              asm.load(:a, :c)
              asm.load([bottom], :a)
              asm.load_high(:a, arg.call(2))
              asm.and_a(3)
              asm.load([ink], :a)
              asm.call("rt_paint_ink")
              # The picture's bank in view, for as long as it is read, and the game's after
              # (rt_bank_back): the build keeps them in a bank of their own.
              asm.load_high(:a, arg.call(3) + 2)
              asm.load([h::MBC_ROM_BANK_LOW], :a)

              asm.label("rt_paint_bits_column")
              # The pixels of this column of tiles from left on and before right: the from mask
              # of how far left is into it (nought in a column it began before), and the before
              # mask of how far right is (eight in a column it ends after).
              asm.load(:a, [column])
              3.times { asm.add_a(:a) }
              asm.load(:b, :a)
              asm.load(:d, 0)
              asm.load(:a, [left])
              asm.sub_a(:b)
              asm.jump_relative(:nc, "rt_paint_bits_column_from")
              asm.xor_a(:a)
              asm.label("rt_paint_bits_column_from")
              asm.load(:e, :a)
              asm.load(:hl, "rt_paint_from_masks")
              asm.add_hl(:de)
              asm.load(:a, [:hl])
              asm.load([column_mask], :a)
              asm.load(:a, [right])
              asm.sub_a(:b)
              asm.cp_a(9)
              asm.jump_relative(:c, "rt_paint_bits_column_before")
              asm.load(:a, 8)
              asm.label("rt_paint_bits_column_before")
              asm.load(:e, :a)
              asm.load(:hl, "rt_paint_before_masks")
              asm.add_hl(:de)
              asm.load(:a, [column_mask])
              asm.and_a([:hl])
              asm.load([column_mask], :a)
              # o = 8 × column - x: the picture's pixel at this tile's left edge (-7 up). Its byte
              # is o ÷ 8 + 1 along the padded row, and its place in that byte o mod 8.
              asm.load(:a, [column])
              asm.load(:l, :a)
              asm.load(:h, 0)
              3.times { asm.add_hl(:hl) }
              asm.load(:a, [x])
              asm.load(:e, :a)
              asm.load(:a, [x + 1])
              asm.load(:d, :a)
              asm.load(:a, :l)
              asm.sub_a(:e)
              asm.load(:l, :a)
              asm.load(:a, :h)
              asm.sbc_a(:d)
              asm.load(:h, :a)
              asm.load(:a, :l)
              asm.and_a(7)
              asm.load([shift], :a)
              3.times do
                asm.sra(:h)
                asm.rr(:l)
              end
              asm.inc(:hl) # past the byte of nothing on the left
              asm.load_high(:a, arg.call(3))
              asm.load(:e, :a)
              asm.load_high(:a, arg.call(3) + 1)
              asm.load(:d, :a)
              asm.add_hl(:de)
              # ...and down to the first row painted: (top - y) rows of +stride+ bytes.
              asm.load(:a, [y])
              asm.load(:b, :a)
              asm.load(:a, [top])
              asm.sub_a(:b) # top - y: from nought up, top being where y is or below it
              asm.load(:b, :a)
              asm.load(:a, [stride])
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.inc(:b)
              asm.jump_relative("rt_paint_bits_down_next")
              asm.label("rt_paint_bits_down")
              asm.add_hl(:de)
              asm.label("rt_paint_bits_down_next")
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_paint_bits_down")
              asm.load(:a, :l)
              asm.load([from], :a)
              asm.load(:a, :h)
              asm.load([from + 1], :a)
              asm.load(:a, [top])
              asm.load([row], :a)
              # The rows of this column are painted by the routine for the colour and its shift, and
              # with its mask.
              asm.load(:a, [ink])
              3.times { asm.add_a(:a) }
              asm.load(:e, :a)
              asm.load(:a, [shift])
              asm.add_a(:e)
              asm.add_a(:a)
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.load(:hl, "rt_paint_bits_rows")
              asm.add_hl(:de)
              asm.load(:a, [:hli])
              asm.load([rows_routine], :a)
              asm.load(:a, [:hl])
              asm.load([rows_routine + 1], :a)
              asm.load(:a, [column_mask])
              asm.load_high(quick.bits_mask, :a)

              asm.label("rt_paint_bits_band")
              asm.load(:a, [row])
              asm.or_a(7)
              asm.inc(:a)
              asm.load(:b, :a)
              asm.load(:a, [bottom])
              asm.cp_a(:b)
              asm.jump_relative(:c, "rt_paint_bits_band_end")
              asm.load(:a, :b)
              asm.label("rt_paint_bits_band_end")
              asm.load([band_end], :a)
              asm.load(:a, [column])
              3.times { asm.add_a(:a) }
              asm.load(:d, :a)
              asm.load(:a, [row])
              asm.load(:e, :a)
              asm.call("rt_paint_cell")
              # B = the rows of the band, and the row moves on past them; then the column's
              # routine paints them, from the picture's byte for the first (DE).
              asm.load(:a, [row])
              asm.load(:c, :a)
              asm.load(:a, [band_end])
              asm.load([row], :a)
              asm.sub_a(:c)
              asm.load(:b, :a)
              asm.load(:a, [rows_routine])
              asm.load(:e, :a)
              asm.load(:a, [rows_routine + 1])
              asm.load(:d, :a)
              asm.push(:de)
              asm.load(:a, [from])
              asm.load(:e, :a)
              asm.load(:a, [from + 1])
              asm.load(:d, :a)
              asm.ret # into the routine pushed
              asm.label("rt_paint_bits_band_done")
              asm.load(:a, :e)
              asm.load([from], :a)
              asm.load(:a, :d)
              asm.load([from + 1], :a)
              asm.load(:a, [row])
              asm.load(:b, :a)
              asm.load(:a, [bottom])
              asm.cp_a(:b)
              asm.jump(:nz, "rt_paint_bits_band")
              asm.load(:a, [last_column])
              asm.load(:b, :a)
              asm.load(:a, [column])
              asm.cp_a(:b)
              asm.jump_relative(:z, "rt_paint_bits_done")
              asm.inc(:a)
              asm.load([column], :a)
              asm.jump("rt_paint_bits_column")
              asm.label("rt_paint_bits_done")
              asm.load(:a, 1)
              asm.load_high(h::SVBK, :a)
              asm.jump("rt_bank_back")

              emit_bits_rows(asm, quick)

              # A span on the screen: from the 16-bit place at +start+ for HL pixels, held to
              # 0..+past+. B = its first pixel, C = one past its last, carry set when anything of
              # it is on the screen.
              [["rt_paint_bits_span_x", x, h::SCREEN_WIDTH], ["rt_paint_bits_span_y", y, h::SCREEN_HEIGHT]].each do |name, start, past|
                asm.label(name)
                asm.load(:a, [start])
                asm.load(:e, :a)
                asm.load(:a, [start + 1])
                asm.load(:d, :a)
                asm.add_hl(:de) # HL = the end
                # The end at or before nought, or the start at or past the edge: nothing shows.
                asm.bit(7, :h)
                asm.jump_relative(:nz, "#{name}_none")
                asm.load(:a, :h)
                asm.or_a(:l)
                asm.jump_relative(:z, "#{name}_none")
                asm.load(:c, past)
                asm.load(:a, :h)
                asm.and_a(:a)
                asm.jump_relative(:nz, "#{name}_end_held")
                asm.load(:a, :l)
                asm.cp_a(past)
                asm.jump_relative(:nc, "#{name}_end_held")
                asm.load(:c, :a)
                asm.label("#{name}_end_held")
                asm.bit(7, :d)
                asm.load(:b, 0)
                asm.jump_relative(:nz, "#{name}_start_held")
                asm.load(:a, :d)
                asm.and_a(:a)
                asm.jump_relative(:nz, "#{name}_none")
                asm.load(:a, :e)
                asm.cp_a(past)
                asm.jump_relative(:nc, "#{name}_none")
                asm.load(:b, :a)
                asm.label("#{name}_start_held")
                asm.scf
                asm.ret
                asm.label("#{name}_none")
                asm.and_a(:a)
                asm.ret
              end

              # Carry set when the 32-bit number at HL fits 16 signed bits, which are then DE.
              asm.label("rt_paint_fits_half")
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.rla
              asm.sbc_a(:a)
              asm.load(:c, :a)
              2.times do
                asm.load(:a, [:hli])
                asm.cp_a(:c)
                asm.jump_relative(:nz, "rt_paint_fits_half_not")
              end
              asm.scf
              asm.ret
              asm.label("rt_paint_fits_half_not")
              asm.and_a(:a)
              asm.ret
            end

            # A PATCH OF THE PICTURE KEPT AND PUT BACK — what a sprite drawn on a painted screen
            # covers, kept as it is drawn and put back before it is drawn somewhere else
            # (Reference#exec_save_region, #exec_restore_region).
            #
            # rt_paint_save(patch, width, height, x, y) keeps the +width+ × +height+ pixels with
            # their top left at (x, y) in the patch's memory (the address of a list's storage, whose
            # slots start past its header), a byte a pixel across each row: the pixel's colour, one
            # up, or nought for a pixel off the screen, which has nothing to keep. Work memory starts
            # cleared, so a patch never kept has nothing in it to put back.
            #
            # rt_paint_restore(patch, width, height, x, y) paints them back with their top left
            # at (x, y), every one but those with nothing kept, held to the area.
            def emit_patches(asm, memory, quick)
              h = Console::GBCHardware
              at = memory[SCRATCH]
              patch = at   # 16 bits: the patch's next byte
              width = at + 2
              height = at + 3
              x = at + 4   # 16 bits
              y = at + 6   # 16 bits
              row = at + 8
              column = at + 9
              across = at + 10 # 16 bits: the pixel's place across the screen
              down = at + 12   # 16 bits: ...and down
              kept = at + 14
              arg = ->(i) { Calls.arg(memory, i, 5) }
              %w[save restore].each do |which|
                asm.label("rt_paint_#{which}")
                asm.load_hl_sp(2)
                asm.load(:b, 20)
                asm.call("rt_take_args")
                asm.load_high(:a, arg.call(0))
                asm.load(:e, :a)
                asm.load_high(:a, arg.call(0) + 1)
                asm.load(:d, :a)
                asm.load(:hl, Lists::HEADER)
                asm.add_hl(:de)
                asm.load(:a, :l)
                asm.load([patch], :a)
                asm.load(:a, :h)
                asm.load([patch + 1], :a)
                [[1, width], [2, height]].each do |i, to|
                  asm.load_high(:a, arg.call(i))
                  asm.load([to], :a)
                  asm.and_a(:a)
                  asm.ret(:z) # no pixels at all
                end
                # A place too far off to fit 16 bits is off the screen, and so is every pixel near it.
                [[3, x], [4, y]].each do |i, to|
                  asm.load(:hl, arg.call(i))
                  asm.call("rt_paint_fits_half")
                  asm.jump_relative(:c, "rt_paint_#{which}_fits_#{i}")
                  asm.load(:de, 0x4000)
                  asm.label("rt_paint_#{which}_fits_#{i}")
                  asm.load(:a, :e)
                  asm.load([to], :a)
                  asm.load(:a, :d)
                  asm.load([to + 1], :a)
                end
                asm.xor_a(:a)
                asm.load([row], :a)
                asm.label("rt_paint_#{which}_row")
                patch_place(asm, y, row, down)
                asm.xor_a(:a)
                asm.load([column], :a)
                asm.label("rt_paint_#{which}_column")
                patch_place(asm, x, column, across)
                which == "save" ? emit_patch_keep(asm, patch) : emit_patch_put_back(asm, memory, quick, patch, kept)
                asm.label("rt_paint_#{which}_next")
                [[column, width, "column"], [row, height, "row"]].each do |count, limit, back|
                  asm.load(:a, [count])
                  asm.inc(:a)
                  asm.load([count], :a)
                  asm.load(:b, :a)
                  asm.load(:a, [limit])
                  asm.cp_a(:b)
                  asm.jump(:nz, "rt_paint_#{which}_#{back}")
                end
                asm.load(:a, 1)
                asm.load_high(h::SVBK, :a)
                asm.ret
              end

              # D, E = the pixel (across, down), and carry set when it is on the screen.
              asm.label("rt_paint_patch_on_screen")
              asm.load(:a, [across + 1])
              asm.and_a(:a)
              asm.ret(:nz)
              asm.load(:a, [down + 1])
              asm.and_a(:a)
              asm.ret(:nz)
              asm.load(:a, [down])
              asm.load(:e, :a)
              asm.cp_a(h::SCREEN_HEIGHT)
              asm.ret(:nc)
              asm.load(:a, [across])
              asm.load(:d, :a)
              asm.cp_a(h::SCREEN_WIDTH)
              asm.ret

              # C = pixel D's bit in its tile's row: the top bit for the leftmost.
              asm.label("rt_paint_bit")
              asm.load(:a, :d)
              asm.and_a(7)
              asm.load(:b, :a)
              asm.inc(:b)
              asm.load(:c, 0x80)
              asm.jump_relative("rt_paint_bit_next")
              asm.label("rt_paint_bit_shift")
              asm.srl(:c)
              asm.label("rt_paint_bit_next")
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_paint_bit_shift")
              asm.ret

              # A = the colour of pixel (D, E) as painted: the clearing colour throughout a tile last
              # painted in an earlier generation.
              asm.label("rt_paint_read")
              asm.call("rt_paint_find")
              asm.load(:a, [:hl])
              asm.and_a(~DIRTY & 0xFF)
              asm.load(:l, :a)
              asm.load_high(:a, quick.generation)
              asm.cp_a(:l)
              asm.jump_relative(:z, "rt_paint_read_painted")
              asm.load_high(:a, quick.clear)
              asm.ret
              asm.label("rt_paint_read_painted")
              asm.load(:a, :e)
              asm.and_a(7)
              asm.add_a(:a)
              asm.add_a(:c)
              asm.load(:l, :a)
              asm.load(:a, :b)
              asm.adc_a(0)
              asm.load(:h, :a)
              asm.call("rt_paint_bit")
              asm.load(:b, 0)
              asm.load(:a, [:hli])
              asm.and_a(:c)
              asm.jump_relative(:z, "rt_paint_read_high")
              asm.inc(:b)
              asm.label("rt_paint_read_high")
              asm.load(:a, [:hl])
              asm.and_a(:c)
              asm.jump_relative(:z, "rt_paint_read_done")
              asm.inc(:b)
              asm.inc(:b)
              asm.label("rt_paint_read_done")
              asm.load(:a, :b)
              asm.ret
            end

            # The 16-bit place at +to+: the one at +start+ and the byte at +by+ on from it.
            def patch_place(asm, start, by, to)
              asm.load(:a, [by])
              asm.load(:c, :a)
              asm.load(:b, 0)
              asm.load(:a, [start])
              asm.load(:l, :a)
              asm.load(:a, [start + 1])
              asm.load(:h, :a)
              asm.add_hl(:bc)
              asm.load(:a, :l)
              asm.load([to], :a)
              asm.load(:a, :h)
              asm.load([to + 1], :a)
            end

            # The patch's next byte is this pixel's colour, one up, or nought off the screen. The
            # patch may be in the banked half of work memory, so bank 1 is put back in view first.
            def emit_patch_keep(asm, patch)
              h = Console::GBCHardware
              asm.call("rt_paint_patch_on_screen")
              asm.load(:a, 0)
              asm.jump_relative(:nc, "rt_paint_keep_byte")
              asm.call("rt_paint_read")
              asm.inc(:a)
              asm.label("rt_paint_keep_byte")
              asm.load(:c, :a)
              asm.load(:a, 1)
              asm.load_high(h::SVBK, :a)
              patch_byte(asm, patch) { asm.load(:a, :c); asm.load([:hli], :a) }
            end

            # The patch's next byte painted back, if anything was kept there and its pixel is on the
            # screen and in the area.
            def emit_patch_put_back(asm, memory, quick, patch, kept)
              h = Console::GBCHardware
              asm.load(:a, 1)
              asm.load_high(h::SVBK, :a)
              patch_byte(asm, patch) do
                asm.load(:a, [:hli])
                asm.load([kept], :a)
              end
              asm.load(:a, [kept])
              asm.and_a(:a)
              asm.jump(:z, "rt_paint_restore_next")
              asm.call("rt_paint_patch_on_screen")
              asm.jump(:nc, "rt_paint_restore_next")
              asm.load(:hl, memory[AREA])
              [[:d, :c], [:e, :c], [:d, :nc], [:e, :nc]].each_with_index do |(pixel, outside), i|
                asm.inc(:hl) unless i.zero?
                asm.load(:a, pixel)
                asm.cp_a([:hl])
                asm.jump(outside, "rt_paint_restore_next")
              end
              asm.push(:de)
              asm.load(:a, [kept])
              asm.dec(:a)
              asm.call("rt_paint_ink")
              asm.pop(:de)
              asm.call("rt_paint_cell")
              asm.call("rt_paint_bit")
              asm.load_high(:a, quick.ink_low)
              asm.load(:d, :a)
              asm.load_high(:a, quick.ink_high)
              asm.load(:e, :a)
              [:d, :e].each do |ink|
                asm.load(:a, [:hl])
                asm.xor_a(ink)
                asm.and_a(:c)
                asm.xor_a([:hl])
                asm.load([:hli], :a)
              end
            end

            # The block's work with HL = the patch's next byte, and the place after it kept.
            def patch_byte(asm, patch)
              asm.load(:a, [patch])
              asm.load(:l, :a)
              asm.load(:a, [patch + 1])
              asm.load(:h, :a)
              yield
              asm.load(:a, :l)
              asm.load([patch], :a)
              asm.load(:a, :h)
              asm.load([patch + 1], :a)
            end

            # THE END OF A PASS: what has to go to the console, listed (LIST). Only tiles something
            # happened to are looked at:
            #
            # - After a clear, every tile showing a picture of its own (OWN_LIST) that was not
            #   painted again since is the clearing colour throughout, and its cell is pointed at
            #   the clear tile. Every other cell shows the clear tile already, so a clear in
            #   another colour is the clear tile rewritten in it.
            # - Every tile painted since (DIRTY_LIST) is held against the copy last sent, and sent
            #   if it differs, or if its cell shows a single colour now.
            def emit_scan(asm, memory, quick)
              h = Console::GBCHardware
              asm.label("rt_paint_scan")
              asm.load(:a, [memory[SCREEN_KIND]])
              asm.cp_a(PAINTED)
              asm.ret(:nz)
              asm.call("rt_paint_list_open")
              asm.load(:a, [memory[CLEARED]])
              asm.and_a(:a)
              asm.jump(:z, "rt_paint_scan_dirty")
              asm.xor_a(:a)
              asm.load([memory[CLEARED]], :a)
              asm.load_high(:a, quick.clear)
              asm.load(:hl, memory[LAST_SOLID])
              asm.cp_a([:hl])
              asm.jump(:z, "rt_paint_scan_own")
              asm.load([:hl], :a)
              # A clear in another colour: every cell not showing its own tile shows the clear tile,
              # so the clear tile takes the colour, one entry for the whole screen. A tile painted
              # since the clear is sent as its own picture below, in the same blanks.
              asm.swap(:a)
              asm.or_a(SOLID)
              asm.load(:c, CLEAR_TILE_ENTRY)
              asm.call("rt_paint_send")

              # Every tile showing its own picture: kept if it was painted since the clear, pointed
              # at the clearing colour if not. The list is walked with its place in HL, what is left
              # of it in BC, and where the next one kept goes in DE, each pushed round the tile's
              # work, so a tile costs a few instructions besides what is done with it; the ones kept
              # are written back over the list as it is read.
              asm.label("rt_paint_scan_own")
              asm.load(:hl, memory[OWN_LIST])
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.load(:b, :a)
              asm.load(:d, :h)
              asm.load(:e, :l)
              asm.label("rt_paint_scan_own_entry")
              asm.load(:a, :b)
              asm.or_a(:c)
              asm.jump_relative(:z, "rt_paint_scan_own_done")
              asm.dec(:bc)
              asm.push(:bc)
              asm.push(:de)
              emit_list_entry(asm)
              asm.call("rt_paint_state_now")
              asm.jump_relative(:z, "rt_paint_scan_own_keep") # painted in this generation
              asm.call("rt_paint_point_at_clear")
              asm.pop(:hl)
              asm.pop(:de)
              asm.jump_relative("rt_paint_scan_own_next")
              asm.label("rt_paint_scan_own_keep")
              asm.load(:a, :e)
              asm.pop(:hl)
              asm.pop(:de)
              asm.load(:b, :a)
              asm.load(:a, :c)
              asm.load([:de], :a)
              asm.inc(:de)
              asm.load(:a, :b)
              asm.load([:de], :a)
              asm.inc(:de)
              asm.label("rt_paint_scan_own_next")
              asm.pop(:bc)
              asm.jump_relative("rt_paint_scan_own_entry")
              asm.label("rt_paint_scan_own_done") # how many were kept: from the list's start to DE
              first = memory[OWN_LIST] + 2
              asm.load(:a, :e)
              asm.sub_a(first & 0xFF)
              asm.load(:l, :a)
              asm.load(:a, :d)
              asm.sbc_a(first >> 8)
              asm.srl(:a)
              asm.load([memory[OWN_LIST] + 1], :a)
              asm.load(:a, :l)
              asm.rra
              asm.load([memory[OWN_LIST]], :a)

              # Every tile painted since the pass before, walked the same way. Most of a picture
              # painted again is the same as it was sent and its cell shows it, which is held
              # against the copy sent here, with nothing called.
              asm.label("rt_paint_scan_dirty")
              asm.load(:hl, memory[DIRTY_LIST])
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.load(:b, :a)
              asm.label("rt_paint_scan_dirty_entry")
              asm.load(:a, :b)
              asm.or_a(:c)
              asm.jump(:z, "rt_paint_scan_dirty_done")
              asm.dec(:bc)
              asm.push(:bc)
              emit_list_entry(asm)
              asm.call("rt_paint_state_now")
              asm.res(7, [:hl]) # no longer dirty, whatever comes of it
              asm.jump(:nz, "rt_paint_scan_dirty_next") # cleared since: the clear saw to it
              asm.push(:de)
              emit_tile_pair(asm)
              # A tile is sixteen bytes from an address that is a multiple of sixteen, so only the
              # low byte of each address moves along it.
              16.times do
                asm.load(:a, [:de])
                asm.cp_a([:hl])
                asm.jump_relative(:nz, "rt_paint_scan_dirty_changed")
                asm.inc(:e)
                asm.inc(:l)
              end
              asm.pop(:de)
              # As sent: it goes only if its cell shows a colour.
              asm.call("rt_paint_shown_at")
              asm.load(:a, [:hl])
              asm.cp_a(OWN)
              asm.jump_relative(:z, "rt_paint_scan_dirty_next")
              asm.jump_relative("rt_paint_scan_dirty_new_cell")
              asm.label("rt_paint_scan_dirty_changed") # the tile as painted is the copy sent from now
              asm.pop(:de)
              asm.push(:de)
              emit_tile_pair(asm)
              16.times do
                asm.load(:a, [:hli])
                asm.load([:de], :a)
                asm.inc(:e)
              end
              asm.pop(:de)
              asm.call("rt_paint_shown_at")
              asm.load(:a, [:hl])
              asm.cp_a(OWN)
              asm.jump_relative(:nz, "rt_paint_scan_dirty_new_cell")
              asm.load(:a, :e)
              asm.or_a(KEEPS_CELL)
              asm.call("rt_paint_send")
              asm.jump_relative("rt_paint_scan_dirty_next")
              asm.label("rt_paint_scan_dirty_new_cell")
              asm.call("rt_paint_send_own")
              asm.call("rt_paint_shown_at")
              asm.load([:hl], OWN)
              push_keeping(asm) do
                asm.load(:d, :c)
                asm.load(:hl, memory[OWN_LIST])
                asm.call("rt_paint_list_add")
              end
              asm.label("rt_paint_scan_dirty_next")
              asm.pop(:hl)
              asm.pop(:bc)
              asm.jump("rt_paint_scan_dirty_entry")

              asm.label("rt_paint_scan_dirty_done")
              asm.xor_a(:a)
              asm.load(:hl, memory[DIRTY_LIST])
              asm.load([:hli], :a)
              asm.load([:hl], :a)
              # LIST_END after the last entry to send.
              asm.load(:hl, memory[LIST])
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.load(:b, :a)
              asm.sla(:c)
              asm.rl(:b)
              asm.add_hl(:bc)
              asm.inc(:hl)
              asm.load([:hl], LIST_END)
              asm.load(:a, 1)
              asm.load_high(h::SVBK, :a)
              asm.ret

              # The list to send emptied: nothing on it but its end, and the blank at its start.
              # A = nought after.
              asm.label("rt_paint_list_open")
              asm.load(:hl, memory[LIST])
              asm.xor_a(:a)
              3.times { asm.load([:hli], :a) }
              asm.load([:hl], LIST_END)
              asm.load(:a, (memory[LIST] + 2) & 0xFF)
              asm.load([memory[LIST_DONE]], :a)
              asm.load(:a, (memory[LIST] + 2) >> 8)
              asm.load([memory[LIST_DONE] + 1], :a)
              asm.load(:a, NO_BANK) # no run yet for a cell to join
              [0, RUN_BYTES].each { |run| asm.load([memory[RUNS] + run + RUN_BANK], :a) }
              asm.xor_a(:a)
              asm.ret

              # Tile C of bank E's bank in view, HL = its state, and Z when it was painted in this
              # generation.
              asm.label("rt_paint_state_now")
              asm.load(:a, :e)
              asm.add_a(BANKS.first)
              asm.load_high(h::SVBK, :a)
              asm.load(:h, STATE_AT >> 8)
              asm.load(:l, :c)
              asm.load(:a, [:hl])
              asm.and_a(~DIRTY & 0xFF)
              asm.load(:b, :a)
              asm.load_high(:a, quick.generation)
              asm.cp_a(:b)
              asm.ret

              # Tile C of bank E shows the clearing colour from now: its cell pointed at it.
              asm.label("rt_paint_point_at_clear")
              asm.call("rt_paint_shown_at")
              asm.load_high(:a, quick.clear)
              asm.load([:hl], :a)
              asm.swap(:a)
              asm.or_a(SOLID)
              asm.or_a(:e)
              asm.jump_relative("rt_paint_send")

              # Tile C of bank E is sent as it is painted, and its cell pointed at it.
              asm.label("rt_paint_send_own")
              asm.load(:a, :e)
              emit_send(asm, memory)

              # HL = what tile C of the bank in view shows now.
              asm.label("rt_paint_shown_at")
              asm.load(:a, SHOWN_AT & 0xFF)
              asm.add_a(:c)
              asm.load(:l, :a)
              asm.load(:h, SHOWN_AT >> 8)
              asm.ret
            end

            # rt_paint_send: A = the bank, and SOLID and a colour for a single colour, or
            # KEEPS_CELL; C = the tile in its bank, or CLEAR_TILE_ENTRY for the clear tile
            # rewritten in the colour. Onto the list to send: added to either end of the last run,
            # or of the one before it, when the cell is next to it along its row and sent the same
            # way; a run of its own when not. Keeps BC and DE.
            #
            # Two runs, because two rows of text are painted a column at a time, down both rows,
            # so a row's runs are taken in turn; either end, because a menu's cursor is painted
            # after the words just to its right. Each run is kept (RUNS) as the scan has its
            # tiles, a tile and its bank, so that whether a tile is next to it is a byte or two
            # compared: the tile after its last and the tile before its first, how many more cells
            # its row has room for after it and before it (#emit_tables's rt_paint_room_after
            # and rt_paint_room_before), and its entry's place.
            RUN_NEXT = 0
            RUN_BANK = 1
            RUN_ROOM_AFTER = 2
            RUN_BEFORE = 3
            RUN_ROOM_BEFORE = 4
            RUN_ENTRY = 5
            RUN_BYTES = 7
            def emit_send(asm, memory)
              last = memory[RUNS]
              before_last = last + RUN_BYTES
              asm.label("rt_paint_send")
              push_keeping(asm) do
                asm.load(:b, :a)
                asm.and_a(3)
                asm.load(:d, :a) # the bank
                asm.load(:a, :c)
                asm.cp_a(CLEAR_TILE_ENTRY)
                asm.jump_relative(:nz, "rt_paint_send_cell")
                asm.load(:a, :b)
                asm.swap(:a)
                asm.and_a(3)
                asm.load(:d, :a)
                asm.load(:e, SENDS_CLEAR_TILE)
                asm.load(:hl, memory[LIST])
                asm.call("rt_paint_list_add")
                asm.jump("rt_paint_send_done")
                asm.label("rt_paint_send_cell")
                asm.load(:a, :b)
                asm.and_a(SENDS_SOLID | SENDS_KEEPING_CELL) # the same bits as SOLID and KEEPS_CELL
                asm.load(:b, :a) # what is sent
                [last, before_last].each_with_index do |run, i|
                  emit_run_grows_after(asm, run, "rt_paint_send_after_#{i}")
                  emit_run_grows_before(asm, run, "rt_paint_send_before_#{i}")
                end
                emit_run_begins(asm, memory, last, before_last)
                asm.label("rt_paint_send_done")
              end
              asm.ret
            end

            # Tile C of bank D carries on +run+ past its last cell, when it is the tile after that
            # cell, there is room, and it is sent as the run is (B): the run is a cell longer.
            def emit_run_grows_after(asm, run, label)
              asm.load(:hl, run + RUN_NEXT)
              asm.load(:a, [:hli])
              asm.cp_a(:c)
              asm.jump_relative(:nz, label)
              asm.load(:a, [:hli])
              asm.cp_a(:d)
              asm.jump_relative(:nz, label)
              asm.load(:a, [:hl])
              asm.and_a(:a)
              asm.jump_relative(:z, label)
              emit_compare_entry_kind(asm, run)
              asm.jump_relative(:nz, label)
              asm.load(:a, [:hl])
              asm.add_a(1 << RUN_LENGTH_SHIFT)
              asm.load([:hl], :a)
              asm.load(:hl, run + RUN_ROOM_AFTER)
              asm.dec([:hl])
              asm.load(:hl, run + RUN_NEXT)
              asm.inc([:hl])
              asm.jump("rt_paint_send_done")
              asm.label(label)
            end

            # Tile C of bank D comes before +run+'s first cell, when it is the tile before that cell,
            # there is room, and it is sent as the run is (B): the run starts a cell sooner.
            def emit_run_grows_before(asm, run, label)
              asm.load(:hl, run + RUN_BEFORE)
              asm.load(:a, [:hli])
              asm.cp_a(:c)
              asm.jump_relative(:nz, label)
              asm.load(:a, [:hl])
              asm.and_a(:a)
              asm.jump_relative(:z, label)
              asm.load(:a, [run + RUN_BANK])
              asm.cp_a(:d)
              asm.jump_relative(:nz, label)
              emit_compare_entry_kind(asm, run)
              asm.jump_relative(:nz, label)
              # The first cell one less — its top bit is the second byte's lowest, so the borrow
              # carries into it — and the run a cell longer.
              asm.dec(:hl)
              asm.load(:a, [:hl])
              asm.sub_a(1)
              asm.load([:hli], :a)
              asm.load(:a, [:hl])
              asm.sbc_a(0)
              asm.add_a(1 << RUN_LENGTH_SHIFT)
              asm.load([:hl], :a)
              asm.load(:hl, run + RUN_ROOM_BEFORE)
              asm.dec([:hl])
              asm.load(:hl, run + RUN_BEFORE)
              asm.dec([:hl])
              asm.jump("rt_paint_send_done")
              asm.label(label)
            end

            # HL = +run+'s entry's second byte, and Z when what it sends is B.
            def emit_compare_entry_kind(asm, run)
              asm.load(:hl, run + RUN_ENTRY)
              asm.load(:a, [:hli])
              asm.load(:h, [:hl])
              asm.load(:l, :a)
              asm.inc(:hl)
              asm.load(:a, [:hl])
              asm.and_a(SENDS_SOLID | SENDS_KEEPING_CELL)
              asm.cp_a(:b)
            end

            # Tile C of bank D is a run of its own, the last from now, and the last run before it
            # the one before.
            def emit_run_begins(asm, memory, last, before_last)
              asm.push(:de)
              asm.load(:hl, last)
              asm.load(:de, before_last)
              RUN_BYTES.times do
                asm.load(:a, [:hli])
                asm.load([:de], :a)
                asm.inc(:de)
              end
              asm.pop(:de)
              asm.load(:a, :d)
              # HL = the cell's number: the tile's on from its bank's first cell.
              asm.load(:l, :c)
              asm.load(:h, 0)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_paint_send_numbered")
              asm.push(:de)
              asm.load(:de, CELLS_A_BANK)
              asm.add_hl(:de)
              asm.dec(:a)
              asm.jump_relative(:z, "rt_paint_send_numbered_pop")
              asm.add_hl(:de)
              asm.label("rt_paint_send_numbered_pop")
              asm.pop(:de)
              asm.label("rt_paint_send_numbered")
              asm.push(:hl)
              # The entry, at the list's next place, and the list one longer.
              asm.push(:de)
              asm.load(:hl, memory[LIST])
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hld])
              asm.load(:d, :a)
              asm.inc(:de)
              asm.load(:a, :e)
              asm.load([:hli], :a)
              asm.load(:a, :d)
              asm.load([:hl], :a)
              asm.dec(:de)
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.add_hl(:hl)
              asm.load(:de, memory[LIST] + 2)
              asm.add_hl(:de)
              asm.load(:a, :l)
              asm.load([last + RUN_ENTRY], :a)
              asm.load(:a, :h)
              asm.load([last + RUN_ENTRY + 1], :a)
              asm.pop(:de)
              asm.pop(:hl) # the cell's number again; the entry's place is in the run
              push_keeping(asm) do
                asm.load(:a, [last + RUN_ENTRY])
                asm.load(:e, :a)
                asm.load(:a, [last + RUN_ENTRY + 1])
                asm.load(:d, :a)
                asm.load(:a, :l)
                asm.load([:de], :a)
                asm.inc(:de)
                asm.load(:a, :h)
                asm.or_a(:b)
                asm.load([:de], :a)
              end
              # The run: the tiles either side of it, its bank, and its row's room either side.
              asm.load(:a, :c)
              asm.inc(:a)
              asm.load([last + RUN_NEXT], :a)
              asm.sub_a(2)
              asm.load([last + RUN_BEFORE], :a)
              asm.load(:a, :d)
              asm.load([last + RUN_BANK], :a)
              asm.call("rt_paint_tables_in_view")
              asm.push(:hl)
              asm.load(:de, "rt_paint_room_after")
              asm.add_hl(:de)
              asm.load(:a, [:hl])
              asm.load([last + RUN_ROOM_AFTER], :a)
              asm.pop(:hl)
              asm.load(:de, "rt_paint_room_before")
              asm.add_hl(:de)
              asm.load(:a, [:hl])
              asm.load([last + RUN_ROOM_BEFORE], :a)
              asm.call("rt_bank_back")
            end

            # HL = tile C of the bank in view as painted, DE = as last sent: C × 16 on from each.
            # The swap puts C's low four bits above its high four, which are the two bytes of C × 16.
            def emit_tile_pair(asm)
              asm.load(:a, :c)
              asm.swap(:a)
              asm.load(:b, :a)
              asm.and_a(0xF0)
              asm.load(:l, :a)
              asm.load(:a, :b)
              asm.and_a(0x0F)
              asm.add_a(PAINTED_AT >> 8)
              asm.load(:h, :a)
              asm.load(:a, :l)
              asm.add_a((SENT_AT - PAINTED_AT) & 0xFF)
              asm.load(:e, :a)
              asm.load(:a, :h)
              asm.adc_a((SENT_AT - PAINTED_AT) >> 8)
              asm.load(:d, :a)
            end

            # The next entry of a list being walked, HL its place: C = the tile in its bank, E = the
            # bank's number among BANKS, and the place after it pushed.
            def emit_list_entry(asm)
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.push(:hl)
              asm.and_a(3)
              asm.load(:e, :a)
            end

            # The block's work with BC and DE kept round it (the flags are the block's).
            def push_keeping(asm)
              asm.push(:bc)
              asm.push(:de)
              yield
              asm.pop(:de)
              asm.pop(:bc)
            end

            # IN THE BLANK: the list, from where it got to, for as long as the blank lasts. A run
            # of tiles of their own is copied by the console's own copy, all of it at once, and
            # their cells pointed at them unless they are already (SENDS_KEEPING_CELL); a run of
            # single colours is its cells pointed at the clear tile, and SENDS_CLEAR_TILE the
            # clear tile rewritten. Carry set when some of it is left for the next blank.
            #
            # The blank is the ten lines from 144 to 153, and the sprite table and the rest of the
            # picture go first, so what is left of it is a handful of runs: each run's tiles' entry
            # of rt_paint_cells is read straight along (#cell_entry), and its place on the list is
            # kept in HL the while.
            #
            # A run starts only if it can be done before the blank is: on a line no later than
            # its length's last line (#run_last_line). And never while the line counter reads
            # less than 144 with the screen on — not even nought, which it reads for nearly all of
            # line 153, the blank's last, as well as at the top of the screen. With the screen off
            # the counter reads nought and the whole list goes now.
            # rt_paint_map(n): the scene arriving shows map +n+ of the screen's squares (Art#square_maps)
            # from now: each run the blank sends writes its cells' attributes from it.
            #
            # A cell whose palette is another in this map is marked STALE, as showing neither its
            # own tile nor a colour, so the next time its tile is painted it is sent with its cell,
            # in this map's palette, even when the tile is painted exactly as it was: a colour keeps
            # its place in every palette, so the same tile in another scene can be other colours. A
            # cell not painted again keeps the palette it has, which shows its tile as it was
            # painted, and the colour the screen is cleared to, which every palette holds.
            #
            # rt_paint_map_first is the first map, the one shown before any scene. Nothing for a
            # game of one map, whose cells keep the palettes they are given at power-on.
            STALE = 0xFE
            def emit_map(asm, memory, map_count)
              h = Console::GBCHardware
              asm.label("rt_paint_map")
              if map_count > 1
                asm.load_hl_sp(2)
                asm.load(:a, [:hl])
                asm.call("rt_paint_map_place") # DE = the map's attributes
                asm.load(:a, [memory[MAP]])
                asm.load(:l, :a)
                asm.load(:a, [memory[MAP] + 1])
                asm.load(:h, :a) # HL = the map up before's
                asm.load(:a, :e)
                asm.load([memory[MAP]], :a)
                asm.load(:a, :d)
                asm.load([memory[MAP] + 1], :a)
                asm.call("rt_paint_tables_in_view")
                BANKS.each do |bank|
                  asm.load(:a, bank)
                  asm.load_high(h::SVBK, :a)
                  asm.load(:bc, SHOWN_AT)
                  asm.label("rt_paint_map_cell_#{bank}")
                  asm.load(:a, [:de])
                  asm.cp_a([:hl])
                  asm.jump_relative(:z, "rt_paint_map_same_#{bank}")
                  asm.load(:a, STALE)
                  asm.load([:bc], :a)
                  asm.label("rt_paint_map_same_#{bank}")
                  asm.inc(:hl)
                  asm.inc(:de)
                  asm.inc(:c)
                  asm.load(:a, :c)
                  asm.cp_a((SHOWN_AT + CELLS_A_BANK) & 0xFF)
                  asm.jump_relative(:nz, "rt_paint_map_cell_#{bank}")
                end
                asm.load(:a, 1)
                asm.load_high(h::SVBK, :a)
                asm.jump("rt_bank_back")
              end
              asm.label("rt_paint_map_first")
              return asm.ret if map_count <= 1

              asm.xor_a(:a)
              asm.call("rt_paint_map_place")
              asm.load(:a, :e)
              asm.load([memory[MAP]], :a)
              asm.load(:a, :d)
              asm.load([memory[MAP] + 1], :a)
              asm.ret
              # DE = where map A's attributes are.
              asm.label("rt_paint_map_place")
              asm.add_a(:a)
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.load(:hl, "rt_paint_map_places")
              asm.add_hl(:de)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:d, [:hl])
              asm.ret
              asm.label("rt_paint_map_places")
              map_count.times { |i| asm.data_words("rt_paint_map_#{i}") }
            end

            def emit_upload(asm, memory, map_count)
              h = Console::GBCHardware
              done = memory[LIST_DONE]
              asm.label("rt_paint_upload")
              asm.call("rt_paint_tables_in_view")
              asm.load(:a, [done])
              asm.load(:l, :a)
              asm.load(:a, [done + 1])
              asm.load(:h, :a)
              asm.label("rt_paint_upload_next")
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a) # DE = the entry
              # The list's end is looked for first, so a blank that sends the last run says the
              # list is done, however little of the blank is left.
              asm.inc(:a)
              asm.jump(:z, "rt_paint_upload_done")
              asm.push(:hl)
              # B = the run's length less one: nought for the clear tile, which costs about a tile.
              asm.load(:a, :d)
              asm.load(:b, 0)
              asm.cp_a(SENDS_CLEAR_TILE)
              asm.jump_relative(:nc, "rt_paint_upload_length")
              asm.rrca
              asm.and_a(RUN_LENGTH_MASK)
              asm.load(:b, :a)
              asm.label("rt_paint_upload_length")
              asm.load(:hl, "rt_paint_run_last_lines")
              asm.load(:c, :b)
              asm.load(:b, 0)
              asm.add_hl(:bc)
              asm.load(:b, :c)
              asm.load_high(:a, h::LY)
              asm.cp_a(h::SCREEN_HEIGHT)
              asm.jump_relative(:c, "rt_paint_upload_not_blank")
              asm.cp_a([:hl])
              asm.jump_relative(:z, "rt_paint_upload_in_time")
              asm.jump_relative(:c, "rt_paint_upload_in_time")
              asm.jump("rt_paint_upload_late")
              asm.label("rt_paint_upload_not_blank")
              asm.load_high(:a, h::LCDC)
              asm.bit(7, :a)
              asm.jump(:nz, "rt_paint_upload_late")
              asm.label("rt_paint_upload_in_time")
              asm.load(:a, :d)
              asm.cp_a(SENDS_CLEAR_TILE)
              asm.jump(:nc, "rt_paint_upload_clear_tile")
              if map_count > 1
                # The attributes of the run's cells in the map up now: its first cell's.
                asm.load(:c, :a)
                asm.and_a(1)
                asm.load(:h, :a)
                asm.load(:a, [memory[MAP]])
                asm.add_a(:e)
                asm.load(:l, :a)
                asm.load(:a, [memory[MAP] + 1])
                asm.adc_a(:h)
                asm.load(:h, :a)
                asm.load(:a, [:hl])
                asm.load([memory[RUN_ATTRIBUTES]], :a)
                asm.load(:a, :c)
              end
              # HL = the run's first tile's entry of rt_paint_cells: its number × CELL_ENTRY_BYTES on.
              asm.load(:c, :a) # what is sent
              asm.and_a(1)
              asm.load(:h, :a)
              asm.load(:l, :e)
              asm.add_hl(:hl)
              asm.load(:d, :h)
              asm.load(:e, :l)
              2.times { asm.add_hl(:hl) }
              asm.add_hl(:de)
              asm.load(:de, "rt_paint_cells")
              asm.add_hl(:de)
              asm.bit(7, :c)
              asm.jump_relative(:nz, "rt_paint_upload_solid")
              [h::SVBK, h::HDMA1, h::HDMA2, h::VBK, h::HDMA3, h::HDMA4].each do |register|
                asm.load(:a, [:hli])
                asm.load_high(register, :a)
              end
              asm.load(:a, :b)
              asm.load_high(h::HDMA5, :a) # B + 1 blocks of 16, one a tile: the copy runs now
              asm.bit(KEEPS_CELL_BIT, :c)
              # Their cells show them already — in the palette of the map up then, which a game of
              # more than one map writes again.
              asm.jump_relative(:nz, map_count > 1 ? "rt_paint_upload_kept" : "rt_paint_upload_sent")
              # The cells: the numbers the grid shows the tiles by into the grid's first bank, one
              # more each cell along, and their attributes into the second.
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              asm.load(:a, [:hli])
              asm.load(:c, :b)
              asm.inc(:c)
              asm.push(:de)
              asm.label("rt_paint_upload_numbers")
              asm.load([:de], :a)
              asm.inc(:a)
              asm.inc(:e) # a row of the grid never crosses a 256-byte page
              asm.dec(:c)
              asm.jump_relative(:nz, "rt_paint_upload_numbers")
              asm.pop(:de)
              if map_count > 1
                # Every run's cells take their attributes from the map up now.
                asm.label("rt_paint_upload_map_attributes")
                asm.load(:a, [memory[RUN_ATTRIBUTES]])
              else
                # A cell whose tile is in video memory's second bank has the attributes the clear
                # tile's cells have, its bank and its square's palette, which are all its cell ever
                # holds (#emit_start): only a run in the first bank has attributes to write.
                asm.load(:a, [:hl])
                asm.bit(TILE_BANK_BIT, :a)
                asm.jump_relative(:nz, "rt_paint_upload_sent")
              end
              asm.label("rt_paint_upload_attributes_of") # A = the attributes, B = the run's length less one
              asm.load(:c, :a)
              asm.load(:a, 1)
              asm.load_high(h::VBK, :a)
              asm.load(:a, :c)
              asm.inc(:b)
              asm.label("rt_paint_upload_attributes")
              asm.load([:de], :a)
              asm.inc(:e)
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_paint_upload_attributes")
              asm.label("rt_paint_upload_sent")
              asm.pop(:hl)
              asm.jump("rt_paint_upload_next")
              if map_count > 1
                asm.label("rt_paint_upload_kept") # DE = the first cell's place in the grid
                asm.load(:a, [:hli])
                asm.load(:e, :a)
                asm.load(:a, [:hl])
                asm.load(:d, :a)
                asm.jump_relative("rt_paint_upload_map_attributes")
              end
              # Single colours: the cells pointed at the clear tile, which every single colour
              # shown is.
              asm.label("rt_paint_upload_solid")
              asm.load(:de, 6) # past the copy's six, to the cell's place
              asm.add_hl(:de)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.inc(:hl) # to the attributes the cell had showing its own tile
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              asm.load(:a, CLEAR_TILE)
              asm.load(:c, :b)
              asm.inc(:c)
              asm.push(:de)
              asm.label("rt_paint_upload_solid_numbers")
              asm.load([:de], :a)
              asm.inc(:e)
              asm.dec(:c)
              asm.jump_relative(:nz, "rt_paint_upload_solid_numbers")
              asm.pop(:de)
              if map_count > 1
                asm.load(:a, [memory[RUN_ATTRIBUTES]])
              else
                asm.load(:a, [:hl])
                asm.bit(TILE_BANK_BIT, :a)
                asm.jump_relative(:nz, "rt_paint_upload_sent") # the clear tile's cells have them already
              end
              asm.or_a(h::ATTR_TILE_BANK)
              asm.jump_relative("rt_paint_upload_attributes_of")
              # The clear tile, in the colour E: each of its rows two bytes, the colour's low bit in
              # every pixel of the first and its high bit in the second.
              asm.label("rt_paint_upload_clear_tile")
              asm.load(:a, :e)
              asm.call("rt_paint_ink_bytes")
              asm.load(:a, 1)
              asm.load_high(h::VBK, :a)
              asm.load(:hl, CLEAR_AT)
              asm.load(:b, 8)
              asm.label("rt_paint_upload_clear_row")
              asm.load(:a, :d)
              asm.load([:hli], :a)
              asm.load(:a, :e)
              asm.load([:hli], :a)
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_paint_upload_clear_row")
              asm.pop(:hl)
              asm.jump("rt_paint_upload_next")
              asm.label("rt_paint_upload_done")
              2.times { asm.dec(:hl) } # left at the end, for a blank that comes back to it
              asm.call("rt_paint_upload_stop")
              asm.and_a(:a) # carry clear: the list is done
              asm.ret
              asm.label("rt_paint_upload_late")
              asm.pop(:hl)
              2.times { asm.dec(:hl) } # back at the entry not sent
              asm.call("rt_paint_upload_stop")
              asm.scf
              asm.ret
              # Where it got to kept, and the banks the rest of the runtime expects put back.
              asm.label("rt_paint_upload_stop")
              asm.load(:a, :l)
              asm.load([done], :a)
              asm.load(:a, :h)
              asm.load([done + 1], :a)
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              asm.inc(:a)
              asm.load_high(h::SVBK, :a)
              asm.jump("rt_bank_back")
            end
          end
        end
      end
    end
  end
end
