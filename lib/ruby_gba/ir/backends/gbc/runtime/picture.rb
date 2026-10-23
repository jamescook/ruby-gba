# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        module Runtime
          # THE PICTURE: what the game says about its sprites and its background while a pass runs,
          # kept in work memory, and copied to the console in the blank after the pass.
          #
          # The console's own picture memory can only be written while it is not drawing, so
          # nothing the game does writes it directly. A pass writes copies instead — of the sprite
          # table (Memory::SHADOW_OAM), of the colours, of where the background is scrolled to —
          # and rt_upload copies them in, in the blank: the sprite table all at once by the
          # console's own copy (OAM DMA), the colours if they changed, the scroll. A background put
          # up is a bigger copy, its whole grid of cells, which is done a few rows each blank until
          # it is done; the pass is not counted as shown until it is, so a reader never sees a
          # picture half put up (see Frame).
          #
          # Everything the game's pictures are made of — the tiles, the palettes, the pieces each
          # sprite picture is cut into, the grids — is worked out while the program is built
          # (GBC::Art) and kept in the cartridge, and the tiles go into the console's memory once,
          # at power-on, while the screen is still off.
          module Picture
            # Where each of the runtime's own picture places is, by name.
            SHADOW_PALETTES = "rt picture palettes" # 64 bytes for the backgrounds, then 64 for the sprites
            PALETTES_CHANGED = "rt picture palettes changed"
            SCROLL = "rt picture scroll" # x, then y
            NEXT_SPRITE = "rt picture next sprite" # the next free entry of the sprite table's copy (low byte)
            MAP_JOB = "rt picture map job" # the grid being put up: rows left, where from, where to, its bank
            LCDC_WANTED = "rt picture lcdc"
            OVERLAP = "rt picture overlap" # two sprites' masks and where they meet, while they are tested
            GRID_UP = "rt picture grid up" # the number of the grid up, or being put up
            # The cells of the background changed during the pass, written in the blank after it:
            # how many, then for each where it is in the console's grid (16 bits), its tile and its
            # colours. A pass that changes more than CELLS_KEPT has the rest written where it asks.
            CELLS = "rt picture cells"
            CELLS_KEPT = 32
            CELL_BYTES = 4
            # A BACKGROUND BENT ROW BY ROW (`scroll_each_row`): how far each of the screen's rows
            # sits along, worked out once a pass into BENDS_NEXT and shown from BENDS in the frame
            # after, as the scroll is; BEND_BASE the scroll the shown rows are along from, and
            # BENDING 1 once a game bends.
            BENDS = "rt picture bends"
            BENDS_NEXT = "rt picture bends next"
            BEND_BASE = "rt picture bend base"
            BENDING = "rt picture bending"
            TINT = "rt picture tint" # what the colours are moved toward (TOWARD_*), the colour, and how far
            # The sprites placed this pass, for a reader of the run: how many, then for each whose it
            # is (one up), which picture, and where, x and y (16 bits each) — DRAWN_BYTES a sprite.
            DRAWN = "rt picture drawn"
            DRAWN_BYTES = 7
            MOST_DRAWN = 40
            # A GAME WHOSE SPRITES' LISTS BORROW THE EIGHT (Art#lends?, #emit_lend_colors): which
            # list each of the eight holds, one up so that nought is none; then a bit for each of the
            # eight a sprite was placed in this pass, the same for the pass before, and 1 when a list
            # was lent this pass, so its colours are to be copied.
            LENT = "rt picture lent"
            LENT_BYTES = 8 + 3

            # The display's switch that raises its interrupt as each line ends (STAT's mode-0 bit).
            STAT_HBLANK = 0x08

            # How many of the grid's 32 rows are copied in one blank: their tiles and their cells'
            # colours, 512 bytes, which the console's own copy does in about a quarter of the blank.
            MAP_ROWS_PER_BLANK = 8

            module_function

            def reserve(memory, lends: false)
              memory.reserve(LENT, LENT_BYTES) if lends
              memory.reserve(SHADOW_PALETTES, 128)
              memory.reserve(PALETTES_CHANGED, 1)
              memory.reserve(SCROLL, 2)
              memory.reserve(NEXT_SPRITE, 1)
              memory.reserve(MAP_JOB, 6)
              memory.reserve(CELLS, 1 + (CELLS_KEPT * CELL_BYTES))
              memory.reserve(BENDS, Console::GBCHardware::SCREEN_HEIGHT)
              memory.reserve(BENDS_NEXT, Console::GBCHardware::SCREEN_HEIGHT)
              memory.reserve(BEND_BASE, 1)
              memory.reserve(BENDING, 1)
              memory.reserve(LCDC_WANTED, 1)
              memory.reserve(OVERLAP, OVERLAP_BYTES)
              memory.reserve(GRID_UP, 1)
              memory.reserve(TINT, 4)
              memory.reserve(DRAWN, 1 + (MOST_DRAWN * DRAWN_BYTES))
            end

            # +runs+ are the tiles the game paints from lists (Lowering::TileRuns#run_uploads).
            # +drawn_palettes+ is where a game that draws a background with other colours keeps the
            # colours its pictures are drawn in now (Lowering::Picture#drawn_palettes), or nil for
            # one whose colours are the art's from power-on: a fade moves those.
            # +lends+ says the sprites' lists borrow the console's eight as the game runs (Art#lends?),
            # which needs +drawn_palettes+.
            def emit(asm, memory, sprite_tiles:, background_tiles:, runs: [], drawn_palettes: nil, lends: false)
              emit_start(asm, memory, sprite_tiles: sprite_tiles, background_tiles: background_tiles,
                                      drawn_palettes: drawn_palettes)
              emit_upload(asm, memory)
              emit_tile_runs(asm, runs)
              emit_sprites(asm, memory, lends: lends)
              emit_lend_colors(asm, memory, drawn_palettes) if lends
              emit_background(asm, memory)
              emit_choices(asm, memory)
              emit_overlap(asm, memory)
              emit_tint(asm, memory, drawn_palettes)
              emit_background_colors(asm, drawn_palettes) if drawn_palettes
            end

            # LENDING THE EIGHT SPRITE LISTS. A Color draws a sprite's piece in one of eight lists of
            # four colours. A game whose sprites wear more lists than that between them lends the
            # eight out, the way the console's own games do: rt_lend_colors(list) is which of the
            # eight a sprite wearing the game's list number +list+ (art_lent_palettes) is placed in.
            #
            # One holding that list already is the answer. A list holding none takes one nothing was
            # placed in this pass or the pass before — so one a sprite placed later in this pass still
            # wears is never taken from under it — and its colours are copied into the colours drawn
            # now. rt_sprites_end moves them through the fade in force into the copy the blank sends,
            # so they reach the screen in the same blank as the sprite table that first reads them.
            # A list that finds all eight in use is placed in the first, in whatever colours it holds.
            #
            # Like the Advance's lending, a list gives its one back only once a whole pass has gone
            # by without anything placed in it, since nothing says part way through a pass which lists
            # the rest will wear. So with all eight in use, a thing that comes on the pass another
            # goes is drawn for that pass in colours not its own.
            def emit_lend_colors(asm, memory, drawn_palettes)
              lent = memory[LENT]
              sprite_colors = drawn_palettes + 64
              asm.label("rt_lend_colors")
              asm.load_hl_sp(2)
              asm.load(:b, 4)
              asm.call("rt_take_args")
              asm.load_high(:a, Calls.arg(memory, 0, 1))
              asm.inc(:a)
              asm.load(:c, :a) # C = the list, one up
              asm.load(:hl, lent)
              asm.load(:de, 0x0100) # D = the bit of the one being looked at, E = which it is
              asm.label("rt_lend_held")
              asm.load(:a, [:hli])
              asm.cp_a(:c)
              asm.jump_relative(:z, "rt_lend_placed")
              asm.inc(:e)
              asm.sla(:d)
              asm.jump_relative(:nz, "rt_lend_held")
              # B = the ones placed in this pass or the one before.
              asm.load(:a, [lent + 8])
              asm.load(:b, :a)
              asm.load(:a, [lent + 9])
              asm.or_a(:b)
              asm.load(:b, :a)
              asm.load(:hl, lent)
              asm.load(:de, 0x0100)
              asm.label("rt_lend_free")
              asm.load(:a, :b)
              asm.and_a(:d)
              asm.jump_relative(:z, "rt_lend_take")
              asm.inc(:hl)
              asm.inc(:e)
              asm.sla(:d)
              asm.jump_relative(:nz, "rt_lend_free")
              asm.load(:e, 0) # every one in use
              asm.jump_relative("rt_lend_answer")
              asm.label("rt_lend_take")
              asm.load([:hl], :c)
              asm.load(:a, 1)
              asm.load([lent + 10], :a)
              asm.push(:de)
              # The list's colours, from art_lent_palettes + 8 × the list...
              asm.load(:a, :c)
              asm.dec(:a)
              asm.load(:l, :a)
              asm.load(:h, 0)
              3.times { asm.add_hl(:hl) }
              asm.load(:de, "art_lent_palettes")
              asm.add_hl(:de)
              # ...into the sprites' colours drawn now + 8 × the one it took.
              asm.pop(:de)
              asm.push(:de)
              asm.load(:a, :e)
              3.times { asm.add_a(:a) }
              asm.add_a(sprite_colors & 0xFF)
              asm.load(:e, :a)
              asm.load(:a, sprite_colors >> 8)
              asm.adc_a(0)
              asm.load(:d, :a)
              asm.load(:b, 8)
              asm.call("rt_copy_b")
              asm.pop(:de)
              asm.label("rt_lend_placed")
              asm.load(:a, [lent + 8])
              asm.or_a(:d)
              asm.load([lent + 8], :a)
              asm.label("rt_lend_answer")
              asm.load(:d, 0)
              asm.load(:bc, 0)
              asm.ret
            end

            # rt_background_colors: HL = a table of a background's colours (Lowering::Picture
            # #emit_background_colors) — how many palettes, then for each its number and its four
            # colours — into the colours the pictures are drawn in now, and those through the fade
            # in force into the copy the blank sends.
            def emit_background_colors(asm, drawn_palettes)
              asm.label("rt_background_colors")
              asm.load(:b, [:hl])
              asm.inc(:hl)
              asm.label("rt_background_colors_next")
              asm.load(:a, :b)
              asm.and_a(:a)
              asm.jump(:z, "rt_tint_apply")
              asm.load(:a, [:hli]) # the palette: drawn_palettes + 8 × its number
              3.times { asm.add_a(:a) }
              asm.add_a(drawn_palettes & 0xFF)
              asm.load(:e, :a)
              asm.load(:a, drawn_palettes >> 8)
              asm.adc_a(0)
              asm.load(:d, :a)
              8.times do
                asm.load(:a, [:hli])
                asm.load([:de], :a)
                asm.inc(:de)
              end
              asm.dec(:b)
              asm.jump_relative("rt_background_colors_next")
            end

            # What a fade or a tint moves every colour toward: black, white, or a colour of the
            # game's.
            TOWARD_BLACK = 0
            TOWARD_WHITE = 1
            TOWARD_COLOR = 2

            # A colour has three channels of five bits, red in the lowest.
            CHANNEL_MAX = 31
            STEPS = 32

            # At power-on, with the screen off: every tile into the console's memory, every
            # palette into the copy and the console. The data is the game's (GBC::Art, by the
            # labels Picture#data_section writes); how many tiles there are is known as the
            # cartridge is built, so the copies are written out for them.
            #
            # Sprite tiles go 128 to a bank at 0x8000; background tiles 256 to a bank, the first
            # 128 at 0x9000 and the next 128 at 0x8800 — the console's other way of counting
            # tiles, which a background's cells use, so the two kinds never meet.
            def emit_start(asm, memory, sprite_tiles:, background_tiles:, drawn_palettes: nil)
              h = Console::GBCHardware
              asm.label("rt_picture_start")
              chunks = []
              sprite_tiles.times.each_slice(128).with_index do |slice, bank|
                chunks << ["art_sprite_tiles", slice.first, slice.length, bank, h::VRAM]
              end
              background_tiles.times.each_slice(128).with_index do |slice, half|
                chunks << ["art_background_tiles", slice.first, slice.length, half / 2, half.even? ? 0x9000 : 0x8800]
              end
              chunks.each do |label, first, count, bank, to|
                asm.load(:a, bank)
                asm.load_high(h::VBK, :a)
                asm.load_bank_of(:a, label)
                asm.load([h::MBC_ROM_BANK_LOW], :a)
                asm.load(:hl, label)
                asm.load(:de, first * 16)
                asm.add_hl(:de)
                asm.load(:de, to)
                asm.load(:bc, count * 16)
                asm.call("rt_copy_bc")
              end
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              asm.call("rt_bank_back")
              # The palettes: the game's into the copy, then the copy into the console — and into the
              # colours the pictures are drawn in now, for a game that draws a background in others.
              if drawn_palettes
                asm.load(:hl, "art_palettes")
                asm.load(:de, drawn_palettes)
                asm.load(:b, 128)
                asm.call("rt_copy_b")
              end
              asm.load(:hl, "art_palettes")
              asm.load(:de, memory[SHADOW_PALETTES])
              asm.load(:b, 128)
              asm.call("rt_copy_b")
              asm.call("rt_picture_write_palettes")
              asm.load(:a, h::LCDC_ON | h::LCDC_SPRITES_ON | h::LCDC_BG_PRIORITY)
              asm.load([memory[LCDC_WANTED]], :a)
              asm.ret

              # The bank the game had in view, back in view after the runtime borrowed the window.
              asm.label("rt_bank_back")
              asm.load_high(:a, Memory::CURRENT_BANK)
              asm.load([h::MBC_ROM_BANK_LOW], :a)
              asm.ret

              # B bytes from HL to DE (none for 0 is 256).
              asm.label("rt_copy_b")
              asm.load(:a, [:hli])
              asm.load([:de], :a)
              asm.inc(:de)
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_copy_b")
              asm.ret

              # BC bytes from HL to DE.
              asm.label("rt_copy_bc")
              asm.load(:a, :b)
              asm.or_a(:c)
              asm.ret(:z)
              asm.load(:a, [:hli])
              asm.load([:de], :a)
              asm.inc(:de)
              asm.dec(:bc)
              asm.jump_relative("rt_copy_bc")

              # The console's own copy into picture memory (general-purpose DMA): C + 1 blocks of 16
              # bytes from HL to DE, the processor stopped while it runs. It is eight times quicker
              # than the processor copying, which is what lets a blank hold a grid's rows.
              asm.label("rt_gdma")
              asm.load(:a, :h)
              asm.load_high(h::HDMA1, :a)
              asm.load(:a, :l)
              asm.load_high(h::HDMA2, :a)
              asm.load(:a, :d)
              asm.load_high(h::HDMA3, :a)
              asm.load(:a, :e)
              asm.load_high(h::HDMA4, :a)
              asm.load(:a, :c)
              asm.load_high(h::HDMA5, :a)
              asm.ret

              # Every palette from the copy into the console: 64 bytes of background colours, then
              # 64 of sprite colours, each written one byte after another, eight to a turn of the
              # loop so the colours take a quarter of the blank rather than all of it.
              asm.label("rt_picture_write_palettes")
              asm.load(:hl, memory[SHADOW_PALETTES])
              [h::BCPS, h::OCPS].each do |select|
                asm.load(:a, 0x80)
                asm.load_high(select, :a)
                asm.load(:c, (select + 1) & 0xFF)
                asm.load(:b, 8)
                asm.label("rt_picture_palette_#{select}")
                8.times do
                  asm.load(:a, [:hli])
                  asm.load_high([:c], :a)
                end
                asm.dec(:b)
                asm.jump_relative(:nz, "rt_picture_palette_#{select}")
              end
              asm.xor_a(:a)
              asm.load([memory[PALETTES_CHANGED]], :a)
              asm.ret
            end

            # TILES THE GAME PAINTS FROM A LIST (Lowering::TileRuns).
            #
            # rt_repack_tiles: BC tiles from the Advance's way of keeping one — 32 bytes, eight rows
            # of four, each byte two pixels with the left one in its low four bits — at HL, into the
            # Color's at DE: 16 bytes, eight rows of two, the low bit of each of the row's pixels in
            # the first byte and the high bit in the second, the leftmost pixel in bit 7. A Color tile
            # holds places 0 to 3, so a place past them is made 0, black.
            #
            # rt_tile_runs_upload, in the blank: each run whose tiles were repacked since, put into
            # picture memory by the console's own copy, a tile at a time, since a run's tiles need not
            # sit side by side there — a background's or a sprite's picture's.
            def emit_tile_runs(asm, runs)
              h = Console::GBCHardware
              asm.label("rt_repack_tiles")
              asm.load(:a, :b)
              asm.or_a(:c)
              asm.ret(:z)
              asm.push(:bc)
              asm.load(:a, 8) # rows
              asm.label("rt_repack_row")
              asm.push(:af)
              asm.push(:de)
              asm.load(:b, 0) # the low bits
              asm.load(:d, 0) # the high bits
              asm.load(:e, 4) # bytes a row
              asm.label("rt_repack_byte")
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              # A place past the four a list of the Color's holds draws black, as a place past the end
              # of the run's colours does in the interpreter: place 0, where the black backdrop shows.
              [[0x0C, 0], [0xC0, 4]].each do |past, low|
                asm.and_a(past)
                asm.jump_relative(:z, "rt_repack_in_four_#{low}")
                asm.res(low, :c)
                asm.res(low + 1, :c)
                asm.label("rt_repack_in_four_#{low}")
                asm.load(:a, :c)
              end
              asm.srl(:c) # the left pixel's low bit...
              asm.rl(:b)
              asm.srl(:c) # ...and its high bit
              asm.rl(:d)
              asm.srl(:c)
              asm.srl(:c)
              asm.srl(:c) # the right pixel's low bit...
              asm.rl(:b)
              asm.srl(:c) # ...and its high bit
              asm.rl(:d)
              asm.dec(:e)
              asm.jump_relative(:nz, "rt_repack_byte")
              asm.load(:a, :b)
              asm.load(:c, :d)
              asm.pop(:de)
              asm.load([:de], :a)
              asm.inc(:de)
              asm.load(:a, :c)
              asm.load([:de], :a)
              asm.inc(:de)
              asm.pop(:af)
              asm.dec(:a)
              asm.jump_relative(:nz, "rt_repack_row")
              asm.pop(:bc)
              asm.dec(:bc)
              asm.jump("rt_repack_tiles")

              asm.label("rt_tile_runs_upload")
              runs.each_with_index do |run, r|
                past = "rt_tile_runs_upload_past_#{r}"
                asm.load(:a, [run.owed])
                asm.and_a(:a)
                asm.jump(:z, past)
                asm.xor_a(:a)
                asm.load([run.owed], :a)
                run.tiles.each_with_index do |(bank, address), k|
                  asm.load(:a, bank)
                  asm.load_high(h::VBK, :a)
                  asm.load(:hl, run.staging + (k * 16))
                  asm.load(:de, address)
                  asm.load(:c, 0) # one block of 16 bytes
                  asm.call("rt_gdma")
                end
                asm.xor_a(:a)
                asm.load_high(h::VBK, :a)
                asm.label(past)
              end
              asm.ret
            end

            # IN THE BLANK: the sprite table, the colours if they changed, the scroll and the
            # screen's switches; and a few more rows of a grid being put up. Carry set when a grid
            # is still being put up, so the frame waits for another blank before it counts as shown.
            def emit_upload(asm, memory)
              h = Console::GBCHardware
              asm.label("rt_upload")
              asm.call(Memory::OAM_DMA)
              asm.load(:a, [memory[PALETTES_CHANGED]])
              asm.and_a(:a)
              asm.call(:nz, "rt_picture_write_palettes")
              asm.load(:hl, memory[SCROLL])
              asm.load(:a, [:hli])
              asm.load_high(h::SCX, :a)
              asm.load(:a, [:hl])
              asm.load_high(h::SCY, :a)
              asm.load(:a, [memory[BENDING]])
              asm.and_a(:a)
              asm.call(:nz, "rt_bends_shown")
              asm.load_high(:a, h::LCDC) # the screen's switches, left on if it is on
              asm.and_a(h::LCDC_ON)
              asm.load(:b, :a)
              asm.load(:a, [memory[LCDC_WANTED]])
              asm.and_a(~h::LCDC_ON & 0xFF)
              asm.or_a(:b)
              asm.load_high(h::LCDC, :a)
              asm.call("rt_tile_runs_upload")
              # The cells a big map's view brought in (Runtime::BigMaps).
              asm.call("rt_big_view")
              # A grid being put up, and a painted screen's tiles: as much of each as the blank holds.
              asm.call("rt_picture_map_job")
              asm.push(:af)
              asm.call(:nc, "rt_picture_cells") # once the grid is all up, the cells changed since
              asm.call("rt_paint_upload")
              asm.jump_relative(:c, "rt_upload_more")
              asm.pop(:af)
              asm.ret
              asm.label("rt_upload_more")
              asm.pop(:af)
              asm.scf
              asm.ret

              # MAP_ROWS_PER_BLANK more rows of a grid being put up, or all of them while the screen
              # is off. Carry set when some are left.
              asm.label("rt_picture_map_job")
              asm.load(:a, [memory[MAP_JOB]])
              asm.and_a(:a)
              asm.ret(:z) # nothing being put up: carry clear from the AND
              asm.call("rt_picture_map_rows")
              asm.load(:a, [memory[MAP_JOB]])
              asm.and_a(:a)
              asm.ret(:z)
              asm.scf
              asm.ret

              # THE ROWS' BENDS FOR THE FRAME ABOUT TO BE DRAWN: the ones the pass worked out, from
              # the scroll just set, the first row's set now and each row after it as the line before
              # it ends (rt_hblank_interrupt).
              asm.label("rt_bends_shown")
              asm.load(:hl, memory[BENDS_NEXT])
              asm.load(:de, memory[BENDS])
              asm.load(:b, Console::GBCHardware::SCREEN_HEIGHT)
              asm.label("rt_bends_shown_row")
              asm.load(:a, [:hli])
              asm.load([:de], :a)
              asm.inc(:de)
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_bends_shown_row")
              asm.load_high(:a, h::SCX)
              asm.load([memory[BEND_BASE]], :a)
              asm.load(:hl, memory[BENDS])
              asm.add_a([:hl])
              asm.load_high(h::SCX, :a)
              asm.ret

              # rt_bends_on(): a background bends from here — the interrupt at the end of each line
              # switched on, as well as the frame's.
              asm.label("rt_bends_on")
              asm.load(:a, [memory[BENDING]])
              asm.and_a(:a)
              asm.ret(:nz)
              asm.inc(:a)
              asm.load([memory[BENDING]], :a)
              asm.load_high(:a, h::STAT)
              asm.or_a(STAT_HBLANK)
              asm.load_high(h::STAT, :a)
              asm.load_high(:a, h::IE)
              asm.or_a(h::INT_STAT)
              asm.load_high(h::IE, :a)
              asm.ret

              # At the end of each line drawn: the next line along by its bend. After the last, the
              # first, for the frame after the blank — which a pass running late leaves to this.
              asm.label("rt_hblank_interrupt")
              %i[af de hl].each { |pair| asm.push(pair) }
              asm.load_high(:a, h::LY)
              asm.inc(:a)
              asm.cp_a(Console::GBCHardware::SCREEN_HEIGHT)
              asm.jump_relative(:c, "rt_hblank_interrupt_row")
              asm.xor_a(:a)
              asm.label("rt_hblank_interrupt_row")
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.load(:hl, memory[BENDS])
              asm.add_hl(:de)
              asm.load(:a, [memory[BEND_BASE]])
              asm.add_a([:hl])
              asm.load_high(h::SCX, :a)
              %i[hl de af].each { |pair| asm.pop(pair) }
              asm.reti

              # The cells changed during the pass (CELLS), each its tile into the first bank of video
              # memory and its colours into the second.
              asm.label("rt_picture_cells")
              asm.load(:hl, memory[CELLS])
              asm.load(:a, [:hl])
              asm.and_a(:a)
              asm.ret(:z)
              asm.load(:b, :a)
              asm.xor_a(:a)
              asm.load([:hli], :a)
              asm.label("rt_picture_cells_next")
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              2.times do |bank|
                asm.load(:a, bank)
                asm.load_high(h::VBK, :a)
                asm.load(:a, [:hli])
                asm.load([:de], :a)
              end
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_picture_cells_next")
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              asm.ret

              # rt_upload in as many blanks as it takes.
              asm.label("rt_upload_whole")
              asm.call("rt_upload")
              asm.ret(:nc)
              asm.call("rt_sleep_until_vblank")
              asm.jump_relative("rt_upload_whole")
            end

            # SPRITES. A pass's sprites are written into the copy of the table front-most first,
            # which is the order the console draws them in (an earlier entry in front), from
            # rt_sprites_begin to rt_sprites_end, which switches off every entry after
            # the last one written. A sprite is its picture's pieces, each an entry; a piece
            # wholly off the screen is left out, since the table's place is a byte and a place far
            # off the screen would come round onto it.
            #
            # In a game whose sprites' lists borrow the eight (+lends+), a pass's start makes this
            # pass's eight the pass before's, and its end copies the colours of any list lent in it.
            def emit_sprites(asm, memory, lends: false)
              args = ->(i) { Calls.arg(memory, i, 4) }
              asm.label("rt_sprites_begin")
              if lends
                asm.load(:hl, memory[LENT] + 8)
                asm.load(:a, [:hl])
                asm.load([:hl], 0)
                asm.inc(:hl)
                asm.load([:hl], :a)
              end
              asm.xor_a(:a)
              asm.load([memory[NEXT_SPRITE]], :a)
              asm.load([memory[DRAWN]], :a)
              asm.ret

              asm.label("rt_sprites_end")
              if lends
                asm.load(:hl, memory[LENT] + 10)
                asm.load(:a, [:hl])
                asm.and_a(:a)
                asm.jump_relative(:z, "rt_sprites_end_lent")
                asm.load([:hl], 0)
                asm.call("rt_tint_apply")
                asm.label("rt_sprites_end_lent")
              end
              asm.load(:a, [memory[NEXT_SPRITE]])
              asm.load(:l, :a)
              asm.load(:h, Memory::SHADOW_OAM >> 8)
              asm.label("rt_sprites_end_next")
              asm.load(:a, :l)
              asm.cp_a(Console::GBCHardware::OAM_SIZE)
              asm.ret(:nc)
              asm.load([:hl], 0) # Y of 0: above the screen, not drawn
              4.times { asm.inc(:l) }
              asm.jump_relative("rt_sprites_end_next")

              # rt_sprite(picture, x, y, attributes): HL in the pictures' table is the picture's
              # pieces — a count, then for each its dx, dy, tile and bank. The attributes are the
              # palette and whether it is drawn behind the background (OBJ_BEHIND), as the sprite
              # table keeps them.
              # rt_sprite_fixed(record): the same, from a record in the cartridge of the four
              # numbers, sixteen bits each, put where rt_sprite's numbers are put.
              asm.label("rt_sprite_fixed")
              asm.load_hl_sp(2)
              asm.load(:a, [:hli])
              asm.load(:h, [:hl])
              asm.load(:l, :a)
              [args.call(0), args.call(1), args.call(2), args.call(3), args.call(3) + 2].each do |to|
                asm.load(:a, [:hli])
                asm.load_high(to, :a)
                asm.load(:a, [:hli])
                asm.load_high(to + 1, :a)
              end
              asm.jump_relative("rt_sprite_taken")

              asm.label("rt_sprite")
              asm.load_hl_sp(2)
              asm.load(:b, 16)
              asm.call("rt_take_args")
              asm.label("rt_sprite_taken")
              # Written down for a reader of the run: whose, which picture, where.
              asm.load(:a, [memory[DRAWN]])
              asm.cp_a(MOST_DRAWN)
              asm.jump_relative(:nc, "rt_sprite_noted")
              asm.load(:e, :a)
              asm.inc(:a)
              asm.load([memory[DRAWN]], :a)
              asm.load(:l, :e)
              asm.load(:h, 0)
              3.times { asm.add_hl(:hl) }
              asm.load(:a, :l) # × 8, less one: × 7
              asm.sub_a(:e)
              asm.load(:l, :a)
              asm.load(:a, :h)
              asm.sbc_a(0)
              asm.load(:h, :a)
              asm.load(:de, memory[DRAWN] + 1)
              asm.add_hl(:de)
              [args.call(3) + 1, args.call(3) + 2, args.call(3) + 3, args.call(1), args.call(1) + 1,
               args.call(2), args.call(2) + 1].each do |from|
                asm.load_high(:a, from)
                asm.load([:hli], :a)
              end
              asm.label("rt_sprite_noted")
              asm.load_high(:a, args.call(0)) # the picture's entry: the table + 2 × its number
              asm.load(:l, :a)
              asm.load_high(:a, args.call(0) + 1)
              asm.load(:h, :a)
              asm.add_hl(:hl)
              asm.load(:de, "art_pictures")
              asm.add_hl(:de)
              asm.load(:a, [:hli])
              asm.load(:h, [:hl])
              asm.load(:l, :a) # HL = the picture's pieces
              asm.load(:a, [:hli])
              asm.and_a(:a)
              asm.ret(:z)
              asm.load(:c, :a) # how many pieces
              asm.label("rt_sprite_piece")
              asm.push(:bc)
              asm.call("rt_gbc_place_piece")
              asm.pop(:bc)
              asm.dec(:c)
              asm.jump_relative(:nz, "rt_sprite_piece")
              asm.ret

              # One piece at HL (dx, dy, tile, bank), HL moved past it: its place on the screen
              # worked out in 16 bits, and an entry written unless it is wholly off the screen or the
              # table is full.
              asm.label("rt_gbc_place_piece")
              # DE = x + dx, as a 16-bit number (x's low two bytes).
              asm.load_high(:a, args.call(1))
              asm.add_a([:hl])
              asm.load(:e, :a)
              asm.load_high(:a, args.call(1) + 1)
              asm.adc_a(0)
              asm.load(:d, :a)
              asm.inc(:hl)
              asm.push(:de)
              # BC = y + dy.
              asm.load_high(:a, args.call(2))
              asm.add_a([:hl])
              asm.load(:c, :a)
              asm.load_high(:a, args.call(2) + 1)
              asm.adc_a(0)
              asm.load(:b, :a)
              asm.inc(:hl)
              asm.pop(:de)
              # On the screen only when -8 < x < 160 and -8 < y < 144: x + 8 and y + 16 (the table's
              # places) then fit a byte and are not past the screen.
              asm.push(:hl)
              asm.load(:hl, 8)
              asm.add_hl(:de) # HL = x + 8
              asm.load(:a, :h)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_gbc_piece_off")
              asm.load(:a, :l)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_gbc_piece_off")
              asm.cp_a(168)
              asm.jump_relative(:nc, "rt_gbc_piece_off")
              asm.load(:e, :a) # E = the table's x
              asm.load(:hl, 8)
              asm.add_hl(:bc) # HL = y + 8: on the screen when 1..151
              asm.load(:a, :h)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_gbc_piece_off")
              asm.load(:a, :l)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_gbc_piece_off")
              asm.cp_a(152)
              asm.jump_relative(:nc, "rt_gbc_piece_off")
              asm.add_a(8)
              asm.load(:d, :a) # D = the table's y (y + 16)
              asm.load(:a, [memory[NEXT_SPRITE]])
              asm.cp_a(Console::GBCHardware::OAM_SIZE)
              asm.jump_relative(:nc, "rt_gbc_piece_off") # the table is full
              asm.load(:l, :a)
              asm.add_a(4)
              asm.load([memory[NEXT_SPRITE]], :a)
              asm.load(:h, Memory::SHADOW_OAM >> 8)
              asm.load(:a, :d)
              asm.load([:hli], :a)
              asm.load(:a, :e)
              asm.load([:hli], :a)
              asm.pop(:de) # DE = the piece's tile and bank
              asm.load(:a, [:de])
              asm.load([:hli], :a)
              asm.inc(:de)
              asm.load(:a, [:de]) # the attributes: the piece's bank and mirroring, then the sprite's
              asm.inc(:de)
              asm.load(:b, :a)
              asm.load_high(:a, args.call(3))
              asm.or_a(:b)
              asm.load([:hl], :a)
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.ret
              asm.label("rt_gbc_piece_off")
              asm.pop(:hl)
              asm.inc(:hl)
              asm.inc(:hl)
              asm.ret
            end

            # ONE CELL OF THE BACKGROUND CHANGED (Reference#exec_set_tile): rt_background_cell(col,
            # row, size, cell) — +size+ the map's columns and, in its second byte, its rows; +cell+
            # the tile and, in its second byte, the cell's colours — changes the cell in the
            # console's grid, its tile in the first bank of video memory and its colours in the
            # second, and a cell off the map changes nothing.
            #
            # IN THE BLANK AFTER THE PASS, with the rest of the pass's picture: the cell waits in
            # CELLS, so the frame being drawn still shows the pass before, as the interpreter shows
            # it. A pass that changes more cells than CELLS keeps has the rest written where it asks:
            # video memory can be written between the lines the display reads but not while it reads
            # one (STAT's low two bits, 3 while it reads video memory), so each write waits for a
            # moment it is not reading, with the interrupt held off between the wait and the write.
            #
            # A grid with a cell changed is no longer the one declared, so the next put up of it puts
            # it up again (GRID_UP), as declared.
            def emit_background_cell(asm, memory)
              h = Console::GBCHardware
              arg = ->(i) { Calls.arg(memory, i, 4) }
              asm.label("rt_background_cell")
              asm.load_hl_sp(2)
              asm.load(:b, 16)
              asm.call("rt_take_args")
              [0, 1].each do |i| # the column and the row: from nought, and short of the map's size
                asm.load_high(:a, arg.call(i) + 1)
                asm.load(:b, :a)
                asm.load_high(:a, arg.call(i) + 2)
                asm.or_a(:b)
                asm.load(:b, :a)
                asm.load_high(:a, arg.call(i) + 3)
                asm.or_a(:b)
                asm.ret(:nz)
                asm.load_high(:a, arg.call(2) + i)
                asm.load(:c, :a)
                asm.load_high(:a, arg.call(i))
                asm.cp_a(:c)
                asm.ret(:nc)
              end
              asm.load_high(:a, arg.call(1)) # HL = the cell's place in the grid: 32 cells a row
              asm.load(:l, :a)
              asm.load(:h, 0)
              5.times { asm.add_hl(:hl) }
              asm.load_high(:a, arg.call(0))
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.add_hl(:de)
              asm.load(:de, h::TILE_MAP0)
              asm.add_hl(:de)
              asm.load(:a, 0xFF)
              asm.load([memory[GRID_UP]], :a)
              # Into the cells for the blank, while there is room: HL where it goes, then the cell.
              asm.load(:a, [memory[CELLS]])
              asm.cp_a(CELLS_KEPT)
              asm.jump_relative(:nc, "rt_background_cell_now")
              asm.inc(:a)
              asm.load([memory[CELLS]], :a)
              asm.dec(:a)
              asm.add_a(:a)
              asm.add_a(:a) # four bytes a cell
              asm.push(:hl)
              asm.load(:l, :a)
              asm.load(:h, 0)
              asm.load(:de, memory[CELLS] + 1)
              asm.add_hl(:de)
              asm.pop(:de)
              asm.load(:a, :e)
              asm.load([:hli], :a)
              asm.load(:a, :d)
              asm.load([:hli], :a)
              asm.load_high(:a, arg.call(3))
              asm.load([:hli], :a)
              asm.load_high(:a, arg.call(3) + 1)
              asm.load([:hl], :a)
              asm.ret
              asm.label("rt_background_cell_now")
              asm.di
              [0, 1].each do |bank|
                asm.load(:a, bank)
                asm.load_high(h::VBK, :a)
                asm.label("rt_background_cell_wait_#{bank}")
                asm.load_high(:a, h::STAT)
                asm.and_a(0x02)
                asm.jump_relative(:nz, "rt_background_cell_wait_#{bank}")
                asm.load_high(:a, arg.call(3) + bank)
                asm.load([:hl], :a)
              end
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              asm.ei
              asm.ret
            end

            # THE BACKGROUND. rt_background_put_up(grid) starts putting a grid up — its tiles
            # and then its cells' colours, 32 rows of 32 each, kept by GBC::Art — and the blanks
            # copy it in (rt_upload); rt_background_scroll(x, y) says where the view sits.
            def emit_background(asm, memory)
              h = Console::GBCHardware
              emit_background_cell(asm, memory)
              asm.label("rt_background_put_up")
              asm.load_hl_sp(2)
              asm.load(:a, [:hl]) # the grid's number: nothing to do when it is the one up
              asm.load(:hl, memory[GRID_UP])
              asm.cp_a([:hl])
              asm.ret(:z)
              asm.label("rt_picture_put_up") # A = the grid's number
              asm.load([memory[GRID_UP]], :a)
              asm.load(:hl, memory[BigMaps::STATE] + BigMaps::ON) # a big map is not up any more
              asm.load([:hl], 0)
              asm.load(:e, :a) # its entry in the grids' table, three bytes
              asm.load(:d, 0)
              asm.load(:hl, "art_grids")
              3.times { asm.add_hl(:de) }
              asm.load(:a, [:hli])
              asm.load([memory[MAP_JOB] + 1], :a)
              asm.load(:a, [:hli])
              asm.load([memory[MAP_JOB] + 2], :a)
              asm.load(:a, [:hl])
              asm.load([memory[MAP_JOB] + 5], :a)
              asm.xor_a(:a) # the first row of the console's grid
              asm.load([memory[MAP_JOB] + 3], :a)
              asm.load(:a, h::TILE_MAP0 >> 8)
              asm.load([memory[MAP_JOB] + 4], :a)
              asm.load(:a, 32)
              asm.load([memory[MAP_JOB]], :a)
              asm.load_high(:a, h::LCDC) # with the screen off it goes in now
              asm.bit(7, :a)
              asm.ret(:nz)

              # The next rows of the grid being put up, from where the job has got to — all of them
              # while the screen is off, MAP_ROWS_PER_BLANK in a blank — each row's 32 tiles into
              # bank 0 of the console's grid and its 32 cells' colours, 1024 bytes on, into bank 1.
              asm.label("rt_picture_map_rows")
              asm.load_high(:a, h::LCDC)
              asm.bit(7, :a)
              asm.load(:b, 32)
              asm.jump_relative(:z, "rt_picture_map_rows_counted")
              asm.load(:b, MAP_ROWS_PER_BLANK)
              asm.label("rt_picture_map_rows_counted")
              asm.load(:a, [memory[MAP_JOB]])
              asm.cp_a(:b)
              asm.jump_relative(:nc, "rt_picture_map_rows_some")
              asm.load(:b, :a) # fewer left than that: the rest
              asm.label("rt_picture_map_rows_some")
              asm.sub_a(:b)
              asm.load([memory[MAP_JOB]], :a)
              asm.load(:a, [memory[MAP_JOB] + 5])
              asm.load([h::MBC_ROM_BANK_LOW], :a)
              asm.load(:a, :b) # rows × 32 bytes = rows × 2 blocks of 16
              asm.add_a(:a)
              asm.dec(:a)
              asm.load(:c, :a)
              asm.push(:bc)
              asm.load(:a, [memory[MAP_JOB] + 1]) # HL = where these rows come from
              asm.load(:l, :a)
              asm.load(:a, [memory[MAP_JOB] + 2])
              asm.load(:h, :a)
              asm.load(:a, [memory[MAP_JOB] + 3]) # DE = where they go
              asm.load(:e, :a)
              asm.load(:a, [memory[MAP_JOB] + 4])
              asm.load(:d, :a)
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              asm.call("rt_gdma") # the tiles (rt_gdma keeps HL, DE and BC)
              asm.push(:hl)
              asm.push(:bc)
              asm.load(:bc, 1024)
              asm.add_hl(:bc)
              asm.pop(:bc)
              asm.load(:a, 1)
              asm.load_high(h::VBK, :a)
              asm.call("rt_gdma") # the cells' colours
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              asm.pop(:hl)
              asm.pop(:bc) # B = the rows copied: BC = the bytes they were, 32 a row
              asm.load(:c, :b)
              asm.load(:b, 0)
              5.times do
                asm.sla(:c)
                asm.rl(:b)
              end
              asm.add_hl(:bc) # the next row comes from just past these
              asm.load(:a, :l)
              asm.load([memory[MAP_JOB] + 1], :a)
              asm.load(:a, :h)
              asm.load([memory[MAP_JOB] + 2], :a)
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.add_hl(:bc) # ...and goes just past these
              asm.load(:a, :l)
              asm.load([memory[MAP_JOB] + 3], :a)
              asm.load(:a, :h)
              asm.load([memory[MAP_JOB] + 4], :a)
              asm.jump("rt_bank_back")

              # A change of the kind of screen takes everything down: the grid with nothing in it
              # (GBC::Art's first) goes up, at the scroll's start.
              asm.label("rt_picture_take_down")
              asm.xor_a(:a)
              asm.load(:hl, memory[SCROLL])
              asm.load([:hli], :a)
              asm.load([:hl], :a)
              asm.jump("rt_picture_put_up")

              asm.label("rt_background_scroll")
              asm.load_hl_sp(6) # y, then x, from the top of the stack: their low bytes
              asm.load(:a, [:hl])
              asm.load([memory[SCROLL]], :a)
              asm.load_hl_sp(2)
              asm.load(:a, [:hl])
              asm.load([memory[SCROLL] + 1], :a)
              # ...and, for a map bigger than the grid, the cell each is in (Runtime::BigMaps).
              big = memory[BigMaps::STATE]
              [[6, BigMaps::WANT], [2, BigMaps::WANT + 2]].each do |from, want|
                asm.load_hl_sp(from)
                asm.load(:a, [:hli])
                asm.load(:e, :a)
                asm.load(:a, [:hl])
                asm.load(:d, :a)
                asm.call("rt_big_want")
                asm.load(:a, :e)
                asm.load([big + want], :a)
                asm.load(:a, :d)
                asm.load([big + want + 1], :a)
              end
              asm.jump("rt_big_prepare")
            end

            # CHOOSING BY NUMBER. rt_place_of_choice(which, others) is which list of colours a
            # sprite is drawn with: 1 + which for one of its +others+, and 0 — its own — for any
            # number naming none of them (Reference#object_recolor). rt_pose_place(pose, count)
            # is which of its pictures a sprite is showing, counted back from the last for a number
            # below nought as the interpreter reads it; one naming none of them stops the game.
            def emit_choices(asm, memory)
              which = Calls.arg(memory, 0, 2)
              others = Calls.arg(memory, 1, 2)
              asm.label("rt_place_of_choice")
              asm.load_hl_sp(2)
              asm.load(:b, 8)
              asm.call("rt_take_args")
              asm.load_high(:a, which + 3)
              asm.bit(7, :a)
              asm.jump_relative(:nz, "rt_place_of_choice_own")
              asm.load(:hl, which)
              asm.call("rt_load32")
              asm.load(:hl, others)
              asm.call("rt_cmp32")
              asm.cp_a(1)
              asm.jump_relative(:nz, "rt_place_of_choice_own")
              asm.inc(:e) # which + 1: which is below +others+, so never past 16 bits
              asm.ret(:nz)
              asm.inc(:d)
              asm.ret
              asm.label("rt_place_of_choice_own")
              asm.load(:bc, 0)
              asm.load(:de, 0)
              asm.ret

              # rt_row_drawn_with(choice, table): the first row of a sprite's pictures drawn with the
              # list +choice+ names (rt_place_of_choice's answer), and for a list that holds other
              # sets as the game runs, as many rows further as the set it holds now — counted as
              # rt_place_of_choice counts, so a number naming none of the others is the set it was
              # declared with. +table+ is eight bytes a list (Lowering::Picture#row_drawn_with): its
              # first row and where its number is kept, sixteen bits each, then how many others.
              asm.label("rt_row_drawn_with")
              asm.load_hl_sp(2)
              asm.load(:b, 8)
              asm.call("rt_take_args")
              asm.load_high(:a, which)
              asm.load(:l, :a)
              asm.load(:h, 0)
              3.times { asm.add_hl(:hl) }
              asm.load_high(:a, others)
              asm.load(:e, :a)
              asm.load_high(:a, others + 1)
              asm.load(:d, :a)
              asm.add_hl(:de)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a) # DE = the first row
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.load(:b, :a) # BC = where the number is kept
              asm.or_a(:c)
              asm.jump_relative(:z, "rt_row_drawn_with_done")
              asm.load(:a, [:hl])
              asm.load(:h, :b)
              asm.load(:l, :c)
              asm.load(:b, :a) # B = how many others
              asm.load(:a, [:hli])
              asm.load(:c, :a) # C = the number's low byte; the rest has to be nought
              asm.load(:a, [:hli])
              asm.or_a([:hl])
              asm.inc(:hl)
              asm.or_a([:hl])
              asm.jump_relative(:nz, "rt_row_drawn_with_done")
              asm.load(:a, :c)
              asm.cp_a(:b)
              asm.jump_relative(:nc, "rt_row_drawn_with_done")
              asm.inc(:a) # one of the others: a row further than its number
              asm.add_a(:e)
              asm.load(:e, :a)
              asm.jump_relative(:nc, "rt_row_drawn_with_done")
              asm.inc(:d)
              asm.label("rt_row_drawn_with_done")
              asm.load(:bc, 0)
              asm.ret

              asm.label("rt_pose_place") # (pose, count): +which+ and +others+ again
              asm.load_hl_sp(2)
              asm.load(:b, 8)
              asm.call("rt_take_args")
              asm.load(:hl, which)
              asm.call("rt_load32")
              asm.bit(7, :b)
              asm.jump_relative(:z, "rt_pose_place_counted")
              asm.load(:hl, others)
              asm.call("rt_add32")
              asm.bit(7, :b)
              asm.jump_relative(:nz, "rt_pose_place_none")
              asm.label("rt_pose_place_counted")
              asm.load(:hl, others)
              asm.call("rt_cmp32")
              asm.cp_a(1)
              asm.ret(:z)
              asm.label("rt_pose_place_none")
              [[which, 3], [others, 7]].each do |from, to| # the pose and the count: the fault's two numbers
                asm.load(:hl, from)
                asm.load(:de, memory[Frame::FAULT] + to)
                asm.load(:b, 4)
                asm.call("rt_copy_b")
              end
              asm.load(:a, Frame::PICTURE_NOT_THERE)
              asm.jump("rt_fault")
            end

            OVERLAP_BYTES = 17

            # PIXELS TOUCHING. rt_pixels_overlap(a, b, dx, dy): 1 when sprite picture +a+ and
            # sprite picture +b+, b standing dx across and dy down from a, draw a pixel in the same
            # place (Reference#pixels_overlap?). Each picture's MASK (GBC::Art) is a bit for every
            # pixel, set where it draws; only the rectangle where the two pictures meet is walked,
            # and nothing at all when they do not meet. A picture is at most 64 pixels each way, so
            # two that meet are less than 64 apart and every number here fits a byte.
            def emit_overlap(asm, memory)
              at = memory[OVERLAP]
              a_mask = at       # width, height, bytes a row, where its rows start
              b_mask = at + 5
              dx = at + 10
              dy = at + 11
              x_first = at + 12
              x_past = at + 13
              y_now = at + 14
              y_past = at + 15
              x_now = at + 16
              arg = ->(i) { Calls.arg(memory, i, 4) }

              asm.label("rt_pixels_overlap")
              asm.load_hl_sp(2)
              asm.load(:b, 16)
              asm.call("rt_take_args")
              [[arg.call(2), dx], [arg.call(3), dy]].each do |from, to|
                asm.load(:hl, from)
                asm.call("rt_fits_byte")
                asm.jump(:nc, "rt_overlap_no")
                asm.load([to], :a)
              end
              [[arg.call(0), a_mask], [arg.call(1), b_mask]].each do |from, to|
                asm.load(:hl, from)
                asm.load(:de, to)
                asm.call("rt_overlap_mask")
              end
              # Across, then down: where the two meet, in a's own pixels — from max(0, d) to
              # min(a's size, d + b's size) — or nothing when d is at or past a's size, or d + b's
              # size is at or before nought.
              [[dx, a_mask, b_mask, x_first, x_past], [dy, a_mask + 1, b_mask + 1, y_now, y_past]].each do |d, a_size, b_size, first, past|
                asm.load(:a, [a_size])
                asm.xor_a(0x80)
                asm.load(:b, :a)
                asm.load(:a, [d])
                asm.xor_a(0x80)
                asm.cp_a(:b) # signed: d against a's size
                asm.jump(:nc, "rt_overlap_no")
                asm.load(:a, [b_size])
                asm.load(:b, :a)
                asm.load(:a, [d])
                asm.add_a(:b)
                asm.jump(:z, "rt_overlap_no")
                asm.bit(7, :a)
                asm.jump(:nz, "rt_overlap_no")
                asm.load(:b, :a) # d + b's size, above nought: the smaller of it and a's size
                asm.load(:a, [a_size])
                asm.cp_a(:b)
                asm.jump_relative(:c, "rt_overlap_#{first}_past")
                asm.load(:a, :b)
                asm.label("rt_overlap_#{first}_past")
                asm.load([past], :a)
                asm.load(:a, [d])
                asm.bit(7, :a)
                asm.jump_relative(:z, "rt_overlap_#{first}_first")
                asm.xor_a(:a)
                asm.label("rt_overlap_#{first}_first")
                asm.load([first], :a)
              end

              asm.label("rt_overlap_row")
              asm.load(:a, [y_now])
              asm.load(:b, :a)
              asm.load(:a, [y_past])
              asm.cp_a(:b)
              asm.jump_relative(:z, "rt_overlap_no")
              asm.load(:a, [x_first])
              asm.load([x_now], :a)
              asm.label("rt_overlap_pixel")
              asm.load(:a, [x_now])
              asm.load(:b, :a)
              asm.load(:a, [x_past])
              asm.cp_a(:b)
              asm.jump_relative(:z, "rt_overlap_next_row")
              # a's pixel at (x, y)...
              asm.load(:d, :b)
              asm.load(:a, [y_now])
              asm.load(:e, :a)
              asm.load(:hl, a_mask + 2)
              asm.call("rt_overlap_bit")
              asm.jump_relative(:z, "rt_overlap_next_pixel")
              # ...and b's at (x - dx, y - dy).
              asm.load(:a, [dx])
              asm.load(:b, :a)
              asm.load(:a, [x_now])
              asm.sub_a(:b)
              asm.load(:d, :a)
              asm.load(:a, [dy])
              asm.load(:b, :a)
              asm.load(:a, [y_now])
              asm.sub_a(:b)
              asm.load(:e, :a)
              asm.load(:hl, b_mask + 2)
              asm.call("rt_overlap_bit")
              asm.jump_relative(:nz, "rt_overlap_yes")
              asm.label("rt_overlap_next_pixel")
              asm.load(:hl, x_now)
              asm.inc([:hl])
              asm.jump_relative("rt_overlap_pixel")
              asm.label("rt_overlap_next_row")
              asm.load(:hl, y_now)
              asm.inc([:hl])
              asm.jump_relative("rt_overlap_row")
              asm.label("rt_overlap_yes")
              asm.load(:bc, 0)
              asm.load(:de, 1)
              asm.ret
              asm.label("rt_overlap_no")
              asm.load(:bc, 0)
              asm.load(:de, 0)
              asm.ret

              # Carry set when the 32-bit number at HL fits a signed byte, which is then in A.
              asm.label("rt_fits_byte")
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.rla
              asm.sbc_a(:a) # every byte above it, if it fits: nought, or all ones below nought
              asm.load(:d, :a)
              3.times do
                asm.load(:a, [:hli])
                asm.cp_a(:d)
                asm.jump_relative(:nz, "rt_fits_byte_not")
              end
              asm.load(:a, :e)
              asm.scf
              asm.ret
              asm.label("rt_fits_byte_not")
              asm.and_a(:a)
              asm.ret

              # The mask of the picture whose number is at HL, into DE: its width, height and bytes
              # a row, and where its rows start.
              asm.label("rt_overlap_mask")
              asm.load(:a, [:hli])
              asm.load(:h, [:hl])
              asm.load(:l, :a)
              asm.add_hl(:hl)
              asm.push(:de)
              asm.load(:de, "art_masks")
              asm.add_hl(:de)
              asm.pop(:de)
              asm.load(:a, [:hli])
              asm.load(:h, [:hl])
              asm.load(:l, :a)
              3.times do
                asm.load(:a, [:hli])
                asm.load([:de], :a)
                asm.inc(:de)
              end
              asm.load(:a, :l)
              asm.load([:de], :a)
              asm.inc(:de)
              asm.load(:a, :h)
              asm.load([:de], :a)
              asm.ret

              # NZ when the pixel at (D, E) of a mask is drawn; HL is the mask's bytes a row, and
              # where its rows start just after that.
              asm.label("rt_overlap_bit")
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.load(:h, [:hl])
              asm.load(:l, :a) # HL = its rows
              asm.load(:b, 0)
              asm.load(:a, :e)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_overlap_bit_row")
              asm.label("rt_overlap_bit_down")
              asm.add_hl(:bc)
              asm.dec(:a)
              asm.jump_relative(:nz, "rt_overlap_bit_down")
              asm.label("rt_overlap_bit_row")
              asm.load(:a, :d)
              3.times { asm.srl(:a) }
              asm.load(:c, :a)
              asm.add_hl(:bc)
              asm.load(:a, :d)
              asm.and_a(7)
              asm.load(:b, :a)
              asm.load(:a, 0x80)
              asm.jump_relative(:z, "rt_overlap_bit_test")
              asm.label("rt_overlap_bit_shift")
              asm.srl(:a)
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_overlap_bit_shift")
              asm.label("rt_overlap_bit_test")
              asm.and_a([:hl])
              asm.ret
            end

            # FADES AND TINTS. A Game Boy Color's display cannot mix colours as it draws, so a fade
            # is the colours in its lists moved — every palette's every colour, from the game's own
            # (art_palettes) into the copy the blank sends (SHADOW_PALETTES) — by +steps+
            # thirty-seconds of the way toward black, white or a colour, by the interpreter's rule
            # for a fade that walks the colours (Reference::Framebuffer#walked_toward and #mixed):
            #
            #   toward black: c - c × steps / 32
            #   toward white: c + (31 - c) × steps / 32
            #   toward a colour t: (c × (32 - steps) + t × steps) / 32
            #
            # rt_tint(toward, color, steps) does nothing when nothing changed, which is most
            # frames of a game that says its fade every frame.
            #
            # rt_tint_apply moves them again by the fade in force, from the colours they are drawn in
            # now: the art's, or +drawn_palettes+ for a game that draws a background in others.
            def emit_tint(asm, memory, drawn_palettes = nil)
              at = memory[TINT]
              arg = ->(i) { Calls.arg(memory, i, 3) }
              asm.label("rt_tint")
              asm.load_hl_sp(2)
              asm.load(:b, 12)
              asm.call("rt_take_args")
              asm.load_high(:a, arg.call(2)) # the steps, held to 0..32
              asm.load(:b, :a)
              asm.load_high(:a, arg.call(2) + 3)
              asm.bit(7, :a)
              asm.jump_relative(:z, "rt_tint_not_below")
              asm.load(:b, 0)
              asm.label("rt_tint_not_below")
              asm.load(:a, :b)
              asm.cp_a(STEPS + 1)
              asm.jump_relative(:c, "rt_tint_held")
              asm.load(:b, STEPS)
              asm.label("rt_tint_held")
              # The same as before: nothing to do. No steps at all is the colours as they are,
              # whatever they were moved toward.
              asm.load(:hl, at + 3)
              asm.load(:a, :b)
              asm.cp_a([:hl])
              asm.jump_relative(:nz, "rt_tint_changed")
              asm.and_a(:a)
              asm.ret(:z)
              asm.load_high(:a, arg.call(0))
              asm.load(:hl, at)
              asm.cp_a([:hl])
              asm.jump_relative(:nz, "rt_tint_changed")
              asm.load_high(:a, arg.call(1))
              asm.inc(:hl)
              asm.cp_a([:hl])
              asm.jump_relative(:nz, "rt_tint_changed")
              asm.load_high(:a, arg.call(1) + 1)
              asm.inc(:hl)
              asm.cp_a([:hl])
              asm.ret(:z)
              asm.label("rt_tint_changed")
              asm.load(:hl, at)
              asm.load_high(:a, arg.call(0))
              asm.load([:hli], :a)
              asm.load_high(:a, arg.call(1))
              asm.load([:hli], :a)
              asm.load_high(:a, arg.call(1) + 1)
              asm.load([:hli], :a)
              asm.load(:a, :b)
              asm.load([:hl], :a)
              # Every colour: its channels apart, each moved, and put back together.
              asm.label("rt_tint_apply")
              asm.load(:hl, drawn_palettes || "art_palettes")
              asm.load(:de, memory[SHADOW_PALETTES])
              asm.load(:c, 64)
              asm.label("rt_tint_color")
              asm.push(:bc)
              asm.push(:de)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a) # DE = the colour
              asm.push(:hl)
              asm.load(:a, :e)
              asm.and_a(CHANNEL_MAX)
              asm.load(:b, 0) # the colour's red, from the lowest bits
              asm.call("rt_tint_channel")
              asm.push(:af)
              # green: the top three bits of the low byte and the bottom two of the high one
              asm.load(:a, :e)
              asm.swap(:a)
              asm.srl(:a)
              asm.and_a(7)
              asm.load(:l, :a)
              asm.load(:a, :d)
              asm.and_a(3)
              3.times { asm.add_a(:a) }
              asm.or_a(:l)
              asm.and_a(CHANNEL_MAX)
              asm.load(:b, 1)
              asm.call("rt_tint_channel")
              asm.push(:af)
              asm.load(:a, :d)
              2.times { asm.srl(:a) }
              asm.and_a(CHANNEL_MAX)
              asm.load(:b, 2)
              asm.call("rt_tint_channel")
              # Back together: blue << 10 | green << 5 | red.
              asm.load(:d, :a) # blue
              asm.pop(:af)
              asm.load(:l, :a) # green
              asm.pop(:af)
              asm.load(:e, :a) # red
              asm.load(:a, :l)
              asm.swap(:a)
              asm.add_a(:a) # green's low three bits up to the top of the byte
              asm.and_a(0xE0)
              asm.or_a(:e)
              asm.load(:e, :a)
              asm.load(:a, :l)
              3.times { asm.srl(:a) }
              asm.load(:l, :a) # green's top two bits
              asm.load(:a, :d)
              2.times { asm.add_a(:a) }
              asm.or_a(:l)
              asm.load(:d, :a)
              asm.pop(:hl)
              asm.pop(:bc) # BC = where in the copy (pushed as DE)
              asm.load(:a, :e)
              asm.load([:bc], :a)
              asm.inc(:bc)
              asm.load(:a, :d)
              asm.load([:bc], :a)
              asm.inc(:bc)
              asm.load(:d, :b)
              asm.load(:e, :c)
              asm.pop(:bc)
              asm.dec(:c)
              asm.jump_relative(:nz, "rt_tint_color")
              asm.load(:a, 1)
              asm.load([memory[PALETTES_CHANGED]], :a)
              asm.ret

              # A = channel A (0..31) of a colour moved; B says which channel of the tint's colour
              # to move toward (0 red, 1 green, 2 blue). Keeps DE and HL.
              asm.label("rt_tint_channel")
              asm.push(:de)
              asm.push(:hl)
              asm.load(:c, :a) # the channel
              asm.load(:a, [at + 3])
              asm.load(:e, :a) # the steps
              asm.load(:a, [at])
              asm.cp_a(TOWARD_BLACK)
              asm.jump_relative(:z, "rt_tint_black")
              asm.cp_a(TOWARD_WHITE)
              asm.jump_relative(:z, "rt_tint_white")
              # Toward a colour: (c × (32 - s) + t × s) / 32.
              asm.push(:bc)
              asm.load(:a, STEPS)
              asm.sub_a(:e)
              asm.load(:d, :a)
              asm.load(:a, :c)
              asm.call("rt_times") # HL = c × (32 - s)
              asm.pop(:bc)
              asm.push(:hl)
              asm.call("rt_tint_wanted") # A = t's channel
              asm.load(:d, :e)
              asm.call("rt_times") # HL = t × s
              asm.pop(:de)
              asm.add_hl(:de)
              asm.jump_relative("rt_tint_thirty_seconds")
              asm.label("rt_tint_black") # c - c × s / 32
              asm.load(:d, :e)
              asm.load(:a, :c)
              asm.call("rt_times")
              asm.call("rt_tint_halve_five")
              asm.load(:b, :a)
              asm.load(:a, :c)
              asm.sub_a(:b)
              asm.jump_relative("rt_tint_done")
              asm.label("rt_tint_white") # c + (31 - c) × s / 32
              asm.load(:d, :e)
              asm.load(:a, CHANNEL_MAX)
              asm.sub_a(:c)
              asm.call("rt_times")
              asm.call("rt_tint_halve_five")
              asm.add_a(:c)
              asm.jump_relative("rt_tint_done")
              asm.label("rt_tint_thirty_seconds")
              asm.call("rt_tint_halve_five")
              asm.label("rt_tint_done")
              asm.pop(:hl)
              asm.pop(:de)
              asm.ret

              # A = HL / 32.
              asm.label("rt_tint_halve_five")
              5.times do
                asm.srl(:h)
                asm.rr(:l)
              end
              asm.load(:a, :l)
              asm.ret

              # A = channel B of the tint's colour.
              asm.label("rt_tint_wanted")
              asm.load(:a, [at + 1])
              asm.load(:l, :a)
              asm.load(:a, [at + 2])
              asm.load(:h, :a)
              asm.load(:a, :b)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_tint_wanted_shifted")
              asm.label("rt_tint_wanted_shift")
              5.times do
                asm.srl(:h)
                asm.rr(:l)
              end
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_tint_wanted_shift")
              asm.label("rt_tint_wanted_shifted")
              asm.load(:a, :l)
              asm.and_a(CHANNEL_MAX)
              asm.ret

              # HL = A × D, both small.
              asm.label("rt_times")
              asm.load(:hl, 0)
              asm.and_a(:a)
              asm.ret(:z)
              asm.push(:bc)
              asm.load(:c, :a)
              asm.load(:b, 0)
              asm.load(:a, :d)
              asm.label("rt_times_next")
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_times_done")
              asm.srl(:a)
              asm.jump_relative(:nc, "rt_times_skip")
              asm.add_hl(:bc)
              asm.label("rt_times_skip")
              asm.sla(:c)
              asm.rl(:b)
              asm.jump_relative("rt_times_next")
              asm.label("rt_times_done")
              asm.pop(:bc)
              asm.ret
            end
          end
        end
      end
    end
  end
end
