# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # A MAP BIGGER THAN THE CONSOLE'S GRID, brought into view a strip at a time.
        #
        # The console draws a background from a grid of cells in its video memory, and the
        # biggest grid it has is 64x64 cells — four screens. A room bigger than that cannot be
        # put in the grid whole. But the screen only ever shows 31 columns and 21 rows of cells
        # (30 by 20, and one more each way while the view sits part way across a cell), and the
        # grid comes round again at its edge: scroll past its right side and the display reads
        # its left side. So a 32x32 grid is enough to show any part of any map, as long as the
        # cells around the view hold the right part of the map when the picture is drawn.
        #
        # That is what this keeps true. The whole map stays in the cartridge, row after row, and
        # each frame, in the gap before the picture, the place the view is scrolled to is
        # compared with the place the grid was last filled for. A view that moved a cell to the
        # right has one new column coming in on the right; it is copied in over the column that
        # just left on the left, which is the same place in the grid. Rows the same way. Retail
        # games draw their big rooms exactly like this.
        #
        # A JUMP — a new map, a scene taking over, or a view that moved more than a few cells at
        # once — fills the whole view again instead, row by row, in that same gap. So the frame
        # the view lands on already shows the right picture.
        #
        # Past the edge of the map there are no cells, and the blank cell (every pixel
        # see-through) is copied in there. That is why such a map does not come round again the
        # way a map that fits its grid does (see IR::TileMap.streams?).
        #
        # WHAT IT COSTS: a frame the view stayed inside the same cell copies nothing, and pays a
        # few dozen instructions to find that out — where the view is, which map, and four
        # comparisons. A frame it crossed one copies a column of 21 cells or a row of 31, a
        # handful of instructions a cell. A jump is the whole view, 21 rows of 31.
        module MapStreaming
          include Console::Hardware

          # The cells the screen can show at once, each way: 240 and 160 pixels over 8-pixel
          # cells, and one more for a view part way across a cell.
          VIEW_COLS = 31
          VIEW_ROWS = 21

          # The grid such a background has in video memory: one block of 32x32 cells.
          STREAM_CELLS = 32

          # A view that moved further than this many cells since the last frame is filled again
          # whole. Copying that many columns or rows one by one would cost more than the fill.
          MOST_STRIPS = 8

          # A map's four words in the table of maps (see ScreenLayout::StreamedMaps): how far into
          # the blob it starts, its columns, its rows and its blank cell. Sixteen bytes, so a
          # map's row is found with a shift.
          MAP_ROW_SHIFT = 4

          # The registers the strip copy keeps across the whole fill: the map in the cartridge,
          # its columns and rows, the grid in video memory and the blank cell.
          STREAM_SOURCE = 6
          STREAM_COLS = 7
          STREAM_ROWS = 8
          STREAM_GRID = 10
          STREAM_BLANK = 11

          # The registers one strip is described in: the first cell's column and row, how many
          # cells, and how far each step moves along a row and down a column.
          STRIP_COL = 2
          STRIP_ROW = 3
          STRIP_COUNT = 4
          STRIP_ACROSS = 5
          STRIP_DOWN = 9

          # ...and the one a cell's place is worked out in, beside ACC and TMP.
          STRIP_SCRATCH = 12

          # The variables this keeps for one background: the column and row the grid was last
          # filled for, the column and row the view is at now, and the row a fill has reached.
          def stream_var(name, what) = :"_stream_#{name}_#{what}"

          # BRING THE CELLS AROUND THE VIEW IN, for a background whose map is brought into view a
          # strip at a time, before its scroll registers are written. +node+ is the scroll write,
          # whose x and y are where the view is now, in the map's own pixels.
          def emit_stream_view(node, bg)
            name = node.name
            refill = gensym
            columns_left = gensym
            rows_down = gensym
            rows_up = gensym
            done = gensym
            strip = gensym

            emit_view_cell(node.x, stream_var(name, :want_col))
            emit_view_cell(node.y, stream_var(name, :want_row))
            emit_stream_source(bg)

            filled = IR::Nodes::Background.stream_vars(name).last
            load_var(ACC, filled)
            emit(ASM.cmp_imm(ACC, 0))
            emit_branch(:bcond, refill, cond: :eq) # a new map, or a scene that just took over
            emit_far_move_check(stream_var(name, :col), stream_var(name, :want_col), refill)
            emit_far_move_check(stream_var(name, :row), stream_var(name, :want_row), refill)

            # Columns coming in on the right: the one just past the right edge of what is held.
            emit_strip_steps(name, :col, :want_col, toward: :up, strip: strip, done: columns_left) do |at|
              emit(ASM.add_imm(STRIP_COL, at, VIEW_COLS))
              load_var(STRIP_ROW, stream_var(name, :row))
              emit_column_strip
            end
            place_label(columns_left)
            emit_strip_steps(name, :col, :want_col, toward: :down, strip: strip, done: rows_down) do |at|
              emit(ASM.mov_reg(STRIP_COL, at))
              load_var(STRIP_ROW, stream_var(name, :row))
              emit_column_strip
            end
            place_label(rows_down)
            emit_strip_steps(name, :row, :want_row, toward: :up, strip: strip, done: rows_up) do |at|
              emit(ASM.add_imm(STRIP_ROW, at, VIEW_ROWS))
              load_var(STRIP_COL, stream_var(name, :col))
              emit_row_strip
            end
            place_label(rows_up)
            emit_strip_steps(name, :row, :want_row, toward: :down, strip: strip, done: done) do |at|
              emit(ASM.mov_reg(STRIP_ROW, at))
              load_var(STRIP_COL, stream_var(name, :col))
              emit_row_strip
            end
            emit_branch(:b, done)

            place_label(refill)
            emit_view_fill(name, filled, strip)

            # The copy of one strip, called from each place above. It sits here, jumped over,
            # so it moves wherever the code around it is put.
            place_label(done)
            after = gensym
            emit_branch(:b, after)
            place_label(strip)
            emit_strip_routine(name)
            place_label(after)
          end

          # Where a background's view is, as the scroll write names it: the background, and the
          # two values its place is read from.
          ViewPlace = Struct.new(:name, :x, :y)

          # FILL THE WHOLE VIEW NOW, from the place the background's view is at and the map it
          # names, rather than in the scroll write later in the gap. For the moments the layers
          # are switched off — a scene taking over, an area's tiles coming in — so the view is
          # whole by the time they are on again, and no part of the frame shows the last room's
          # cells over the new tiles.
          def emit_stream_fill(bg)
            name = bg.stream.name
            emit(ASM.load_immediate(ACC, 0))
            store_var(ACC, IR::Nodes::Background.stream_vars(name).last)
            x, y = IR::Nodes::Background.scroll_vars(name)
            emit_stream_view(ViewPlace.new(name, Build.var_ref(x), Build.var_ref(y)), bg)
          end

          # HAND THE BACKGROUND ANOTHER MAP: say which map the strips come from now, and that the
          # grid does not hold it yet. Nothing is copied here. The scroll write later in the
          # same gap fills the whole view from the new map, at the place the view is at then,
          # so the frame shows the new map wherever the game moved the view to on the way in.
          # A number naming no map changes nothing.
          def emit_stream_map_change(node, bg, done)
            streamed, filled = IR::Nodes::Background.stream_vars(node.name)
            @lowering.value(node.which)
            emit(ASM.cmp_imm(ACC, bg.map_count))
            emit_branch(:bcond, done, cond: :hs)
            store_var(ACC, streamed)
            emit(ASM.load_immediate(ACC, 0))
            store_var(ACC, filled)
          end

          private

          # The cell a view's place in pixels starts in, kept in +var+. A view to the left of or
          # above the map is a negative place, and shifting keeps the sign, so it is still the
          # cell the view starts in.
          def emit_view_cell(value, var)
            @lowering.value(value)
            emit(ASM.asr_imm(ACC, ACC, 3))
            store_var(ACC, var)
          end

          # The map the strips come from: where it starts in the cartridge, its size and its
          # blank cell. Read off the table of maps by the number the background last showed —
          # which is always a map it has, since a number naming none is never stored there.
          def emit_stream_source(bg)
            stream = bg.stream
            streamed, = IR::Nodes::Background.stream_vars(stream.name)
            load_var(ACC, streamed)
            emit(ASM.lsl_imm(ACC, ACC, MAP_ROW_SHIFT))
            emit_load_data_address(TMP, stream.table)
            emit(ASM.add_reg(TMP, TMP, ACC))
            emit(ASM.ldr_offset(STREAM_SOURCE, TMP, 0))
            emit(ASM.ldr_offset(STREAM_COLS, TMP, 4))
            emit(ASM.ldr_offset(STREAM_ROWS, TMP, 8))
            emit(ASM.ldr_offset(STREAM_BLANK, TMP, 12))
            emit_load_data_address(TMP, stream.maps)
            emit(ASM.add_reg(STREAM_SOURCE, STREAM_SOURCE, TMP))
            emit(ASM.load_immediate(STREAM_GRID, VRAM_START + (bg.screen_block * SCREENBLOCK_BYTES)))
          end

          # Go to +refill+ when the view moved more than MOST_STRIPS cells one way since the grid
          # was filled. One unsigned test covers both directions: the move plus MOST_STRIPS is
          # inside 0..2*MOST_STRIPS for a short move either way, and anything else, a negative
          # number included, reads as more.
          def emit_far_move_check(held, want, refill)
            load_var(ACC, want)
            load_var(TMP, held)
            emit(ASM.sub_reg(ACC, ACC, TMP))
            emit(ASM.add_imm(ACC, ACC, MOST_STRIPS))
            emit(ASM.cmp_imm(ACC, (2 * MOST_STRIPS) + 1))
            emit_branch(:bcond, refill, cond: :hs)
          end

          # Move the place the grid holds one cell at a time toward where the view is, copying
          # the strip that comes in at each step, until the two agree. +toward: :up+ is the
          # view to the right or below. The block gets the register holding the grid's place —
          # before the step going up, after it going down — and names the strip that comes in.
          def emit_strip_steps(name, held_what, want_what, toward:, strip:, done:)
            held = stream_var(name, held_what)
            want = stream_var(name, want_what)
            again = gensym
            place_label(again)
            load_var(ACC, held)
            load_var(TMP, want)
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, done, cond: toward == :up ? :ge : :le)
            if toward == :up
              emit(ASM.add_imm(TMP, ACC, 1)) # the grid's place moves on; ACC keeps where it was
              store_var(TMP, held)
            else
              emit(ASM.sub_imm(ACC, ACC, 1))
              store_var(ACC, held)
            end
            yield ACC
            emit_branch(:bl, strip)
            emit_branch(:b, again)
          end

          # A strip down one column: VIEW_ROWS cells, each a row further down.
          def emit_column_strip
            emit(ASM.load_immediate(STRIP_COUNT, VIEW_ROWS))
            emit(ASM.load_immediate(STRIP_ACROSS, 0))
            emit(ASM.load_immediate(STRIP_DOWN, 1))
          end

          # A strip along one row: VIEW_COLS cells, each a column further right.
          def emit_row_strip
            emit(ASM.load_immediate(STRIP_COUNT, VIEW_COLS))
            emit(ASM.load_immediate(STRIP_ACROSS, 1))
            emit(ASM.load_immediate(STRIP_DOWN, 0))
          end

          # FILL THE WHOLE VIEW, a row at a time, for the place the view is at now, and say the
          # grid holds it.
          def emit_view_fill(name, filled, strip)
            row = stream_var(name, :fill_row)
            again = gensym
            load_var(ACC, stream_var(name, :want_col))
            store_var(ACC, stream_var(name, :col))
            load_var(ACC, stream_var(name, :want_row))
            store_var(ACC, stream_var(name, :row))
            store_var(ACC, row)
            place_label(again)
            load_var(STRIP_ROW, row)
            load_var(STRIP_COL, stream_var(name, :col))
            emit_row_strip
            emit_branch(:bl, strip)
            load_var(ACC, row)
            emit(ASM.add_imm(ACC, ACC, 1))
            store_var(ACC, row)
            load_var(TMP, stream_var(name, :row))
            emit(ASM.add_imm(TMP, TMP, VIEW_ROWS))
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, again, cond: :lt)
            emit(ASM.load_immediate(ACC, 1))
            store_var(ACC, filled)
          end

          # COPY ONE STRIP OF CELLS FROM THE MAP INTO THE GRID, as described in the STRIP
          # registers. A cell outside the map gets the blank cell. A cell's place in the grid is
          # its column and row each taken round 32, which is what lets the grid come round again
          # under the view.
          def emit_strip_routine(name)
            again = gensym
            blank = gensym
            @emitter.note_video_copy("bringing the view of background :#{name} along its map", 2)
            place_label(again)
            emit(ASM.mov_reg(ACC, STREAM_BLANK))
            # One unsigned compare catches both ends: a negative column or row reads as a very
            # large number, so anything outside 0...size fails the same test.
            emit(ASM.cmp_reg(STRIP_COL, STREAM_COLS))
            emit_branch(:bcond, blank, cond: :hs)
            emit(ASM.cmp_reg(STRIP_ROW, STREAM_ROWS))
            emit_branch(:bcond, blank, cond: :hs)
            emit(ASM.mul(TMP, STRIP_ROW, STREAM_COLS))
            emit(ASM.add_reg(TMP, TMP, STRIP_COL))
            emit(ASM.lsl_imm(TMP, TMP, 1)) # two bytes a cell
            emit(ASM.add_reg(TMP, TMP, STREAM_SOURCE))
            emit(ASM.load_halfword(ACC, TMP))
            place_label(blank)
            emit(ASM.and_imm(TMP, STRIP_ROW, STREAM_CELLS - 1))
            emit(ASM.lsl_imm(TMP, TMP, 5))
            emit(ASM.and_imm(STRIP_SCRATCH, STRIP_COL, STREAM_CELLS - 1))
            emit(ASM.orr_reg(TMP, TMP, STRIP_SCRATCH))
            emit(ASM.lsl_imm(TMP, TMP, 1))
            emit(ASM.add_reg(TMP, TMP, STREAM_GRID))
            emit(ASM.store_halfword(ACC, TMP))
            emit(ASM.add_reg(STRIP_COL, STRIP_COL, STRIP_ACROSS))
            emit(ASM.add_reg(STRIP_ROW, STRIP_ROW, STRIP_DOWN))
            emit(ASM.subs_imm(STRIP_COUNT, STRIP_COUNT, 1))
            emit_branch(:bcond, again, cond: :ne)
            emit(ASM.return)
          end
        end
      end
    end
  end
end
