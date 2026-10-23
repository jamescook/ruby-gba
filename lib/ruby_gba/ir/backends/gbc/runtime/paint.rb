# frozen_string_literal: true

module RubyGBA
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
          # the picture is a pixel of one of them. A tile's pixels are two bits, so the picture
          # holds four colours at once — the background's eighth palette, which the build fills with
          # the colours the game paints in (GBC::Art), black first.
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
          #   grid is pointed at one of four tiles of a single colour instead, which is two bytes
          #   rather than sixteen.
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
            # round to 0x9000 — and the four tiles of a single colour after the last of them.
            GRID = 0x9C00
            SOLID_TILE = 104
            SOLID_AT = 0x9680
            PALETTE = 7

            # In the bank byte of an entry of the list to send: a cell pointed at a single colour,
            # the colour in the two bits above the bank's number.
            SOLID = 0x80

            # The runtime's own places: the kind of screen up; the three lists — what to send in
            # the blank, the tiles painted since the last pass, the tiles whose cells show their own
            # picture — each a count and then two bytes an entry (a tile's number in its bank, and
            # the bank's among BANKS, with SOLID and a colour for a cell pointed at one); how far
            # the blank has got down the first; whether the screen was cleared since the last pass,
            # and the colour every cell not showing its own picture shows; and the area painting
            # is held to (rt_paint_area), its left, top, right and bottom.
            SCREEN_KIND = "rt paint screen kind"
            LIST = "rt paint list"
            DIRTY_LIST = "rt paint dirty list"
            OWN_LIST = "rt paint own list"
            LIST_DONE = "rt paint list done"
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

              [LIST, DIRTY_LIST, OWN_LIST].each { |list| memory.reserve(list, 2 + (CELLS * 2)) }
              memory.reserve(LIST_DONE, 2)
              memory.reserve(CLEARED, 1)
              memory.reserve(LAST_SOLID, 1)
              memory.reserve(AREA, 4)
              memory.reserve(SCRATCH, 19)
            end

            def emit(asm, memory, painting:)
              emit_screen(asm, memory, painting: painting)
              return emit_nothing_painted(asm) unless painting

              quick = Quick.new(generation: memory.quick(1), clear: memory.quick(1), clear_low: memory.quick(1),
                                clear_high: memory.quick(1), ink_low: memory.quick(1), ink_high: memory.quick(1),
                                bank_index: memory.quick(1), bits_mask: memory.quick(1), bits_stride: memory.quick(1))
              emit_start(asm, memory, quick)
              emit_tables(asm)
              emit_cell(asm, memory, quick)
              emit_area(asm, memory)
              emit_clear(asm, memory, quick)
              emit_rect(asm, memory, quick)
              emit_bits(asm, memory, quick)
              emit_patches(asm, memory, quick)
              emit_scan(asm, memory, quick)
              emit_upload(asm, memory)
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
            # up black with no sprite on it, and a tiled one with nothing up — but the sprites this
            # pass drew, which the interpreter keeps in front of whatever scenery arrives after
            # them (Reference#redraw_sprites_over_arrived_scenery). 0, and nothing changes, for the
            # kind already up.
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
              asm.call("rt_sprites_begin")
              asm.call("rt_sprites_end")
              asm.jump_relative("rt_screen_changed")
              asm.label("rt_screen_tiled")
              asm.and_a(~h::LCDC_BG_MAP1 & 0xFF)
              asm.load([memory[Picture::LCDC_WANTED]], :a)
              asm.call("rt_picture_take_down")
              asm.label("rt_screen_changed")
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
            # in generation 0, and shown as the single colour black), the four single-colour tiles,
            # and the second grid pointed at black throughout.
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
              4.times do |color|
                8.times do
                  asm.load(:a, color & 1 == 1 ? 0xFF : 0)
                  asm.load([:hli], :a)
                  asm.load(:a, color & 2 == 2 ? 0xFF : 0)
                  asm.load([:hli], :a)
                end
              end
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
              asm.xor_a(:a)
              %i[generation clear clear_low clear_high].each { |name| asm.load_high(quick.public_send(name), :a) }
              [LIST, DIRTY_LIST, OWN_LIST, LIST_DONE].each do |list|
                asm.load(:hl, memory[list])
                asm.load([:hli], :a)
                asm.load([:hl], :a)
              end
              asm.load([memory[CLEARED]], :a)
              asm.load([memory[LAST_SOLID]], :a)
              asm.load(:hl, memory[AREA])
              WHOLE_SCREEN.each do |edge|
                asm.load(:a, edge)
                asm.load([:hli], :a)
              end
              asm.load(:a, PAINTED)
              asm.load([memory[SCREEN_KIND]], :a)
              asm.load(:a, [memory[Picture::LCDC_WANTED]])
              asm.or_a(h::LCDC_BG_MAP1)
              asm.load([memory[Picture::LCDC_WANTED]], :a)
              asm.ret
            end

            # Tables the painting reads: for each row of tiles (eight bytes each) its bank of work
            # memory, where its first tile is there, that tile's number in the bank, and the bank's
            # number among BANKS; the masks of a span; and for each tile, by its bank's number × 128
            # and its own in the bank, how it is sent (see #emit_upload).
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
              asm.label("rt_paint_cells")
              BANKS.each_index do |index|
                128.times do |in_bank|
                  in_bank < CELLS_A_BANK ? asm.data_bytes(cell_entry((index * CELLS_A_BANK) + in_bank)) : asm.data_bytes([0] * 8)
                end
              end
            end

            # How tile +cell+ is sent: its bank of work memory and where it is there, its bank of
            # video memory (with the top two bits of its place in the grid), where it goes there,
            # the number the grid shows it by, and the low byte of its place in the grid.
            def cell_entry(cell)
              h = Console::GBCHardware
              row, column = cell.divmod(COLUMNS)
              bank = BANKS.fetch(row / ROWS_A_BANK)
              in_bank = cell % CELLS_A_BANK
              from = PAINTED_AT + (in_bank * 16)
              video_bank, slot = cell < 128 ? [0, cell] : [1, cell - 128]
              to = 0x8800 + (slot * 16)
              number = (slot + 128) & 0xFF
              grid = row * 32 + column
              flags = (video_bank * h::ATTR_TILE_BANK) | ((grid >> 8) << 4)
              [bank, from & 0xFF, from >> 8, flags, to & 0xFF, to >> 8, number, grid & 0xFF]
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
            def emit_bits_rows(asm, quick)
              steps = (0...8).map { |n| "rt_paint_bits_rows_#{n}" }
              steps.each_with_index do |label, n|
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
                [quick.ink_low, quick.ink_high].each do |ink|
                  asm.load_high(:a, ink)
                  asm.xor_a([:hl])
                  asm.and_a(:c)
                  asm.xor_a([:hl])
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
              asm.label("rt_paint_bits_rows")
              steps.each { |label| asm.data_words(label) }
            end

            # rt_paint_bits(x, y, color, bits, stride, rows): a picture of one colour, a bit a
            # pixel — a line of text, a digit, a pixel — with its top left at (x, y). The build
            # worked the bits out (GBC::Picture#bits_of): +rows+ rows of +stride+ bytes, the
            # leftmost pixel in the top bit, with a byte of nothing either side of each row so a
            # tile's eight pixels can be read from any place along it. Held to the screen.
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
              rows_routine = at + 17 # 16 bits: rt_paint_bits_rows_N for this column's shift
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
              asm.call("rt_paint_ink")

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
              # The rows of this column are painted by the routine for its shift, and with its mask.
              asm.load(:a, [shift])
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
              asm.ret

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
            #   that colour's tile. Every other cell already shows a single colour, the last
            #   clear's; a clear in another colour points every one of them at the new one.
            # - Every tile painted since (DIRTY_LIST) is held against the copy last sent, and sent
            #   if it differs, or if its cell shows a single colour now.
            def emit_scan(asm, memory, quick)
              h = Console::GBCHardware
              at = memory[SCRATCH]
              read = at       # 16 bits: where the list being walked has got to
              kept = at + 2   # 16 bits: how many of the own list are kept
              left = at + 4   # 16 bits: how many of its entries are left
              asm.label("rt_paint_scan")
              asm.load(:a, [memory[SCREEN_KIND]])
              asm.cp_a(PAINTED)
              asm.ret(:nz)
              asm.xor_a(:a)
              asm.load(:hl, memory[LIST])
              asm.load([:hli], :a)
              asm.load([:hl], :a)
              asm.load(:hl, memory[LIST_DONE])
              asm.load([:hli], :a)
              asm.load([:hl], :a)
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
              # A clear in another colour: every cell not showing its own tile, pointed at it — but
              # a tile painted since the clear, which the dirty list sends as its own picture below.
              # Each cell goes on the list once, so it never holds more than there are cells.
              BANKS.each_index do |index|
                asm.load(:a, BANKS[index])
                asm.load_high(h::SVBK, :a)
                asm.load(:c, 0)
                asm.label("rt_paint_scan_recolor_#{index}")
                asm.call("rt_paint_state_now") # Z: painted in this generation
                asm.jump_relative(:z, "rt_paint_scan_recolor_next_#{index}")
                asm.call("rt_paint_shown_at")
                asm.load(:a, [:hl])
                asm.cp_a(OWN)
                asm.jump_relative(:z, "rt_paint_scan_recolor_next_#{index}")
                asm.load(:e, index)
                asm.call("rt_paint_point_at_clear")
                asm.label("rt_paint_scan_recolor_next_#{index}")
                asm.inc(:c)
                asm.load(:a, :c)
                asm.cp_a(CELLS_A_BANK)
                asm.jump_relative(:nz, "rt_paint_scan_recolor_#{index}")
              end

              # Every tile showing its own picture: kept if it was painted since the clear, pointed
              # at the clearing colour if not.
              asm.label("rt_paint_scan_own")
              asm.xor_a(:a)
              asm.load([kept], :a)
              asm.load([kept + 1], :a)
              asm.load(:hl, memory[OWN_LIST])
              asm.call("rt_paint_list_begin")
              asm.label("rt_paint_scan_own_next")
              asm.call("rt_paint_list_entry")
              asm.jump(:nc, "rt_paint_scan_own_done")
              asm.call("rt_paint_state_now") # Z: painted in this generation
              asm.jump_relative(:z, "rt_paint_scan_own_keep")
              asm.call("rt_paint_point_at_clear")
              asm.jump_relative("rt_paint_scan_own_next")
              asm.label("rt_paint_scan_own_keep")
              asm.load(:a, [kept])
              asm.load(:l, :a)
              asm.load(:a, [kept + 1])
              asm.load(:h, :a)
              asm.push(:hl)
              asm.inc(:hl)
              asm.load(:a, :l)
              asm.load([kept], :a)
              asm.load(:a, :h)
              asm.load([kept + 1], :a)
              asm.pop(:hl)
              asm.add_hl(:hl)
              asm.push(:de)
              asm.load(:de, memory[OWN_LIST] + 2)
              asm.add_hl(:de)
              asm.pop(:de)
              asm.load(:a, :c)
              asm.load([:hli], :a)
              asm.load(:a, :e)
              asm.load([:hl], :a)
              asm.jump_relative("rt_paint_scan_own_next")
              asm.label("rt_paint_scan_own_done")
              asm.load(:a, [kept])
              asm.load([memory[OWN_LIST]], :a)
              asm.load(:a, [kept + 1])
              asm.load([memory[OWN_LIST] + 1], :a)

              # Every tile painted since the pass before.
              asm.label("rt_paint_scan_dirty")
              asm.load(:hl, memory[DIRTY_LIST])
              asm.call("rt_paint_list_begin")
              asm.label("rt_paint_scan_dirty_next")
              asm.call("rt_paint_list_entry")
              asm.jump(:nc, "rt_paint_scan_dirty_done")
              asm.call("rt_paint_state_now")
              asm.res(7, [:hl]) # no longer dirty, whatever comes of it
              asm.jump_relative(:nz, "rt_paint_scan_dirty_next") # cleared since: the clear saw to it
              asm.call("rt_paint_same_as_sent")
              asm.jump_relative(:z, "rt_paint_scan_dirty_same")
              asm.call("rt_paint_copy_sent")
              asm.jump_relative("rt_paint_scan_dirty_send")
              asm.label("rt_paint_scan_dirty_same") # as sent: it goes only if its cell shows a colour
              asm.call("rt_paint_shown_at")
              asm.load(:a, [:hl])
              asm.cp_a(OWN)
              asm.jump_relative(:z, "rt_paint_scan_dirty_next")
              asm.label("rt_paint_scan_dirty_send")
              asm.call("rt_paint_send_own")
              asm.call("rt_paint_shown_at")
              asm.load(:a, [:hl])
              asm.cp_a(OWN)
              asm.jump_relative(:z, "rt_paint_scan_dirty_next")
              asm.load([:hl], OWN)
              push_keeping(asm) do
                asm.load(:d, :c)
                asm.load(:hl, memory[OWN_LIST])
                asm.call("rt_paint_list_add")
              end
              asm.jump("rt_paint_scan_dirty_next")
              asm.label("rt_paint_scan_dirty_done")
              asm.xor_a(:a)
              asm.load(:hl, memory[DIRTY_LIST])
              asm.load([:hli], :a)
              asm.load([:hl], :a)
              asm.load(:a, 1)
              asm.load_high(h::SVBK, :a)
              asm.ret

              # Walking a list: rt_paint_list_begin with HL = the list, then each rt_paint_list_entry
              # hands back the next entry — C = the tile in its bank, E = the bank's number among
              # BANKS, that bank in view — with carry clear once there are none left.
              asm.label("rt_paint_list_begin")
              asm.load(:a, [:hli])
              asm.load([left], :a)
              asm.load(:a, [:hli])
              asm.load([left + 1], :a)
              asm.load(:a, :l)
              asm.load([read], :a)
              asm.load(:a, :h)
              asm.load([read + 1], :a)
              asm.ret

              asm.label("rt_paint_list_entry")
              asm.load(:hl, left)
              asm.load(:a, [:hli])
              asm.or_a([:hl])
              asm.ret(:z) # none left: the OR leaves carry clear
              asm.dec(:hl)
              asm.load(:a, [:hl])
              asm.sub_a(1)
              asm.load([:hli], :a)
              asm.load(:a, [:hl])
              asm.sbc_a(0)
              asm.load([:hl], :a)
              asm.load(:a, [read])
              asm.load(:l, :a)
              asm.load(:a, [read + 1])
              asm.load(:h, :a)
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.and_a(3)
              asm.load(:e, :a)
              asm.add_a(BANKS.first)
              asm.load_high(h::SVBK, :a)
              asm.load(:a, :l)
              asm.load([read], :a)
              asm.load(:a, :h)
              asm.load([read + 1], :a)
              asm.scf
              asm.ret

              # HL = tile C's state, and Z when it was painted in this generation.
              asm.label("rt_paint_state_now")
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
              asm.label("rt_paint_send") # A = the bank, and SOLID and a colour for a single colour
              push_keeping(asm) do
                asm.load(:d, :c)
                asm.load(:e, :a)
                asm.load(:hl, memory[LIST])
                asm.call("rt_paint_list_add")
              end
              asm.ret

              # HL = what tile C of the bank in view shows now.
              asm.label("rt_paint_shown_at")
              asm.load(:a, SHOWN_AT & 0xFF)
              asm.add_a(:c)
              asm.load(:l, :a)
              asm.load(:h, SHOWN_AT >> 8)
              asm.ret

              # HL = tile C of the bank in view as painted, DE = as last sent.
              asm.label("rt_paint_tile_pair")
              asm.load(:l, :c)
              asm.load(:h, 0)
              4.times { asm.add_hl(:hl) }
              asm.load(:de, SENT_AT)
              asm.add_hl(:de)
              asm.load(:d, :h)
              asm.load(:e, :l)
              asm.load(:a, :l)
              asm.sub_a((SENT_AT - PAINTED_AT) & 0xFF)
              asm.load(:l, :a)
              asm.load(:a, :h)
              asm.sbc_a((SENT_AT - PAINTED_AT) >> 8)
              asm.load(:h, :a)
              asm.ret

              # Z when tile C is as last sent. Keeps C and E.
              asm.label("rt_paint_same_as_sent")
              # A tile is sixteen bytes from an address that is a multiple of sixteen, so only the low
              # byte of each address moves along it.
              push_keeping(asm) do
                asm.call("rt_paint_tile_pair")
                16.times do
                  asm.load(:a, [:de])
                  asm.cp_a([:hl])
                  asm.jump_relative(:nz, "rt_paint_same_as_sent_done")
                  asm.inc(:e)
                  asm.inc(:l)
                end
                asm.xor_a(:a) # the same throughout: the zero flag set
                asm.label("rt_paint_same_as_sent_done")
              end
              asm.ret

              # Tile C as painted is the copy sent. Keeps C and E.
              asm.label("rt_paint_copy_sent")
              push_keeping(asm) do
                asm.call("rt_paint_tile_pair")
                16.times do
                  asm.load(:a, [:hli])
                  asm.load([:de], :a)
                  asm.inc(:e)
                end
              end
              asm.ret
            end

            # The block's work with BC and DE kept round it (the flags are the block's).
            def push_keeping(asm)
              asm.push(:bc)
              asm.push(:de)
              yield
              asm.pop(:de)
              asm.pop(:bc)
            end

            # IN THE BLANK: the list, from where it got to, for as long as the blank lasts. A tile
            # of its own is copied by the console's own copy, and its cell pointed at it; a single
            # colour is the cell pointed at that colour's tile. Carry set when some of it is left
            # for the next blank. With the screen off the line never moves, and it all goes now.
            def emit_upload(asm, memory)
              h = Console::GBCHardware
              asm.label("rt_paint_upload")
              asm.label("rt_paint_upload_next")
              asm.load(:a, [memory[LIST_DONE]])
              asm.load(:e, :a)
              asm.load(:a, [memory[LIST_DONE] + 1])
              asm.load(:d, :a)
              asm.load(:a, [memory[LIST]])
              asm.cp_a(:e)
              asm.jump_relative(:nz, "rt_paint_upload_more")
              asm.load(:a, [memory[LIST] + 1])
              asm.cp_a(:d)
              asm.jump_relative(:nz, "rt_paint_upload_more")
              asm.and_a(:a) # carry clear: the list is done
              asm.ret
              asm.label("rt_paint_upload_more")
              asm.load_high(:a, h::LY)
              asm.cp_a(152)
              asm.jump_relative(:c, "rt_paint_upload_in_time")
              asm.scf # the blank is nearly over: the rest next time
              asm.ret
              asm.label("rt_paint_upload_in_time")
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.inc(:hl)
              asm.load(:a, :l)
              asm.load([memory[LIST_DONE]], :a)
              asm.load(:a, :h)
              asm.load([memory[LIST_DONE] + 1], :a)
              asm.dec(:hl)
              asm.add_hl(:hl)
              asm.load(:bc, memory[LIST] + 2)
              asm.add_hl(:bc)
              asm.load(:a, [:hli])
              asm.load(:d, :a) # the tile in its bank
              asm.load(:a, [:hl])
              asm.load(:e, :a) # its bank, and SOLID and a colour
              # HL = its entry of rt_paint_cells: (bank × 128 + tile) × 8.
              asm.and_a(3)
              asm.rrca
              asm.load(:b, :a)
              asm.and_a(0x80)
              asm.or_a(:d)
              asm.load(:l, :a)
              asm.load(:a, :b)
              asm.and_a(0x7F)
              asm.load(:h, :a)
              3.times { asm.add_hl(:hl) }
              asm.load(:bc, "rt_paint_cells")
              asm.add_hl(:bc)
              asm.bit(7, :e)
              asm.jump_relative(:nz, "rt_paint_upload_solid")
              asm.load(:a, [:hli])
              asm.load_high(h::SVBK, :a)
              asm.load(:a, [:hli])
              asm.load_high(h::HDMA2, :a)
              asm.load(:a, [:hli])
              asm.load_high(h::HDMA1, :a)
              asm.load(:a, [:hli]) # its bank of video memory, and the top of its place in the grid
              asm.load(:b, :a)
              asm.and_a(h::ATTR_TILE_BANK)
              asm.rrca
              asm.rrca
              asm.rrca
              asm.load_high(h::VBK, :a)
              asm.load(:a, [:hli])
              asm.load_high(h::HDMA4, :a)
              asm.load(:a, [:hli])
              asm.load_high(h::HDMA3, :a)
              asm.xor_a(:a)
              asm.load_high(h::HDMA5, :a) # one block of 16: the copy runs now
              asm.load(:a, [:hli]) # the number the grid shows it by
              asm.load(:c, :a)
              asm.load(:a, :b)
              asm.and_a(h::ATTR_TILE_BANK)
              asm.or_a(PALETTE)
              asm.jump_relative("rt_paint_upload_cell")
              asm.label("rt_paint_upload_solid")
              3.times { asm.inc(:hl) }
              asm.load(:a, [:hli])
              asm.load(:b, :a)
              3.times { asm.inc(:hl) }
              asm.load(:a, :e)
              asm.swap(:a)
              asm.and_a(3)
              asm.add_a(SOLID_TILE)
              asm.load(:c, :a)
              asm.load(:a, h::ATTR_TILE_BANK | PALETTE)
              asm.label("rt_paint_upload_cell") # A = the cell's attributes, C = its tile, B and (HL) its place
              asm.push(:af)
              asm.load(:a, :b)
              asm.and_a(0x30)
              asm.swap(:a)
              asm.add_a(GRID >> 8)
              asm.load(:d, :a)
              asm.load(:e, [:hl])
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              asm.load(:a, :c)
              asm.load([:de], :a)
              asm.load(:a, 1)
              asm.load_high(h::VBK, :a)
              asm.pop(:af)
              asm.load([:de], :a)
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              asm.load(:a, 1)
              asm.load_high(h::SVBK, :a)
              asm.jump("rt_paint_upload_next")
            end
          end
        end
      end
    end
  end
end
