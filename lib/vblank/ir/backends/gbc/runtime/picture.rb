# frozen_string_literal: true

module VBlank
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
            # The display's switches the game wants, which the blank writes to the console's LCDC
            # register: the screen on or off, which grid the background is read from, and the
            # sprite layer on or off — all forty sprites at once, with the sprite table left as it
            # is (rt_sprites_on, rt_sprites_off).
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
            # sits along, worked out once a pass into a table of the bend's own (the lowering keeps
            # one for each bend) and shown from BENDS in the frame after, as the scroll is.
            # BENDS_FROM is the table of the background up, BENDING 1 while that background has a
            # bend (rt_bends_on, rt_bends_off), and BEND_BASE the scroll the shown rows are along
            # from.
            BENDS = "rt picture bends"
            BENDS_FROM = "rt picture bends from"
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
            # was lent this pass, so its colours are to be copied; and how many times a sprite found
            # all eight in use (LENT_MISSED bytes in, sixteen bits, held at the most it can count),
            # which a profile of the game reports (Diagnostics::GBCProfiler).
            LENT = "rt picture lent"
            LENT_MISSED = 8 + 3
            # 1 while the sprite being placed has yet to place a piece, so has borrowed no list.
            LENT_PENDING = LENT_MISSED + 2
            LENT_BYTES = LENT_PENDING + 1

            # A STATUS BAR (`status_bar`), in a game that has one: the console's window, read from
            # the second grid. BAR is the row its top is at, the number of the grid in the window's
            # grid (0xFF for none, or one with a cell changed), and 0xFF while the grid's rows are
            # still being copied in; BAR_JOB is that copy, kept as MAP_JOB keeps the background's.
            BAR = "rt picture bar"
            BAR_UP = 1
            BAR_PENDING = 2
            BAR_JOB = "rt picture bar job"
            # The window's left edge, which the console counts from seven pixels left of the screen.
            WINDOW_LEFT = 7

            # A GAME WHOSE SCREENS BRING THEIR OWN TILES IN (GBC::Art::Room): the number of the room
            # asked for last (nought for none), which is in picture memory once the blank after the
            # asking has brought it in; the one waiting for that blank (nought for none); and 1 while
            # the display is held off for it. rt_upload is then rt_tiles_bring_in around the plain
            # upload, which #emit_upload labels rt_upload_now.
            ROOMS = "rt picture rooms"
            ROOM_PENDING = 1
            ROOM_DISPLAY_OFF = 2

            # The display's switch that raises its interrupt as each line ends (STAT's mode-0 bit).
            STAT_HBLANK = 0x08

            # How many of the grid's 32 rows are copied in one blank: their tiles and their cells'
            # colours, 512 bytes, which the console's own copy does in about a quarter of the blank.
            MAP_ROWS_PER_BLANK = 8

            module_function

            def reserve(memory, lends: false, groups: false, bar_rows: nil, rooms: false)
              memory.reserve(ROOMS, 3) if rooms
              if bar_rows
                memory.reserve(BAR, 3)
                memory.reserve(BAR_JOB, 6)
              end
              memory.reserve(LENT, LENT_BYTES) if lends
              PictureGroups.reserve(memory) if groups
              memory.reserve(SHADOW_PALETTES, 128)
              memory.reserve(PALETTES_CHANGED, 1)
              memory.reserve(SCROLL, 2)
              memory.reserve(NEXT_SPRITE, 1)
              memory.reserve(MAP_JOB, 6)
              memory.reserve(CELLS, 1 + (CELLS_KEPT * CELL_BYTES))
              memory.reserve(BENDS, Console::GBCHardware::SCREEN_HEIGHT)
              memory.reserve(BENDS_FROM, 2)
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
            # which needs +drawn_palettes+. +palettes_in_use+ are the numbers of the palettes the game
            # can show, backgrounds' 0 to 7 and sprites' 8 to 15 (Art#palettes_in_use): a fade
            # moves those alone. +groups+ says it has pictures grouped by room (Runtime::PictureGroups).
            # +bar_rows+ is how many rows of the window's grid a game's status bars fill, the most of
            # any of them, or nil for a game with none.
            # +rooms+ says its screens bring their own tiles in (#emit_rooms), and +room_colors+ their
            # own colours with them, which needs +drawn_palettes+. +lent_families+ says its sprites'
            # lists that are lent come in families (Art#lent_family). +backdrop+ is the first screen's,
            # shown until the first frame, or nil where the first list holds it (Art#first_screen_backdrop).
            # +banked_colors+ says its backgrounds' colour tables are kept in banks (#emit_background_colors_far).
            def emit(asm, memory, sprite_tiles:, background_tiles:, runs: [], drawn_palettes: nil, lends: false,
                     palettes_in_use:, groups: false, bar_rows: nil, rooms: false, room_colors: false, lent_families: false,
                     backdrop: nil, banked_colors: false)
              emit_start(asm, memory, sprite_tiles: sprite_tiles, background_tiles: background_tiles,
                                      drawn_palettes: drawn_palettes, bar: !bar_rows.nil?, backdrop: backdrop)
              emit_rooms(asm, memory, colors: room_colors) if rooms
              emit_upload(asm, memory, groups: groups, bar: !bar_rows.nil?, label: rooms ? "rt_upload_now" : "rt_upload")
              emit_oam_dma_held(asm)
              PictureGroups.emit(asm, memory) if groups
              emit_tile_runs(asm, runs)
              emit_sprites(asm, memory, lends: lends)
              emit_lend_colors(asm, memory, drawn_palettes, families: lent_families) if lends
              emit_background(asm, memory, bar: !bar_rows.nil?)
              emit_bar(asm, memory, bar_rows) if bar_rows
              emit_choices(asm, memory)
              emit_overlap(asm, memory)
              emit_tint(asm, memory, drawn_palettes, palettes_in_use)
              emit_background_colors(asm, drawn_palettes) if drawn_palettes
              emit_background_colors_far(asm) if banked_colors
            end

            # The sprite's first piece going into the sprite table borrows its list (rt_lend_list)
            # and puts the one of the eight it is in into the sprite's attributes, at +attributes+,
            # for this piece and the rest. Keeps BC, DE and HL.
            def emit_lend_on_first_piece(asm, memory, attributes)
              pending = memory[LENT] + LENT_PENDING
              asm.load(:a, [pending])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_lend_on_first_piece_done")
              %i[bc de hl].each { |pair| asm.push(pair) }
              asm.xor_a(:a)
              asm.load([pending], :a)
              asm.load_high(:a, Calls.arg(memory, 0, 5))
              asm.inc(:a)
              asm.load(:c, :a) # the list, one up
              asm.call("rt_lend_list")
              asm.load_high(:a, attributes)
              asm.or_a(:e)
              asm.load_high(attributes, :a)
              %i[hl de bc].each { |pair| asm.pop(pair) }
              asm.label("rt_lend_on_first_piece_done")
            end

            # LENDING THE EIGHT SPRITE LISTS. A Color draws a sprite's piece in one of eight lists of
            # four colours. A game whose sprites wear more lists than that between them lends the
            # eight out, the way the console's own games do: rt_lend_list, with C the game's list
            # number (art_lent_palettes) one up, answers E, which of the eight a sprite wearing it is
            # placed in. rt_sprite asks it as the sprite's first piece goes into the sprite table
            # (LENT_PENDING), so a sprite that draws nothing — off the screen, or past the table's
            # forty — borrows nothing.
            #
            # One holding that list already is the answer. A list holding none takes one nothing was
            # placed in this pass or the pass before — so one a sprite placed later in this pass still
            # wears is never taken from under it — and its colours are copied into the colours drawn
            # now. rt_sprites_end moves them through the fade in force into the copy the blank sends,
            # so they reach the screen in the same blank as the sprite table that first reads them.
            # A list that finds none free takes one holding a list of its own family that nothing was
            # placed in this pass (+families+, #emit_lend_family), its colours copied in the same way:
            # a sprite stepping through its lists a frame at a time keeps the one it wore. A list that
            # still finds all eight in use is placed in the first, in whatever colours it holds, and
            # counted (LENT_MISSED), since nothing in the picture tells the author it happened.
            #
            # Like the Advance's lending, a list gives its one back only once a whole pass has gone
            # by without anything placed in it, since nothing says part way through a pass which lists
            # the rest will wear. So with all eight in use, a thing that comes on the pass another
            # goes is drawn for that pass in colours not its own.
            def emit_lend_colors(asm, memory, drawn_palettes, families: false)
              lent = memory[LENT]
              sprite_colors = drawn_palettes + 64
              asm.label("rt_lend_list")
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
              if families
                asm.call("rt_lend_family")
                asm.jump_relative(:nz, "rt_lend_take")
              end
              # Every one in use: counted, and placed in the first.
              asm.load(:hl, lent + LENT_MISSED)
              asm.inc([:hl])
              asm.jump_relative(:nz, "rt_lend_missed")
              asm.inc(:hl)
              asm.inc([:hl])
              asm.jump_relative(:nz, "rt_lend_missed")
              asm.dec([:hl]) # held at the most: 0xFFFF
              asm.dec(:hl)
              asm.dec([:hl])
              asm.label("rt_lend_missed")
              asm.load(:e, 0)
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
              asm.ret
              emit_lend_family(asm, lent) if families
            end

            # rt_lend_family: C = a list, one up, that found none of the eight free. One that holds a
            # list of its family (Art#lent_family) and that nothing was placed in this pass is
            # its: NZ, with HL at it, E which it is and D its bit, as rt_lend_take takes them. Z for
            # none. A sprite stepping through its lists takes the one it wore the frame before.
            def emit_lend_family(asm, lent)
              asm.label("rt_lend_family")
              asm.load(:a, :c)
              asm.call("rt_lend_family_of")
              asm.and_a(:a)
              asm.ret(:z) # a list of no family
              asm.load(:b, :a)
              asm.load(:hl, lent)
              asm.load(:de, 0x0100)
              asm.label("rt_lend_family_slot")
              asm.load(:a, [lent + 8])
              asm.and_a(:d)
              asm.jump_relative(:nz, "rt_lend_family_next") # worn this pass
              asm.load(:a, [:hl])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_lend_family_next")
              asm.call("rt_lend_family_of")
              asm.cp_a(:b)
              asm.jump_relative(:z, "rt_lend_family_found")
              asm.label("rt_lend_family_next")
              asm.inc(:hl)
              asm.inc(:e)
              asm.sla(:d)
              asm.jump_relative(:nz, "rt_lend_family_slot")
              asm.xor_a(:a) # Z: none
              asm.ret
              asm.label("rt_lend_family_found")
              asm.or_a(1) # NZ
              asm.ret

              # A = a list, one up: A = its family (0 for none). Keeps BC, DE and HL.
              asm.label("rt_lend_family_of")
              asm.push(:de)
              asm.push(:hl)
              asm.dec(:a)
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.load(:hl, "art_lent_families")
              asm.add_hl(:de)
              asm.load(:a, [:hl])
              asm.pop(:hl)
              asm.pop(:de)
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

            # rt_background_colors_far: the same, for a table kept in a bank of the cartridge (C), in a
            # game too big for the part always in view (GBC#build_cartridge): the bank is put in view
            # while it is read, and the game's put back after.
            def emit_background_colors_far(asm)
              asm.label("rt_background_colors_far")
              asm.load(:a, :c)
              asm.select_rom_bank
              asm.call("rt_background_colors")
              asm.jump("rt_bank_back")
            end

            # What a fade or a tint moves every colour toward: black, white, or a colour of the
            # game's.
            TOWARD_BLACK = 0
            TOWARD_WHITE = 1
            TOWARD_COLOR = 2

            # The palettes +numbers+ as runs of neighbours, [first, how many], for one walk each.
            def palette_runs(numbers)
              numbers.sort.slice_when { |a, b| b != a + 1 }.map { |run| [run.first, run.length] }
            end

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
            def emit_start(asm, memory, sprite_tiles:, background_tiles:, drawn_palettes: nil, bar: false, backdrop: nil)
              h = Console::GBCHardware
              asm.label("rt_picture_start")
              if bar # the window's grid holds no bar yet, and the window starts at the left edge
                asm.load(:a, 0xFF)
                asm.load([memory[BAR] + BAR_UP], :a)
                asm.load(:a, WINDOW_LEFT)
                asm.load_high(h::WX, :a)
              end
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
                asm.select_rom_bank
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
              if backdrop
                # The first screen's backdrop, which the screen shows until the first frame, in place
                # of the first list's first colour as the console is given the lists. The copy then
                # has its own back, and is sent at the first frame (Art#first_screen_backdrop).
                shadow = memory[SHADOW_PALETTES]
                asm.load(:a, backdrop & 0xFF)
                asm.load([shadow], :a)
                asm.load(:a, backdrop >> 8)
                asm.load([shadow + 1], :a)
                asm.call("rt_picture_write_palettes")
                asm.load(:hl, "art_palettes")
                asm.load(:a, [:hli])
                asm.load([shadow], :a)
                asm.load(:a, [:hl])
                asm.load([shadow + 1], :a)
                asm.load(:a, 1)
                asm.load([memory[PALETTES_CHANGED]], :a)
              else
                asm.call("rt_picture_write_palettes")
              end
              # The sprite layer starts on; a painted screen turns it off (rt_screen, rt_paint_start)
              # and the next sprite pass on a tiled one turns it on again (rt_sprites_end).
              asm.load(:a, h::LCDC_ON | h::LCDC_SPRITES_ON | h::LCDC_BG_PRIORITY)
              asm.load([memory[LCDC_WANTED]], :a)
              asm.ret

              # The bank the game had in view, back in view after the runtime borrowed the window.
              asm.label("rt_bank_back")
              asm.load_high(:a, Memory::CURRENT_BANK)
              asm.select_rom_bank
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

            # THE SPRITE TABLE'S COPY WITH INTERRUPTS HELD OFF. While the copy runs the processor can
            # read nothing but its quick memory, and every interrupt's routine is in the cartridge:
            # taken then, the processor would read nonsense and run it, until the console started
            # again. The copy starts as the blank does (rt_sleep_until_vblank), when the display
            # raises nothing, but the timer's interrupt comes when it comes in a game that plays a
            # recording, and a copy that starts late for any reason would meet the one that bends a
            # row (rt_hblank_interrupt). Held off, an interrupt is answered as soon as the copy is
            # done, which holds a recording's next sample back by a little. Every caller has
            # interrupts on, so they go back on.
            def emit_oam_dma_held(asm)
              asm.label("rt_oam_dma_held")
              asm.di
              asm.call(Memory::OAM_DMA)
              asm.ei
              asm.ret
            end

            # IN THE BLANK: the sprite table, the colours if they changed, the scroll and the
            # screen's switches; and a few more rows of a grid being put up. Carry set when a grid
            # is still being put up, so the frame waits for another blank before it counts as shown.
            #
            # The sprite table is not copied while a painted screen is up: the sprite layer is off
            # there (Paint#emit_screen), so nothing would show it, and the copy takes a fair part of
            # the blank the painted screen's tiles need. The blank that puts a tiled screen back up
            # copies it, as that screen's kind is up by then.
            #
            # The rows' bends are copied last. The blank is the only time video memory can be
            # written, and a grid being put up takes as much of it as it can; the bends are work
            # memory, which can be written at any time, so they wait until the video memory is done
            # with: a grid row written once the blank is over is lost, as the display is reading.
            #
            # In a game with pictures grouped by room (+groups+), the groups the sprites placed need
            # are copied in too (Runtime::PictureGroups), before the screen's switches, which keep the
            # sprite layer off while one is still being copied in.
            def emit_upload(asm, memory, groups: false, bar: false, label: "rt_upload")
              h = Console::GBCHardware
              pending = memory[PictureGroups::JOB] + PictureGroups::PENDING if groups
              asm.label(label)
              asm.load(:a, [memory[Paint::SCREEN_KIND]])
              asm.cp_a(Paint::PAINTED)
              asm.call(:nz, "rt_oam_dma_held")
              asm.load(:a, [memory[PALETTES_CHANGED]])
              asm.and_a(:a)
              asm.call(:nz, "rt_picture_write_palettes")
              asm.load(:hl, memory[SCROLL])
              asm.load(:a, [:hli])
              asm.load_high(h::SCX, :a)
              asm.load(:a, [:hl])
              asm.load_high(h::SCY, :a)
              if bar # the row the status bar's window starts at
                asm.load(:a, [memory[BAR]])
                asm.load_high(h::WY, :a)
              end
              asm.call("rt_bends_first_row")
              if groups
                asm.call("rt_groups_upload")
                asm.sbc_a(:a) # 0xFF while a group is still being copied in, nought once all are
                asm.load([pending], :a)
              end
              asm.load_high(:a, h::LCDC) # the screen's switches, left on if it is on
              asm.and_a(h::LCDC_ON)
              asm.load(:b, :a)
              asm.load(:a, [memory[LCDC_WANTED]])
              asm.and_a(~h::LCDC_ON & 0xFF)
              asm.or_a(:b)
              if groups
                asm.load(:c, :a)
                asm.load(:a, [pending])
                asm.cpl
                asm.or_a(~h::LCDC_SPRITES_ON & 0xFF)
                asm.and_a(:c)
              end
              asm.load_high(h::LCDC, :a)
              asm.call("rt_tile_runs_upload")
              # The cells a big map's view brought in (Runtime::BigMaps).
              asm.call("rt_big_view")
              # A grid being put up, and a painted screen's tiles: as much of each as the blank holds.
              # A status bar's grid first, which is a few rows: the carry says either has rows left,
              # and the cells changed wait for both.
              if bar
                asm.call("rt_bar_map_job")
                asm.sbc_a(:a)
                asm.load([memory[BAR] + BAR_PENDING], :a)
              end
              asm.call("rt_picture_map_job")
              if bar
                asm.jump_relative(:c, "rt_upload_jobs")
                asm.load(:a, [memory[BAR] + BAR_PENDING])
                asm.add_a(:a) # carry from 0xFF
                asm.label("rt_upload_jobs")
              end
              asm.push(:af)
              asm.call(:nc, "rt_picture_cells") # once the grid is all up, the cells changed since
              asm.call("rt_paint_upload")
              asm.call("rt_bends_copy")
              asm.jump_relative(:c, "rt_upload_more")
              if groups
                asm.load(:a, [pending])
                asm.add_a(:a) # carry from 0xFF
                asm.jump_relative(:c, "rt_upload_more")
              end
              asm.pop(:af)
              asm.ret
              asm.label("rt_upload_more")
              asm.pop(:af)
              asm.scf
              asm.ret

              # MAP_ROWS_PER_BLANK more rows of a grid being put up, or all of them while the screen
              # is off. Carry set when some are left.
              emit_map_job(asm, memory[MAP_JOB], "rt_picture_map_job", "rt_picture_map_rows")

              # THE ROWS' BENDS FOR THE FRAME ABOUT TO BE DRAWN, from the scroll just set: the first
              # row's set now, and each row after it as the line before it ends
              # (rt_hblank_interrupt), which is switched on here while the background up bends and
              # off while it does not. Switched in the blank, not where the game says, so the frame
              # being drawn as a pass changes it is drawn whole, as the pass before had it.
              asm.label("rt_bends_first_row")
              asm.load(:a, [memory[BENDING]])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_bends_first_row_flat")
              asm.load_high(:a, h::SCX)
              asm.load([memory[BEND_BASE]], :a)
              asm.load(:b, :a)
              asm.load(:a, [memory[BENDS_FROM]])
              asm.load(:l, :a)
              asm.load(:a, [memory[BENDS_FROM] + 1])
              asm.load(:h, :a)
              asm.load(:a, :b)
              asm.add_a([:hl])
              asm.load_high(h::SCX, :a)
              asm.load_high(:a, h::IE)
              asm.and_a(h::INT_STAT) # on already
              asm.ret(:nz)
              asm.load_high(:a, h::IF) # the line interrupt asked for while it was off is not answered
              asm.and_a(~h::INT_STAT & 0xFF)
              asm.load_high(h::IF, :a)
              asm.load_high(:a, h::STAT)
              asm.or_a(STAT_HBLANK)
              asm.load_high(h::STAT, :a)
              asm.load_high(:a, h::IE)
              asm.or_a(h::INT_STAT)
              asm.load_high(h::IE, :a)
              asm.ret
              asm.label("rt_bends_first_row_flat")
              asm.load_high(:a, h::IE)
              asm.and_a(~h::INT_STAT & 0xFF)
              asm.load_high(h::IE, :a)
              asm.ret

              # The rest of the rows into BENDS, for the line interrupt to read, after the blank's
              # video memory (rt_upload). It keeps ahead of the display: a row is copied many times
              # over in the time the display draws one line. Flags as they were, for rt_upload.
              asm.label("rt_bends_copy")
              asm.push(:af)
              asm.load(:a, [memory[BENDING]])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_bends_copy_done")
              asm.load(:a, [memory[BENDS_FROM]])
              asm.load(:l, :a)
              asm.load(:a, [memory[BENDS_FROM] + 1])
              asm.load(:h, :a)
              asm.load(:de, memory[BENDS])
              asm.load(:b, Console::GBCHardware::SCREEN_HEIGHT)
              asm.label("rt_bends_copy_row")
              asm.load(:a, [:hli])
              asm.load([:de], :a)
              asm.inc(:de)
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_bends_copy_row")
              asm.label("rt_bends_copy_done")
              asm.pop(:af)
              asm.ret

              # rt_bends_on(), HL the bend's table: a background with a bend is up, from the next
              # blank (rt_bends_first_row). rt_bends_off(): one without.
              asm.label("rt_bends_on")
              asm.load(:a, :l)
              asm.load([memory[BENDS_FROM]], :a)
              asm.load(:a, :h)
              asm.load([memory[BENDS_FROM] + 1], :a)
              asm.load(:a, 1)
              asm.load([memory[BENDING]], :a)
              asm.ret
              asm.label("rt_bends_off")
              asm.xor_a(:a)
              asm.load([memory[BENDING]], :a)
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
            # the last one written, and turns the sprite layer on when the screen up is drawn from
            # tiles (a painted one keeps it off: rt_screen). A sprite is its picture's pieces, each an entry; a piece
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
              asm.call("rt_picture_not_up_stop")
              if lends
                asm.load(:hl, memory[LENT] + 10)
                asm.load(:a, [:hl])
                asm.and_a(:a)
                asm.jump_relative(:z, "rt_sprites_end_lent")
                asm.load([:hl], 0)
                asm.call("rt_tint_apply")
                asm.label("rt_sprites_end_lent")
              end
              # The sprites shown from here, on a screen drawn from tiles (rt_screen).
              asm.load(:a, [memory[Paint::SCREEN_KIND]])
              asm.cp_a(Paint::PAINTED)
              asm.call(:nz, "rt_sprites_on")
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

              # The console's sprite layer on, or off, in the switches the blank writes (LCDC_WANTED).
              # Off hides every sprite at once; the table is kept either way, and so is the list of
              # what the game placed, which a reader of the run takes as what it drew.
              asm.label("rt_sprites_on")
              asm.load(:a, [memory[LCDC_WANTED]])
              asm.or_a(Console::GBCHardware::LCDC_SPRITES_ON)
              asm.load([memory[LCDC_WANTED]], :a)
              asm.ret
              asm.label("rt_sprites_off")
              asm.load(:a, [memory[LCDC_WANTED]])
              asm.and_a(~Console::GBCHardware::LCDC_SPRITES_ON & 0xFF)
              asm.load([memory[LCDC_WANTED]], :a)
              asm.ret

              # rt_sprite(picture, x, y, attributes): HL in the pictures' table is the picture's
              # pieces — a count, then for each its dx, dy, tile and bank. The attributes are the
              # palette and whether it is drawn behind the background (OBJ_BEHIND), as the sprite
              # table keeps them — in a game that lends its lists, with none of the eight named yet.
              # rt_sprite_fixed(record): the same, from a record in the cartridge of the four
              # numbers, sixteen bits each, put where rt_sprite's numbers are put. A game that lends
              # its lists places none this way (Lowering::Picture#fixed_sprite), and one that did
              # would borrow nothing.
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
              if lends
                asm.xor_a(:a)
                asm.load([memory[LENT] + LENT_PENDING], :a)
              end
              asm.jump_relative("rt_sprite_taken")

              # In a game that lends its lists, rt_sprite(list, picture, x, y, attributes): the list
              # handed first, so the other four keep their places, and lent as the first piece goes in.
              # rt_sprite_args_set is the same with the numbers written where rt_take_args puts them
              # already, by a caller that works each out with nothing that takes numbers of its own.
              asm.label("rt_sprite")
              asm.load_hl_sp(2)
              asm.load(:b, lends ? 20 : 16)
              asm.call("rt_take_args")
              asm.label("rt_sprite_args_set")
              if lends
                asm.load(:a, 1)
                asm.load([memory[LENT] + LENT_PENDING], :a)
              end
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
              asm.load_high(:a, args.call(0)) # the picture's entry: the table + 3 × its number
              asm.load(:l, :a)
              asm.load_high(:a, args.call(0) + 1)
              asm.load(:h, :a)
              # The pieces' bank in view while they are read, and the game's back after. Nothing
              # placing a piece switches it.
              emit_banked_entry(asm, "art_pictures")
              asm.load(:h, :d)
              asm.load(:l, :e) # HL = the picture's pieces
              asm.load(:a, [:hli])
              asm.and_a(:a)
              asm.jump(:z, "rt_bank_back")
              asm.load(:c, :a) # how many pieces
              asm.label("rt_sprite_piece")
              asm.push(:bc)
              asm.call("rt_gbc_place_piece")
              asm.pop(:bc)
              asm.dec(:c)
              asm.jump_relative(:nz, "rt_sprite_piece")
              asm.jump("rt_bank_back")

              # One piece at HL (dx, dy, tile, bank), HL moved past it: its place on the screen
              # worked out in 16 bits, and an entry written unless it is wholly off the screen or the
              # table is full.
              asm.label("rt_gbc_place_piece")
              # On the screen only when -8 < x < 160 and -8 < y < 144: x + 8 and y + 16 (the table's
              # places), worked out in 16 bits from the low halves of x and y, then fit a byte and
              # are not past the screen.
              # B = the table's x: x + dx + 8.
              asm.load_high(:a, args.call(1))
              asm.add_a([:hl])
              asm.load(:e, :a)
              asm.load_high(:a, args.call(1) + 1)
              asm.adc_a(0)
              asm.load(:d, :a)
              asm.inc(:hl)
              asm.load(:a, :e)
              asm.add_a(8)
              asm.load(:b, :a)
              asm.load(:a, :d)
              asm.adc_a(0)
              asm.jump_relative(:nz, "rt_gbc_piece_off_dy")
              asm.load(:a, :b)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_gbc_piece_off_dy")
              asm.cp_a(168)
              asm.jump_relative(:nc, "rt_gbc_piece_off_dy")
              # C = the table's y: y + dy + 16, on the screen when 9..159.
              asm.load_high(:a, args.call(2))
              asm.add_a([:hl])
              asm.load(:e, :a)
              asm.load_high(:a, args.call(2) + 1)
              asm.adc_a(0)
              asm.load(:d, :a)
              asm.inc(:hl)
              asm.load(:a, :e)
              asm.add_a(16)
              asm.load(:c, :a)
              asm.load(:a, :d)
              asm.adc_a(0)
              asm.jump_relative(:nz, "rt_gbc_piece_off")
              asm.load(:a, :c)
              asm.cp_a(9)
              asm.jump_relative(:c, "rt_gbc_piece_off")
              asm.cp_a(160)
              asm.jump_relative(:nc, "rt_gbc_piece_off")
              asm.load(:a, [memory[NEXT_SPRITE]])
              asm.cp_a(Console::GBCHardware::OAM_SIZE)
              asm.jump_relative(:nc, "rt_gbc_piece_off") # the table is full
              asm.load(:d, :h)
              asm.load(:e, :l) # DE = the piece's tile and bank
              asm.load(:l, :a)
              asm.add_a(4)
              asm.load([memory[NEXT_SPRITE]], :a)
              asm.load(:h, Memory::SHADOW_OAM >> 8)
              asm.load([:hl], :c)
              asm.inc(:l)
              asm.load([:hl], :b)
              asm.inc(:l)
              asm.load(:a, [:de])
              asm.load([:hli], :a)
              asm.inc(:de)
              asm.load(:a, [:de]) # the attributes: the piece's bank and mirroring, then the sprite's
              asm.inc(:de)
              asm.load(:b, :a)
              emit_lend_on_first_piece(asm, memory, args.call(3)) if lends
              asm.load_high(:a, args.call(3))
              asm.or_a(:b)
              asm.load([:hl], :a)
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.ret
              asm.label("rt_gbc_piece_off_dy") # HL at the piece's dy
              asm.inc(:hl)
              asm.label("rt_gbc_piece_off") # HL at its tile
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
            def emit_background_cell(asm, memory, label: "rt_background_cell", grid: Console::GBCHardware::TILE_MAP0,
                                     up: memory[GRID_UP])
              h = Console::GBCHardware
              arg = ->(i) { Calls.arg(memory, i, 4) }
              asm.label(label)
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
              asm.load(:de, grid)
              asm.add_hl(:de)
              asm.load(:a, 0xFF)
              asm.load([up], :a)
              # Into the cells for the blank, while there is room: HL where it goes, then the cell.
              asm.load(:a, [memory[CELLS]])
              asm.cp_a(CELLS_KEPT)
              asm.jump_relative(:nc, "#{label}_now")
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
              asm.label("#{label}_now")
              asm.di
              [0, 1].each do |bank|
                asm.load(:a, bank)
                asm.load_high(h::VBK, :a)
                asm.label("#{label}_wait_#{bank}")
                asm.load_high(:a, h::STAT)
                asm.and_a(0x02)
                asm.jump_relative(:nz, "#{label}_wait_#{bank}")
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
            #
            # rt_background_put_up_unscrolled(grid) is the same with the view put back at the
            # top-left corner first, even when the grid is up already: the blank copies SCROLL into
            # the console's two scroll registers, so the background is shown from its corner until
            # the game says where the view sits again. That is what a background's statement and a
            # scene's arrival put up with, as the Advance does (GBA::BackgroundDrawing
            # #emit_background_hardware) and the interpreter shows (Reference#put_up_background);
            # handing a background another of its maps keeps the view where it is (rt_big_show
            # likewise, beside rt_big_put_up).
            def emit_background(asm, memory, bar: false)
              h = Console::GBCHardware
              emit_background_cell(asm, memory)
              # ...and one of a status bar's, in the window's grid (#emit_bar).
              if bar
                emit_background_cell(asm, memory, label: "rt_bar_cell", grid: h::TILE_MAP1, up: memory[BAR] + BAR_UP)
              end
              asm.label("rt_background_put_up_unscrolled")
              asm.xor_a(:a)
              asm.load([memory[SCROLL]], :a)
              asm.load([memory[SCROLL] + 1], :a)
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

              emit_map_rows(asm, memory[MAP_JOB], "rt_picture_map_rows")

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

            # A SCREEN'S OWN TILES (GBC::Art::Room), brought in as it comes up.
            #
            # rt_tiles_put_up(room) says the room numbered +room+ is the one wanted, and does nothing
            # when it is in picture memory already. Its tiles are thousands of bytes — more than one
            # blank can copy while the display draws — so the blank after the pass that wanted it
            # holds the display off, copies them in at once, does the rest of its work (a grid put up
            # whole then, since the display is off) and switches the display back on (rt_upload, around
            # rt_upload_now). The picture is the screen's, whole, from the frame after: the one frame
            # the display is off shows nothing, which is the cut a game moving between two parts of a
            # big world makes anyway, rather than a picture half of old tiles and half of new.
            #
            # A game whose screens bring their own COLOURS in too (+colors+, Art#room_colors?) copies
            # the room's palettes (art_room_colors) into the colours drawn now as it asks, and those
            # through the fade or tint in force into the copy the blank sends (rt_background_colors):
            # so they reach the console in the same blank as the tiles, already faded as the rest.
            def emit_rooms(asm, memory, colors: false)
              h = Console::GBCHardware
              asm.label("rt_tiles_put_up")
              asm.load_hl_sp(2)
              asm.load(:a, [:hl]) # the room's number
              asm.load(:hl, memory[ROOMS])
              asm.cp_a([:hl])
              asm.ret(:z)
              asm.load([:hl], :a)
              asm.load([memory[ROOMS] + ROOM_PENDING], :a)
              if colors # its entry in the table, a word a room, one up
                asm.dec(:a)
                asm.add_a(:a)
                asm.load(:e, :a)
                asm.load(:d, 0)
                asm.load(:hl, "art_room_colors")
                asm.add_hl(:de)
                asm.load(:a, [:hli])
                asm.load(:h, [:hl])
                asm.load(:l, :a)
                asm.jump("rt_background_colors")
              else
                asm.ret
              end

              asm.label("rt_upload")
              asm.load(:a, [memory[ROOMS] + ROOM_PENDING])
              asm.and_a(:a)
              asm.call(:nz, "rt_tiles_bring_in")
              asm.call("rt_upload_now")
              asm.push(:af)
              asm.load(:a, [memory[ROOMS] + ROOM_DISPLAY_OFF])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_upload_display_on")
              asm.xor_a(:a)
              asm.load([memory[ROOMS] + ROOM_DISPLAY_OFF], :a)
              asm.load_high(:a, h::LCDC)
              asm.set(7, :a)
              asm.load_high(h::LCDC, :a)
              asm.label("rt_upload_display_on")
              asm.pop(:af)
              asm.ret

              # A = the room wanted: the display off, in the blank, and every chunk of the room's list
              # copied in by the console's own copy.
              asm.label("rt_tiles_bring_in")
              asm.add_a(:a) # its entry in the rooms' table, a word, one up
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.load(:hl, "art_rooms")
              asm.add_hl(:de)
              asm.dec(:hl)
              asm.dec(:hl)
              asm.load(:a, [:hli])
              asm.load(:h, [:hl])
              asm.load(:l, :a)
              asm.xor_a(:a)
              asm.load([memory[ROOMS] + ROOM_PENDING], :a)
              if colors # a room that brings colours alone in holds the display on: no chunk to copy
                asm.load(:a, [:hl])
                asm.and_a(:a)
                asm.ret(:z)
              end
              asm.load_high(:a, h::LCDC)
              asm.bit(7, :a)
              asm.jump_relative(:z, "rt_tiles_chunk") # off already
              asm.res(7, :a)
              asm.load_high(h::LCDC, :a)
              asm.load(:a, 1)
              asm.load([memory[ROOMS] + ROOM_DISPLAY_OFF], :a)
              asm.label("rt_tiles_chunk")
              asm.load(:a, [:hli]) # how many tiles: nought after the last chunk
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_tiles_brought_in")
              asm.dec(:a)
              asm.load(:c, :a) # blocks of 16, less one
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a) # DE = where they are
              asm.load(:a, [:hli])
              asm.select_rom_bank
              asm.load(:a, [:hli])
              asm.load_high(h::VBK, :a)
              asm.load(:a, [:hli])
              asm.load(:b, :a)
              asm.load(:a, [:hli]) # where they go: B low, A high
              asm.push(:hl)
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.load(:d, :a)
              asm.load(:e, :b)
              asm.call("rt_gdma")
              asm.pop(:hl)
              asm.jump_relative("rt_tiles_chunk")
              asm.label("rt_tiles_brought_in")
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              asm.jump("rt_bank_back")
            end

            # A GRID BEING PUT UP, a few rows a blank: +job+ is where it is kept — the rows left,
            # where the next comes from, where it goes and the bank it is in (MAP_JOB, BAR_JOB).
            # +label+ copies MAP_ROWS_PER_BLANK more rows, or all of them while the screen is off;
            # +rows+ is that copy alone.
            def emit_map_job(asm, job, label, rows)
              asm.label(label)
              asm.load(:a, [job])
              asm.and_a(:a)
              asm.ret(:z) # nothing being put up: carry clear from the AND
              asm.call(rows)
              asm.load(:a, [job])
              asm.and_a(:a)
              asm.ret(:z)
              asm.scf
              asm.ret
            end

            # The next rows of the grid being put up, from where +job+ has got to — all of them
            # while the screen is off, MAP_ROWS_PER_BLANK in a blank — each row's 32 tiles into
            # bank 0 of the console's grid and its 32 cells' colours, 1024 bytes on, into bank 1.
            def emit_map_rows(asm, job, label)
              h = Console::GBCHardware
              asm.label(label)
              asm.load_high(:a, h::LCDC)
              asm.bit(7, :a)
              asm.load(:b, 32)
              asm.jump_relative(:z, "#{label}_counted")
              asm.load(:b, MAP_ROWS_PER_BLANK)
              asm.label("#{label}_counted")
              asm.load(:a, [job])
              asm.cp_a(:b)
              asm.jump_relative(:nc, "#{label}_some")
              asm.load(:b, :a) # fewer left than that: the rest
              asm.label("#{label}_some")
              asm.sub_a(:b)
              asm.load([job], :a)
              asm.load(:a, [job + 5])
              asm.select_rom_bank
              asm.load(:a, :b) # rows × 32 bytes = rows × 2 blocks of 16
              asm.add_a(:a)
              asm.dec(:a)
              asm.load(:c, :a)
              asm.push(:bc)
              asm.load(:a, [job + 1]) # HL = where these rows come from
              asm.load(:l, :a)
              asm.load(:a, [job + 2])
              asm.load(:h, :a)
              asm.load(:a, [job + 3]) # DE = where they go
              asm.load(:e, :a)
              asm.load(:a, [job + 4])
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
              asm.load([job + 1], :a)
              asm.load(:a, :h)
              asm.load([job + 2], :a)
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.add_hl(:bc) # ...and goes just past these
              asm.load(:a, :l)
              asm.load([job + 3], :a)
              asm.load(:a, :h)
              asm.load([job + 4], :a)
              asm.jump("rt_bank_back")
            end

            # THE STATUS BAR (Reference#paint_status_bar): the console's window, which the display
            # draws from its top row, WY, to the bottom of the screen, over the background and under
            # the sprites, reading its cells from the second grid. The bar's grid goes there; the
            # window is switched on in the display's switches the blank writes (LCDC_WANTED), and WY
            # is written from BAR in the blank (rt_upload).
            #
            # rt_bar_put_up(grid, top): the bar's grid into the window's — +rows+ of it, the most any
            # bar of the game fills, so a shorter bar after a taller one leaves none of it behind —
            # unless it is the one there already, with the window on and its top at +top+, the row
            # the bar was declared at, until it is placed (Reference#bar_top_shown).
            # rt_place_bar(top): its top at +top+, kept between 0 and the bottom of the screen.
            # rt_bar_take_down: the window off, for a screen with no bar; and its grid forgotten too
            # when the kind of screen changes, since a painted screen keeps its own grid there.
            def emit_bar(asm, memory, rows)
              h = Console::GBCHardware
              top = Calls.arg(memory, 0, 1)
              asm.label("rt_bar_put_up")
              asm.load_hl_sp(2)
              asm.load(:a, [:hl]) # the top, a row of the screen already
              asm.load([memory[BAR]], :a)
              asm.load_hl_sp(6)
              asm.load(:a, [:hl]) # the grid's number
              asm.load(:hl, memory[BAR] + BAR_UP)
              asm.cp_a([:hl])
              asm.jump_relative(:z, "rt_bar_on")
              asm.load([:hl], :a)
              asm.load(:e, :a) # its entry in the grids' table, three bytes
              asm.load(:d, 0)
              asm.load(:hl, "art_grids")
              3.times { asm.add_hl(:de) }
              asm.load(:a, [:hli])
              asm.load([memory[BAR_JOB] + 1], :a)
              asm.load(:a, [:hli])
              asm.load([memory[BAR_JOB] + 2], :a)
              asm.load(:a, [:hl])
              asm.load([memory[BAR_JOB] + 5], :a)
              asm.xor_a(:a)
              asm.load([memory[BAR_JOB] + 3], :a)
              asm.load(:a, h::TILE_MAP1 >> 8)
              asm.load([memory[BAR_JOB] + 4], :a)
              asm.load(:a, rows)
              asm.load([memory[BAR_JOB]], :a)
              asm.load_high(:a, h::LCDC) # with the screen off it goes in now
              asm.bit(7, :a)
              asm.call(:z, "rt_bar_map_rows")
              asm.label("rt_bar_on")
              asm.load(:a, [memory[LCDC_WANTED]])
              asm.or_a(h::LCDC_WINDOW_ON | h::LCDC_WINDOW_MAP1)
              asm.load([memory[LCDC_WANTED]], :a)
              asm.ret

              asm.label("rt_place_bar")
              asm.load_hl_sp(2)
              asm.load(:b, 4)
              asm.call("rt_take_args")
              asm.load_high(:a, top + 3)
              asm.bit(7, :a)
              asm.jump_relative(:nz, "rt_place_bar_top") # above the top: the top
              asm.load(:b, :a)
              asm.load_high(:a, top + 2)
              asm.or_a(:b)
              asm.load(:b, :a)
              asm.load_high(:a, top + 1)
              asm.or_a(:b)
              asm.load(:a, h::SCREEN_HEIGHT)
              asm.jump_relative(:nz, "rt_place_bar_at") # far past the bottom: the bottom
              asm.load_high(:a, top)
              asm.cp_a(h::SCREEN_HEIGHT)
              asm.jump_relative(:c, "rt_place_bar_at")
              asm.load(:a, h::SCREEN_HEIGHT)
              asm.jump_relative("rt_place_bar_at")
              asm.label("rt_place_bar_top")
              asm.xor_a(:a)
              asm.label("rt_place_bar_at")
              asm.load([memory[BAR]], :a)
              asm.ret

              asm.label("rt_bar_take_down")
              asm.load(:a, 0xFF)
              asm.load([memory[BAR] + BAR_UP], :a)
              asm.label("rt_bar_off")
              asm.load(:a, [memory[LCDC_WANTED]])
              asm.and_a(~h::LCDC_WINDOW_ON & 0xFF)
              asm.load([memory[LCDC_WANTED]], :a)
              asm.ret

              emit_map_job(asm, memory[BAR_JOB], "rt_bar_map_job", "rt_bar_map_rows")
              emit_map_rows(asm, memory[BAR_JOB], "rt_bar_map_rows")
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
              # A number of a byte, which it almost always is, against +others+ (16 bits at most)
              # where the two are; any bigger one by rt_cmp32.
              asm.load(:b, :a)
              asm.load_high(:a, which + 2)
              asm.or_a(:b)
              asm.load(:b, :a)
              asm.load_high(:a, which + 1)
              asm.or_a(:b)
              asm.jump_relative(:nz, "rt_place_of_choice_wide")
              asm.load_high(:a, others + 1)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_place_of_choice_below") # 256 others or more: a byte is below
              asm.load_high(:a, others)
              asm.load(:b, :a)
              asm.load_high(:a, which)
              asm.cp_a(:b)
              asm.jump_relative(:nc, "rt_place_of_choice_own")
              asm.label("rt_place_of_choice_below")
              asm.load_high(:a, which)
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.load(:bc, 0)
              asm.inc(:de) # which + 1
              asm.ret
              asm.label("rt_place_of_choice_wide")
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

            # A SPRITE PICTURE'S ENTRY IN +table+ (art_pictures, art_masks): three bytes for each
            # picture, where its data is and the bank of the cartridge it is in (GBC::Art). With the
            # picture's number in HL, this leaves DE where its data is, that bank in view, and the
            # bank's number in A.
            def emit_banked_entry(asm, table)
              asm.load(:d, :h)
              asm.load(:e, :l)
              asm.add_hl(:hl)
              asm.add_hl(:de)
              asm.load(:de, table)
              asm.add_hl(:de)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:a, [:hl])
              asm.select_rom_bank
            end

            # The collision's working memory: a record for each of the two masks (width, height,
            # bytes a row, its bank, where its rows start), then the walk's own seven bytes.
            MASK_RECORD_BYTES = 6
            OVERLAP_BYTES = (2 * MASK_RECORD_BYTES) + 7

            # PIXELS TOUCHING. rt_pixels_overlap(a, b, dx, dy): 1 when sprite picture +a+ and
            # sprite picture +b+, b standing dx across and dy down from a, draw a pixel in the same
            # place (Reference#pixels_overlap?). Each picture's MASK (GBC::Art) is a bit for every
            # pixel, set where it draws; only the rectangle where the two pictures meet is walked,
            # and nothing at all when they do not meet. A picture is at most 64 pixels each way, so
            # two that meet are less than 64 apart and every number here fits a byte.
            #
            # The two masks can be in different banks of the cartridge (GBC::Art#picture_section),
            # and only one bank is in view at a time, so each read of a mask puts its own bank in
            # view (rt_overlap_bit), and the game's goes back at the end.
            def emit_overlap(asm, memory)
              at = memory[OVERLAP]
              a_mask = at # width, height, bytes a row, its bank, where its rows start
              b_mask = at + MASK_RECORD_BYTES
              dx, dy, x_first, x_past, y_now, y_past, x_now = (0...7).map { |i| at + (2 * MASK_RECORD_BYTES) + i }
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
              asm.jump("rt_bank_back")
              asm.label("rt_overlap_no")
              asm.load(:bc, 0)
              asm.load(:de, 0)
              asm.jump("rt_bank_back")

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
              # a row, its bank, and where its rows start. Leaves its bank in view.
              asm.label("rt_overlap_mask")
              asm.load(:a, [:hli])
              asm.load(:h, [:hl])
              asm.load(:l, :a)
              asm.push(:de)
              emit_banked_entry(asm, "art_masks")
              asm.load(:b, :a)
              asm.load(:h, :d)
              asm.load(:l, :e) # HL = the mask
              asm.pop(:de)
              3.times do
                asm.load(:a, [:hli])
                asm.load([:de], :a)
                asm.inc(:de)
              end
              asm.load(:a, :b)
              asm.load([:de], :a)
              asm.inc(:de)
              asm.load(:a, :l)
              asm.load([:de], :a)
              asm.inc(:de)
              asm.load(:a, :h)
              asm.load([:de], :a)
              asm.ret

              # NZ when the pixel at (D, E) of a mask is drawn; HL is the mask's bytes a row, and its
              # bank and where its rows start just after that. Leaves that bank in view.
              asm.label("rt_overlap_bit")
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.select_rom_bank
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
            def emit_tint(asm, memory, drawn_palettes, palettes_in_use)
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
              # Every colour of the palettes the game uses: its channels apart, each moved, and put
              # back together. The others are never shown, so are left as they are. With no fade or
              # tint in force every colour stays as it is, so the colours are copied across as they
              # are — a few instructions a colour rather than a few hundred, which is what lets a
              # game that fades by stepping its lists itself (`draw_with` every frame) keep a pass a
              # frame.
              asm.label("rt_tint_apply")
              asm.load(:a, [at + 3])
              asm.and_a(:a)
              asm.jump(:z, "rt_tint_copy")
              # HL = where palette +first+'s colours are drawn from now, DE = where in the copy.
              from_and_to = lambda do |first|
                asm.load(:hl, drawn_palettes ? drawn_palettes + (first * 8) : "art_palettes")
                if !drawn_palettes && first.positive?
                  asm.load(:de, first * 8)
                  asm.add_hl(:de)
                end
                asm.load(:de, memory[SHADOW_PALETTES] + (first * 8))
              end
              palette_runs(palettes_in_use).each do |first, count|
                from_and_to.call(first)
                asm.load(:c, count * Art::PLACES)
                asm.call("rt_tint_colors")
              end
              asm.label("rt_tint_applied")
              asm.load(:a, 1)
              asm.load([memory[PALETTES_CHANGED]], :a)
              asm.ret
              asm.label("rt_tint_copy")
              palette_runs(palettes_in_use).each do |first, count|
                from_and_to.call(first)
                asm.load(:b, count * 8)
                asm.call("rt_copy_b")
              end
              asm.jump("rt_tint_applied")
              # C colours from HL into the copy at DE.
              asm.label("rt_tint_colors")
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
              asm.jump_relative(:nz, "rt_tint_colors")
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
