# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # A MAP BIGGER THAN THE COLOR'S GRID. The console draws its background from a grid of
          # 32×32 cells that wraps round, 256 pixels each way, and its screen shows 20×18 of them —
          # 21×19 once the view is part way across a cell. So a bigger map is kept whole in the
          # cartridge (GBC::Art#big_map: each cell's tile and its colours, a row to a section), and
          # the cells the view is over are put in the grid as the view moves. Where a cell of the map
          # lands in the grid is its column and row, each counted round 32, so the grid always holds
          # the view's cells however far across the map the view is.
          #
          # The blank is too short to work cells out in, so that is done in the pass, as the game
          # moves the view (rt_background_scroll), into a copy of the grid in work memory (+buffer+,
          # laid out as GBC::Art lays out a grid). A view one cell along brings in one column and one
          # row, which go in a list (+staged+) the blank copies into the console's grid; anything
          # further — a jump, or the map just put up — is the whole view, and the whole copy goes in
          # by the console's own copying, as a grid put up does (Runtime::Picture's MAP_JOB), the frame
          # waiting for it.
          #
          # A cell past the map's edge is nothing, the backdrop.
          module BigMaps
            STATE = "rt big map"
            ON = 0 # 1 while a big map is up
            MAP = 1 # where its table of rows is (GBC::Art#big_map), and a byte unused
            COLS = 4
            ROWS = 5
            WANT = 6 # the view's top-left cell, x then y, 16 bits each, below nought allowed
            DRAWN = 10 # ...and the one the grid holds the cells around
            VALID = 14 # 1 once the grid holds a whole view
            STAGING = 15 # 1 while cells worked out go in the list for the blank too
            CELL = 16 # the cell being worked out, x then y
            COUNT = 20
            ALONG_Y = 21 # 1 to step down a column, 0 along a row
            STEP_X = 22
            STEP_Y = 23
            BYTES = 24

            # The cells the screen shows, across and down, with the one the view is part way into.
            VIEW_COLS = (Console::GBCHardware::SCREEN_WIDTH / 8) + 1
            VIEW_ROWS = (Console::GBCHardware::SCREEN_HEIGHT / 8) + 1

            # Bytes an entry of the big maps' table takes: where its rows are, a byte unused, its size.
            ENTRY_BYTES = 5

            # The copy of the grid: the cells' tiles, then their colours.
            BUFFER_BYTES = 2048

            # The list for the blank: how many, then each cell's place in the grid, tile and colours.
            STAGED_MOST = 64
            STAGED_BYTES = 1 + (STAGED_MOST * 4)

            module_function

            def reserve(memory) = memory.reserve(STATE, BYTES)

            # +buffer+ and +staged+ are where the copy of the grid and the list for the blank are,
            # or nil for a game with no map bigger than the grid.
            def emit(asm, memory, buffer: nil, staged: nil)
              at = memory[STATE]
              emit_want(asm)
              return emit_none(asm) unless buffer

              emit_put_up(asm, memory, at)
              emit_copy_in(asm, at)
              emit_set(asm, at, staged)
              emit_prepare(asm, memory, at, buffer, staged)
              emit_cells(asm, at, buffer, staged)
              emit_view(asm, staged)
            end

            def emit_none(asm)
              asm.label("rt_big_prepare")
              asm.label("rt_big_view")
              asm.and_a(:a) # carry clear
              asm.ret
            end

            # rt_big_want: DE = the view's x or y in pixels, made the cell it is in.
            def emit_want(asm)
              asm.label("rt_big_want")
              3.times do
                asm.sra(:d)
                asm.rr(:e)
              end
              asm.ret
            end

            # rt_big_put_up(map): big map +map+ of the table (art_big_maps) up as declared — its view at
            # the top-left corner, as a background put up again is (Reference#take_over) — and its
            # whole view worked out and put in. Whatever grid was up is not any more.
            #
            # rt_big_show(map): the same with the view left where it is: the background handed
            # another of its maps (Reference#exec_show_map).
            def emit_put_up(asm, memory, at)
              asm.label("rt_big_put_up")
              asm.xor_a(:a)
              asm.load(:hl, at + WANT)
              4.times { asm.load([:hli], :a) }
              asm.load(:hl, memory[Picture::SCROLL])
              asm.load([:hli], :a)
              asm.load([:hl], :a)
              asm.label("rt_big_show")
              asm.load_hl_sp(2)
              asm.load(:a, [:hl])
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.load(:hl, "art_big_maps")
              ENTRY_BYTES.times { asm.add_hl(:de) }
              asm.load(:de, at + MAP)
              asm.load(:b, ENTRY_BYTES)
              asm.call("rt_copy_b")
              asm.xor_a(:a)
              asm.load([at + VALID], :a)
              asm.load(:a, 0xFF)
              asm.load([memory[Picture::GRID_UP]], :a)
              asm.load(:a, 1)
              asm.load([at + ON], :a)
              asm.jump("rt_big_prepare")
            end

            # A BIG MAP THE GAME CHANGES (`set_tile`) is kept in work memory while it is up, so a cell
            # changed stays changed as the view moves away and back; put up again it is as declared.
            #
            # rt_big_copy_in(map, to): big map +map+ of the table, from the cartridge, a row after
            # another into work memory at +to+.
            def emit_copy_in(asm, at)
              asm.label("rt_big_copy_in")
              asm.load_hl_sp(6)
              asm.load(:a, [:hl])
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.load(:hl, "art_big_maps")
              ENTRY_BYTES.times { asm.add_hl(:de) }
              asm.load(:a, [:hli]) # where its rows are
              asm.load([at + CELL], :a)
              asm.load(:a, [:hli])
              asm.load([at + CELL + 1], :a)
              asm.inc(:hl)
              asm.load(:a, [:hli]) # a row's bytes: its columns × 2
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.load(:a, [:hl])
              asm.load([at + COUNT], :a)
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.add_hl(:hl)
              asm.load(:a, :l)
              asm.load([at + CELL + 2], :a)
              asm.load(:a, :h)
              asm.load([at + CELL + 3], :a)
              asm.load_hl_sp(2)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hl])
              asm.load(:d, :a)
              asm.push(:de)
              asm.label("rt_big_copy_in_row")
              asm.load(:a, [at + CELL])
              asm.load(:l, :a)
              asm.load(:a, [at + CELL + 1])
              asm.load(:h, :a)
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.load(:b, :a)
              asm.load(:a, [:hli])
              asm.select_rom_bank
              asm.load(:a, :l)
              asm.load([at + CELL], :a)
              asm.load(:a, :h)
              asm.load([at + CELL + 1], :a)
              asm.load(:h, :b)
              asm.load(:l, :c)
              asm.load(:a, [at + CELL + 2])
              asm.load(:c, :a)
              asm.load(:a, [at + CELL + 3])
              asm.load(:b, :a)
              asm.pop(:de)
              asm.call("rt_copy_bc")
              asm.push(:de)
              asm.load(:hl, at + COUNT)
              asm.dec([:hl])
              asm.jump_relative(:nz, "rt_big_copy_in_row")
              asm.pop(:de)
              asm.jump("rt_bank_back")
            end

            # rt_big_set(col, row, cell): the cell of the big map up at (+col+, +row+) made +cell+ —
            # its tile in the low byte and its colours in the next — in work memory, and in the grid
            # too while the view is over it. A cell off the map changes nothing.
            def emit_set(asm, at, staged)
              asm.label("rt_big_set")
              asm.load(:a, [at + ON])
              asm.and_a(:a)
              asm.ret(:z)
              # On the map: both at nought or above and below its size (the high bytes nought).
              [[10, COLS, CELL], [6, ROWS, CELL + 2]].each do |from, size, cell|
                asm.load_hl_sp(from + 1)
                asm.load(:a, [:hli])
                asm.or_a([:hl])
                asm.inc(:hl)
                asm.or_a([:hl])
                asm.ret(:nz)
                asm.load_hl_sp(from)
                asm.load(:a, [:hl])
                asm.load(:hl, at + size)
                asm.cp_a([:hl])
                asm.ret(:nc)
                asm.load([at + cell], :a)
                asm.xor_a(:a)
                asm.load([at + cell + 1], :a)
              end
              # Its two bytes in work memory: its row's place (the map's table of rows) + col × 2.
              asm.load(:a, [at + CELL + 2])
              asm.load(:l, :a)
              asm.load(:h, 0)
              asm.load(:d, :h)
              asm.load(:e, :l)
              asm.add_hl(:hl)
              asm.add_hl(:de)
              asm.load(:a, [at + MAP])
              asm.load(:e, :a)
              asm.load(:a, [at + MAP + 1])
              asm.load(:d, :a)
              asm.add_hl(:de)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hl])
              asm.load(:d, :a)
              asm.load(:a, [at + CELL])
              asm.load(:l, :a)
              asm.load(:h, 0)
              asm.add_hl(:hl)
              asm.add_hl(:de)
              asm.push(:hl)
              asm.load_hl_sp(4) # the cell, past the place just pushed
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hl])
              asm.pop(:hl)
              asm.load([:hl], :e)
              asm.inc(:hl)
              asm.load([:hl], :a)
              # In the view the grid holds: column and row each less than the view's size past its corner.
              [[CELL, DRAWN, VIEW_COLS], [CELL + 2, DRAWN + 2, VIEW_ROWS]].each do |cell, drawn, size|
                asm.load(:a, [at + drawn])
                asm.load(:c, :a)
                asm.load(:a, [at + drawn + 1])
                asm.load(:b, :a)
                asm.load(:a, [at + cell])
                asm.sub_a(:c)
                asm.load(:c, :a)
                asm.load(:a, 0)
                asm.sbc_a(:b)
                asm.ret(:nz)
                asm.load(:a, :c)
                asm.cp_a(size)
                asm.ret(:nc)
              end
              asm.load(:a, [staged])
              asm.cp_a(STAGED_MOST)
              asm.jump(:nc, "rt_big_prepare_whole")
              asm.load(:a, 1)
              asm.load([at + STAGING], :a)
              asm.load(:b, 0)
              asm.jump("rt_big_cells")
            end

            # rt_big_prepare, in the pass: what the view's move needs worked out — one column and one
            # row for a cell's move, the whole view for anything else.
            def emit_prepare(asm, memory, at, buffer, staged)
              asm.label("rt_big_prepare")
              asm.load(:a, [at + ON])
              asm.and_a(:a)
              asm.ret(:z)
              asm.load(:a, [at + VALID])
              asm.and_a(:a)
              asm.jump(:z, "rt_big_prepare_whole")
              [[WANT, DRAWN, STEP_X], [WANT + 2, DRAWN + 2, STEP_Y]].each do |want, drawn, step|
                asm.load(:hl, at + want)
                asm.load(:de, at + drawn)
                asm.call("rt_big_step")
                asm.load([at + step], :a)
                asm.cp_a(2)
                asm.jump(:z, "rt_big_prepare_whole")
              end
              # Room in the list for a column and a row, or the whole view after all.
              asm.load(:a, [staged])
              asm.cp_a(STAGED_MOST - VIEW_COLS - VIEW_ROWS + 1)
              asm.jump(:nc, "rt_big_prepare_whole")
              asm.call("rt_big_drawn_is_wanted")
              asm.load(:a, 1)
              asm.load([at + STAGING], :a)
              # One cell across: the column coming into view, at the left or past the right.
              asm.load(:a, [at + STEP_X])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_big_prepare_down")
              asm.cp_a(1)
              asm.load(:a, 0)
              asm.jump_relative(:nz, "rt_big_prepare_left")
              asm.load(:a, VIEW_COLS - 1)
              asm.label("rt_big_prepare_left")
              asm.load(:b, 0)
              asm.call("rt_big_from_want")
              asm.load(:a, VIEW_ROWS)
              asm.load(:b, 1)
              asm.call("rt_big_cells")
              asm.label("rt_big_prepare_down")
              # One cell down: the row coming into view, at the top or past the bottom.
              asm.load(:a, [at + STEP_Y])
              asm.and_a(:a)
              asm.ret(:z)
              asm.cp_a(1)
              asm.load(:b, 0)
              asm.jump_relative(:nz, "rt_big_prepare_top")
              asm.load(:b, VIEW_ROWS - 1)
              asm.label("rt_big_prepare_top")
              asm.xor_a(:a)
              asm.call("rt_big_from_want")
              asm.load(:a, VIEW_COLS)
              asm.load(:b, 0)
              asm.jump("rt_big_cells")

              # The whole view into the copy, row by row, and the whole copy put up from the next
              # blank on.
              asm.label("rt_big_prepare_whole")
              asm.call("rt_big_drawn_is_wanted")
              asm.xor_a(:a)
              asm.load([at + STAGING], :a)
              asm.load([staged], :a) # the whole copy goes in: nothing left to copy cell by cell
              asm.inc(:a)
              asm.load([at + VALID], :a)
              asm.load(:c, 0)
              asm.label("rt_big_prepare_row")
              asm.push(:bc)
              asm.load(:b, :c)
              asm.xor_a(:a)
              asm.call("rt_big_from_want")
              asm.load(:a, VIEW_COLS)
              asm.load(:b, 0)
              asm.call("rt_big_cells")
              asm.pop(:bc)
              asm.inc(:c)
              asm.load(:a, :c)
              asm.cp_a(VIEW_ROWS)
              asm.jump_relative(:nz, "rt_big_prepare_row")
              job = memory[Picture::MAP_JOB]
              asm.load(:a, buffer & 0xFF)
              asm.load([job + 1], :a)
              asm.load(:a, buffer >> 8)
              asm.load([job + 2], :a)
              asm.xor_a(:a)
              asm.load([job + 3], :a)
              asm.load(:a, Console::GBCHardware::TILE_MAP0 >> 8)
              asm.load([job + 4], :a)
              asm.load_high(:a, Memory::CURRENT_BANK)
              asm.load([job + 5], :a)
              asm.load(:a, 32)
              asm.load([job], :a)
              asm.ret

              # rt_big_step: HL = a wanted cell's x or y, DE = the drawn one's: A = 0 the same, 1 one
              # further, 0xFF one back, 2 any further than that.
              asm.label("rt_big_step")
              asm.load(:a, [:de])
              asm.load(:c, :a)
              asm.inc(:de)
              asm.load(:a, [:de])
              asm.load(:b, :a)
              asm.load(:a, [:hli])
              asm.sub_a(:c)
              asm.load(:c, :a)
              asm.load(:a, [:hl])
              asm.sbc_a(:b)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_big_step_back")
              asm.load(:a, :c)
              asm.cp_a(2)
              asm.ret(:c)
              asm.load(:a, 2)
              asm.ret
              asm.label("rt_big_step_back")
              asm.inc(:a)
              asm.jump_relative(:nz, "rt_big_step_far")
              asm.load(:a, :c)
              asm.cp_a(0xFF)
              asm.ret(:z)
              asm.label("rt_big_step_far")
              asm.load(:a, 2)
              asm.ret

              asm.label("rt_big_drawn_is_wanted")
              asm.load(:hl, at + WANT)
              asm.load(:de, at + DRAWN)
              asm.load(:b, 4)
              asm.jump("rt_copy_b")

              # rt_big_from_want: the cell to work out from is A across and B down from the view's.
              asm.label("rt_big_from_want")
              [[WANT, CELL, :a], [WANT + 2, CELL + 2, :b]].each do |want, cell, by|
                asm.load(:e, by)
                asm.load(:a, [at + want])
                asm.add_a(:e)
                asm.load([at + cell], :a)
                asm.load(:a, [at + want + 1])
                asm.adc_a(0)
                asm.load([at + cell + 1], :a)
              end
              asm.ret
            end

            # rt_big_cells: A cells from CELL, along a row (B = 0) or down a column (B = 1), each its
            # tile and colours into the copy of the grid — and into the list for the blank while
            # STAGING says so.
            def emit_cells(asm, at, buffer, staged)
              h = Console::GBCHardware
              asm.label("rt_big_cells")
              asm.load([at + COUNT], :a)
              asm.load(:a, :b)
              asm.load([at + ALONG_Y], :a)
              asm.label("rt_big_cell")
              # On the map: both 16-bit places at nought or above and below its size.
              asm.load(:a, [at + CELL + 1])
              asm.and_a(:a)
              asm.jump(:nz, "rt_big_cell_empty")
              asm.load(:a, [at + CELL + 3])
              asm.and_a(:a)
              asm.jump(:nz, "rt_big_cell_empty")
              asm.load(:a, [at + CELL])
              asm.load(:hl, at + COLS)
              asm.cp_a([:hl])
              asm.jump(:nc, "rt_big_cell_empty")
              asm.load(:a, [at + CELL + 2])
              asm.load(:hl, at + ROWS)
              asm.cp_a([:hl])
              asm.jump(:nc, "rt_big_cell_empty")
              # Its row's entry in the map's table of rows, three bytes: where the row is, its bank.
              asm.load(:l, :a)
              asm.load(:h, 0)
              asm.load(:d, :h)
              asm.load(:e, :l)
              asm.add_hl(:hl)
              asm.add_hl(:de)
              asm.load(:a, [at + MAP])
              asm.load(:e, :a)
              asm.load(:a, [at + MAP + 1])
              asm.load(:d, :a)
              asm.add_hl(:de)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:a, [:hl])
              asm.select_rom_bank
              # HL = the row + the column × 2: the cell's tile, then its colours.
              asm.load(:a, [at + CELL])
              asm.load(:l, :a)
              asm.load(:h, 0)
              asm.add_hl(:hl)
              asm.add_hl(:de)
              asm.load(:a, [:hli])
              asm.load(:b, :a)
              asm.load(:c, [:hl])
              asm.call("rt_bank_back")
              asm.jump_relative("rt_big_cell_put")
              asm.label("rt_big_cell_empty")
              asm.load(:bc, 0)
              asm.label("rt_big_cell_put")
              # DE = its place in the grid: (row round 32) × 32 + (column round 32).
              asm.load(:a, [at + CELL + 2])
              asm.and_a(31)
              asm.load(:l, :a)
              asm.load(:h, 0)
              5.times { asm.add_hl(:hl) }
              asm.load(:a, [at + CELL])
              asm.and_a(31)
              asm.or_a(:l)
              asm.load(:l, :a)
              asm.load(:d, :h)
              asm.load(:e, :l)
              asm.push(:de)
              asm.load(:de, buffer)
              asm.add_hl(:de)
              asm.load([:hl], :b) # the tile, and 1024 on its colours
              asm.load(:de, 1024)
              asm.add_hl(:de)
              asm.load([:hl], :c)
              asm.pop(:de)
              asm.load(:a, [at + STAGING])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_big_cell_next")
              # ...and in the list: the grid's address, the tile, the colours.
              asm.load(:hl, staged)
              asm.load(:a, [:hl])
              asm.inc([:hl])
              asm.inc(:hl)
              asm.push(:de)
              asm.load(:e, :a)
              asm.load(:d, 0)
              4.times { asm.add_hl(:de) }
              asm.pop(:de)
              asm.load(:a, :e)
              asm.load([:hli], :a)
              asm.load(:a, :d)
              asm.or_a(h::TILE_MAP0 >> 8)
              asm.load([:hli], :a)
              asm.load(:a, :b)
              asm.load([:hli], :a)
              asm.load(:a, :c)
              asm.load([:hl], :a)
              asm.label("rt_big_cell_next")
              # The next cell along, and one fewer to work out.
              asm.load(:a, [at + ALONG_Y])
              asm.and_a(:a)
              asm.load(:hl, at + CELL)
              asm.jump_relative(:z, "rt_big_cell_step")
              asm.load(:hl, at + CELL + 2)
              asm.label("rt_big_cell_step")
              asm.inc([:hl])
              asm.jump_relative(:nz, "rt_big_cell_stepped")
              asm.inc(:hl)
              asm.inc([:hl])
              asm.label("rt_big_cell_stepped")
              asm.load(:hl, at + COUNT)
              asm.dec([:hl])
              asm.jump(:nz, "rt_big_cell")
              asm.ret
            end

            # rt_big_view, in the blank: the list's cells into the console's grid — each tile into the
            # first bank of video memory and its colours into the second — and the list empty.
            def emit_view(asm, staged)
              h = Console::GBCHardware
              asm.label("rt_big_view")
              asm.load(:hl, staged)
              asm.load(:a, [:hl])
              asm.and_a(:a)
              asm.ret(:z)
              asm.load(:b, :a)
              asm.xor_a(:a)
              asm.load([:hli], :a)
              asm.label("rt_big_view_cell")
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:a, [:hli])
              asm.load([:de], :a)
              asm.load(:a, 1)
              asm.load_high(h::VBK, :a)
              asm.load(:a, [:hli])
              asm.load([:de], :a)
              asm.xor_a(:a)
              asm.load_high(h::VBK, :a)
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_big_view_cell")
              asm.and_a(:a) # carry clear
              asm.ret
            end
          end
        end
      end
    end
  end
end
