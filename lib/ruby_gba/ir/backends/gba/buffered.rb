# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Double-buffered (Mode 4) drawing, onto the hidden page.
        #
        # These mirror the direct-color fills Drawing makes, with two differences
        # forced by the indexed screen: a pixel is one byte (an index into the color
        # table), not two, so addresses and counts are in bytes; and video memory
        # can't be written a single byte at a time (a lone byte write hits both
        # halves of its 16-bit slot), so fills move whole 16-bit units — two pixels —
        # at once, and a block fill must start on an even column (a rect asked for an
        # odd one gets its two edge pixels written singly instead). The destination is
        # the hidden page, whose address lives in a run-time variable (BACKBUF) and
        # swaps every flip.
        #
        # Reaches Drawing's clip/column/digit-glyph helpers through {Framebuffer}
        # rather than through Drawing itself — the two screens share how they work,
        # not an object.
        class Buffered
          include Constants

          def initialize(emitter:, primitives:, lowering:, framebuffer:, call_cold_routine:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @framebuffer = framebuffer
            @call_cold_routine = call_cold_routine
            @layout = nil
          end

          attr_writer :layout

          # Forwards to @emitter/@primitives, exactly as every other converted
          # collaborator's do (see e.g. {Collision}).
          def emit(bytes) = @emitter.emit(bytes)
          def pos = @emitter.pos
          def place_label(name) = @emitter.place_label(name)
          def gensym = @emitter.gensym
          def emit_branch(kind, target, cond: nil) = @emitter.emit_branch(kind, target, cond: cond)
          def emit_load_data_address(reg, name) = @emitter.emit_load_data_address(reg, name)
          def var_addr(name) = @primitives.var_addr(name)
          def load_var(reg, name) = @primitives.load_var(reg, name)
          def const_int(node) = @primitives.const_int(node)
          def constant_ints!(node, **sides) = @primitives.constant_ints!(node, **sides)
          def store_word_immediate(value, address) = @primitives.store_word_immediate(value, address)
          def emit_row_loop(counter, &block) = @primitives.emit_row_loop(counter, &block)
          def emit_add_const(rd, rn, imm, scratch) = @primitives.emit_add_const(rd, rn, imm, scratch)
          def emit_call_cold_routine(label) = @call_cold_routine.call(label)

          # Clear the hidden page to a solid color: one DMA that repeats the packed
          # index word across the whole page.
          def emit_clear_screen_buffered(node)
            # Inside an area, "the whole page" is that area — which is a rectangle, and there is
            # already one way to fill one of those.
            if @framebuffer.clipping?
              return emit_buffered_rect(@framebuffer.clip_left, @framebuffer.clip_top, @framebuffer.clip_right - @framebuffer.clip_left,
                                        @framebuffer.clip_bottom - @framebuffer.clip_top, node.color)
            end

            scratch = hold_index_word(node.color)
            store_word_immediate(scratch, REG_DMA3SAD)
            point_dma_dest_at_backbuf
            count = SCREEN_WIDTH * SCREEN_HEIGHT / 4 # 32-bit words, 4 indices each
            store_word_immediate(@framebuffer.dma_fill_control(count), REG_DMA3CNT)
          end

          # A rectangle at a constant position/size, filled per row into the hidden
          # page. fill_rect and dma_fill_rect share this — in Mode 4 both are the same
          # packed block fill.
          #
          # A fill moves whole 16-bit units, so it can only START on an even column.
          # Asked for an odd one, the rect's first and last pixel each share a unit
          # with a pixel that is NOT part of the rect — so those two are written one
          # at a time (read the unit, change that pixel's half, write it back) and the
          # DMA fills the even middle between them. The column is known while
          # building, so which of the two shapes a row takes is settled here.
          def emit_fill_rect_buffered(node)
            x, y, w, h = constant_ints!(node, x: node.x, y: node.y, w: node.w, h: node.h)
            @framebuffer.even_width!(w, node.kind)
            emit_buffered_rect(x, y, w, h, node.color)
          end

          # Up to this many pairs of pixels, writing them out beats starting the block-fill
          # engine — and up to here it beats it TWICE OVER, in time and in the code it takes.
          #
          # Counted off the emitted code, a row that starts the engine is fifteen
          # instructions whatever it then moves, and a row written out is two instructions
          # plus one per pair. So the written-out row is the SMALLER one up to thirteen
          # pairs, and it stays the faster one much further than that: starting the engine
          # costs about what fourteen pairs do — the register writes AND the stall while the
          # engine copies, which stops the CPU dead — so the engine does not win on time
          # until a row is nearly thirty pairs wide.
          #
          # This sits at the point where those two agree, so nothing is traded for anything.
          # Past it the written-out row is still faster and starts to cost more code, and a
          # rectangle's rows are unrolled — so going further needs a size budget the
          # framework does not have, and it would spend the quick memory that a game's hot
          # routines are competing for.
          DIRECT_STORE_UNITS = 12

          def direct_fill?(w) = w.positive? && (w / 2) <= DIRECT_STORE_UNITS

          # The fill colour as one 16-bit unit — the same palette index in both of its
          # pixels — held for as long as a fixed-position rect's narrow rows need it.
          # (The run-time-positioned rect's own middle-width path uses this register for
          # its transfer count instead; the two never run together.)
          RECT_FILL = 7

          # ...and the same rectangle without the even-width promise, because an area can cut a
          # row down to an odd number of pixels however even the author's own rectangle was.
          def emit_buffered_rect(x, y, w, h, color)
            # Held to the area sideways once, before any row is emitted: every row of a
            # rectangle spans the same columns, so where it starts and stops is one answer.
            left = [x, @framebuffer.clip_left].max
            right = [x + w, @framebuffer.clip_right].min
            return if right <= left || h <= 0

            x = left
            w = right - left
            scratch = hold_index_word(color)
            index = @layout.palette.index_of(color)

            # WHICH PIXELS CANNOT GO IN AS PAIRS. A fill moves whole 16-bit units, so a run that
            # starts on an odd column shares its first unit with a pixel outside the rectangle,
            # and one holding an odd number of pixels shares its last. Either is written on its
            # own — read the unit, change that half, write it back — and the pairs between them
            # go in as one block.
            first_alone = x.odd?
            last_x = x + w - 1
            middle_x = first_alone ? x + 1 : x
            middle_w = w - (first_alone ? 1 : 0)
            last_alone = middle_w.odd?
            middle_w -= 1 if last_alone

            base = 6
            load_var(base, BACKBUF) # the hidden page base, held for the whole rect
            # A row narrow enough to be written out needs the fill unit in a register, and it
            # is the same unit for every row — so it is loaded once here rather than per row.
            emit(ASM.load_immediate(RECT_FILL, fill_unit(index))) if direct_fill?(middle_w)

            # A rect as wide as the screen is one unbroken run of memory: there is no gap
            # to skip between rows, because the next row starts exactly where the last one
            # ended. So the whole rect goes in as a single block transfer instead of one
            # per row — which for a full-width band (a sky, a floor, a letterbox) is the
            # difference between two instructions and a hundred and sixty.
            if full_width_rows?(x: x, y: y, w: w, h: h)
              return emit_buffered_row_fill(base: base, x: 0, row: y, w: w * h, scratch: scratch)
            end

            h.times do |dy|
              row = y + dy
              next unless (@framebuffer.clip_top...@framebuffer.clip_bottom).cover?(row)

              emit_write_index_pixel_const(base, x, row, index) if first_alone
              emit_buffered_row_fill(base: base, x: middle_x, row: row, w: middle_w, scratch: scratch) if middle_w.positive?
              emit_write_index_pixel_const(base, last_x, row, index) if last_alone
            end
          end

          # Can this rect go in as one transfer? Only if it spans the full screen width (so its
          # rows are contiguous) and every row of it may be painted (so there is nothing to skip
          # in the middle of the run). An area narrower than the screen breaks the first of
          # those, and one that starts below the top or stops above the bottom the second.
          def full_width_rows?(x:, y:, w:, h:)
            x.zero? && w == SCREEN_WIDTH && h.positive? &&
              y >= @framebuffer.clip_top && (y + h) <= @framebuffer.clip_bottom &&
              @framebuffer.clip_left.zero? && @framebuffer.clip_right == SCREEN_WIDTH
          end

          # One row of a rect into the hidden page: +w+ pixels from the even column +x+ of
          # +row+. +base+ is the register holding the hidden page base.
          #
          # A narrow row is written out as pairs of pixels rather than handed to the
          # block-fill engine, for the reason DIRECT_STORE_UNITS gives: starting the engine
          # costs the same whatever it then moves, so below that width the starting is most
          # of the work. A row of eight pixels goes in as four stores against the engine's
          # fifteen instructions and its stall.
          def emit_buffered_row_fill(base:, x:, row:, w:, scratch:)
            return emit_buffered_row_stores(base: base, x: x, row: row, w: w) if direct_fill?(w)

            store_word_immediate(scratch, REG_DMA3SAD)
            emit_add_const(ACC, base, (row * SCREEN_WIDTH) + x, TMP) # + byte offset (1 byte/pixel)
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(ACC, TMP))                                  # destination = that row
            store_word_immediate(dma_fill_control_16(w / 2), REG_DMA3CNT)
          end

          # The same row written out: the fill unit — the palette index in both of its bytes,
          # held in RECT_FILL — stored a pair at a time. Every address here is settled while
          # building, so a row is one address built into r1 and then a store per pair at a
          # fixed offset from it.
          def emit_buffered_row_stores(base:, x:, row:, w:)
            emit_add_const(1, base, (row * SCREEN_WIDTH) + x, ACC) # r1 = the row's first unit
            (w / 2).times { |unit| emit(ASM.store_halfword_offset(RECT_FILL, 1, unit * 2)) }
          end

          # The 16-bit unit a packed fill writes: the palette index in both of its pixels.
          def fill_unit(index) = (index * 0x0101) & 0xFFFF

          # A rectangle at a run-time position, filled per row into the hidden page.
          #
          # Every edge settled while building goes straight to the same fixed-rect fill
          # fill_rect uses (#emit_buffered_rect) — clipped in Ruby, once, nothing for the
          # console to check. A width settled while building but at least one other edge
          # not gets the fits-whole check (#emit_draw_rect_at_buffered_fixed_width): the
          # overwhelming common case is a rect that never actually crosses an edge, and
          # that one still gets the size-chosen, parity-branched shape a fixed rect does.
          # Anything else always needs the clip worked out at run time
          # (#emit_buffered_rect_at_computed), since neither the width nor the position is
          # known well enough while building to rule an edge out.
          def emit_draw_rect_at_buffered(node)
            x = const_int(node.x)
            y = const_int(node.y)
            w = const_int(node.w)
            h = const_int(node.h)
            return if w && w < 1 # a rect with no width draws nothing
            return if h && h < 1 # ...or no height

            return emit_buffered_rect(x, y, w, h, node.color) if x && y && w && h
            return emit_buffered_rect_at_computed(node, w) unless w

            emit_draw_rect_at_buffered_fixed_width(node, w, h)
          end

          # Registers through the whole run: r2 the rect's (clipped, once it needs to be)
          # x, r3 its y — a running row number once #emit_row_address_setup has used it to
          # seed r4 — r4 the address of the row's first column, r5 scratch, r6 how many
          # rows are left when the height is one the game works out.
          RECT_X = 2
          RECT_Y = 3
          RECT_ROW = 4
          RECT_ADDR = 5
          RECT_ROWS_LEFT = 6

          # Put the hidden page's address of column 0 on the rect's FIRST row in r4, once
          # for the whole rect.
          #
          # Every row after that starts exactly one screen width further on, so the rows
          # walk it down with a single add (#emit_advance_row) instead of working it out
          # again. Working it out again is what this used to do on every row: a multiply
          # by the screen width, a load of the hidden page's address, and an add — five
          # instructions before a single pixel was written. On a tall thin column, which is
          # what a per-column renderer draws hundreds of, that WAS the column: measured, a
          # rect cost the same per row at 2 pixels wide as at 16, because almost none of
          # the cost was the pixels.
          def emit_row_address_setup
            emit(ASM.load_immediate(RECT_ADDR, SCREEN_WIDTH))
            emit(ASM.mul(RECT_ROW, RECT_ADDR, RECT_Y)) # r4 = SCREEN_WIDTH * y, 1 byte/pixel
            load_var(RECT_ADDR, BACKBUF)               # r5 = hidden page base
            emit(ASM.add_reg(RECT_ROW, RECT_ROW, RECT_ADDR))
          end

          # One row down the screen: the address (240 bytes a row on this display, which
          # the chip can add in one instruction) and the row NUMBER — r3 is done seeding
          # r4 by the time the first row runs, so from here it tracks which row this is,
          # for #emit_buffered_computed_row's own top/bottom check.
          def emit_advance_row
            emit(ASM.add_imm(RECT_ROW, RECT_ROW, SCREEN_WIDTH))
            emit(ASM.add_imm(RECT_Y, RECT_Y, 1))
          end

          # +h+ is the height when it is settled while building — then the rows are
          # unrolled. It is nil when the game works the height out, and then the same
          # row is emitted once inside a counted loop that walks down the screen.
          def emit_buffered_rect_rows(w:, h:, scratch:, index:, starts_odd:)
            row = { w: w, scratch: scratch, index: index, starts_odd: starts_odd }
            emit_row_address_setup
            # Every row's middle is the same width, so whether it is written straight out
            # is settled here, once, along with the value it writes.
            emit_rect_fill_value(index) if direct_fill?(rect_row_parts(w, starts_odd).last)
            if h
              h.times do |dy|
                emit_advance_row unless dy.zero?
                emit_buffered_rect_row(**row)
              end
              return
            end

            emit_row_loop(RECT_ROWS_LEFT) do
              emit_buffered_rect_row(**row)
              emit_advance_row
            end
          end

          # +starts_odd+ says the rect begins on an odd column, which is settled by here
          # (either the column is a plain number, or the caller branched on its low bit).
          # The width is a plain number too, so which pixels need splicing in one at a
          # time follows from the same rule the computed-width path works out as it runs:
          # the first pixel when the rect starts on an odd column, the last when it ends
          # on an even one. Both parities of width are covered — an odd width is not an
          # error here, just a rect with a different pair of ends.
          def emit_buffered_rect_row(w:, scratch:, index:, starts_odd:)
            left, right, middle_w = rect_row_parts(w, starts_odd)

            emit_splice_rect_edge(index: index, offset: 0, high: true) if left.positive?
            emit_buffered_rect_row_middle(offset: left, w: middle_w, scratch: scratch) if middle_w.positive?
            emit_splice_rect_edge(index: index, offset: w - 1, high: false) if right.positive?
          end

          # Which of a row's pixels need splicing in one at a time, and how many are left
          # in the middle. Every row of a rect has the same answer, so the callers work it
          # out once above the rows and it agrees with what each row then emits.
          def rect_row_parts(w, starts_odd)
            left = starts_odd ? 1 : 0
            right = (starts_odd ? w + 1 : w).odd? ? 1 : 0
            [left, right, w - left - right]
          end

          # Held for the whole of a computed-width rect: r7 the middle's transfer count
          # (0 when there is no middle), r8 whether the rect starts on an odd column
          # (which is also how far right of x its middle begins), r9 the column its last
          # pixel is in.
          RECT_MIDDLE = 7
          RECT_LEFT = 8
          RECT_RIGHT = 9

          # A rect whose width is settled while building but at least one other edge is
          # not — an author's own fixed size at a position the game works out, the health
          # bar every doc example for this verb draws. Checked once, at run time, whether
          # it already fits the area whole: if so, exactly the size-chosen, parity-branched
          # shape #emit_buffered_rect_rows gives a fixed rectangle runs, just with its
          # address built from a run-time x/y instead of one settled while building — the
          # overwhelming common case, and the one worth keeping cheap. Only a rect that
          # would actually cross an edge falls through to the general run-time clip
          # (#emit_buffered_rect_at_computed's tail), because that shape cannot promise
          # the width stays a plain number once the console has trimmed it.
          def emit_draw_rect_at_buffered_fixed_width(node, w, h)
            scratch = hold_index_word(node.color)
            index = @layout.palette.index_of(node.color)

            @framebuffer.eval_rect_position(node, x_reg: RECT_X, y_reg: RECT_Y, rows_reg: RECT_ROWS_LEFT)

            needs_clip = gensym
            done = gensym

            emit(ASM.cmp_imm(RECT_X, @framebuffer.clip_left))
            emit_branch(:bcond, needs_clip, cond: :lt)
            emit_add_const(ACC, RECT_X, w, TMP)
            emit(ASM.cmp_imm(ACC, @framebuffer.clip_right))
            emit_branch(:bcond, needs_clip, cond: :gt)
            emit(ASM.cmp_imm(RECT_Y, @framebuffer.clip_top))
            emit_branch(:bcond, needs_clip, cond: :lt)
            if h
              emit_add_const(ACC, RECT_Y, h, TMP)
            else
              emit(ASM.add_reg(ACC, RECT_Y, RECT_ROWS_LEFT))
            end
            emit(ASM.cmp_imm(ACC, @framebuffer.clip_bottom))
            emit_branch(:bcond, needs_clip, cond: :gt)

            parity = Parity.of(node.x)
            rows = { w: w, h: h, scratch: scratch, index: index }
            if parity
              emit_buffered_rect_rows(**rows, starts_odd: parity == :odd)
            else
              odd_column = gensym
              emit(ASM.and_imm(ACC, RECT_X, 1))
              emit(ASM.cmp_imm(ACC, 0))
              emit_branch(:bcond, odd_column, cond: :ne)
              emit_buffered_rect_rows(**rows, starts_odd: false)
              emit_branch(:b, done)
              place_label(odd_column)
              emit_buffered_rect_rows(**rows, starts_odd: true)
            end
            emit_branch(:b, done)

            place_label(needs_clip)
            emit(ASM.load_immediate(RECT_MIDDLE, w))
            emit_buffered_rect_clip_and_rows(node, scratch, index)

            place_label(done)
          end

          # A rect with at least one edge the game works out as it runs, so the clip has
          # to happen at run time.
          #
          # Here a pixel is one byte, but video memory refuses to write a lone byte — the
          # smallest write covers two side-by-side pixels, one unit. So a rect that
          # starts or ends halfway through a unit has to have that pixel spliced in on
          # its own: read the unit, change only this pixel's half, write it back. The
          # rest, an even number of pixels starting on an even column, goes in as a
          # block fill. Both ends come down to one rule, worked out once above the rows
          # because every row of a rect starts and ends in the same columns:
          #
          #   - the first pixel needs splicing when the rect starts on an ODD column;
          #   - the last one needs splicing when it ends on an EVEN column;
          #   - what is left between them is always an even number of pixels beginning
          #     on an even column, which is exactly what a block fill wants.
          #
          # x and width settle to one CLIPPED span before any row fires — a rect has one
          # x for its whole height — and every row then checks its own y against the
          # area (#emit_buffered_computed_row), because a run-time y or height means a
          # run-time set of rows survives: an unclipped row is what wrapped a rect onto
          # its neighbor.
          def emit_buffered_rect_at_computed(node, w)
            scratch = hold_index_word(node.color)
            index = @layout.palette.index_of(node.color)

            @framebuffer.eval_rect_position(node, x_reg: RECT_X, y_reg: RECT_Y,
                                     rows_reg: RECT_ROWS_LEFT, width_reg: RECT_MIDDLE)
            emit(ASM.load_immediate(RECT_MIDDLE, w)) if w # a fixed width isn't loaded above

            emit_buffered_rect_clip_and_rows(node, scratch, index)
          end

          # The clip, and the rows it leaves for, shared by #emit_buffered_rect_at_computed
          # (always this shape) and #emit_draw_rect_at_buffered_fixed_width (the fallback
          # once a fits-whole rect turns out not to). Assumes r2/r3 (x/y) and r7 (the raw,
          # unclipped width) are already loaded, and r6 (rows left) is too when the height
          # is not settled while building.
          def emit_buffered_rect_clip_and_rows(node, scratch, index)
            done = gensym

            # right = x + width, unclipped, worked out before x itself is touched.
            emit(ASM.add_reg(RECT_RIGHT, RECT_X, RECT_MIDDLE))
            keep_right = gensym
            emit(ASM.cmp_imm(RECT_RIGHT, @framebuffer.clip_right))
            emit_branch(:bcond, keep_right, cond: :le)
            emit(ASM.load_immediate(RECT_RIGHT, @framebuffer.clip_right))
            place_label(keep_right)

            keep_left = gensym
            emit(ASM.cmp_imm(RECT_X, @framebuffer.clip_left))
            emit_branch(:bcond, keep_left, cond: :ge)
            emit(ASM.load_immediate(RECT_X, @framebuffer.clip_left))
            place_label(keep_left)

            # A rect the game shrank to nothing, or slid entirely off the area, draws
            # nothing — and a block fill asked for zero units would move 65536 of them,
            # so this is not optional.
            emit(ASM.sub_reg(RECT_MIDDLE, RECT_RIGHT, RECT_X))
            emit(ASM.cmp_imm(RECT_MIDDLE, 0))
            emit_branch(:bcond, done, cond: :le)

            emit(ASM.sub_imm(RECT_RIGHT, RECT_RIGHT, 1))       # the last column, one back from "past the end"
            emit(ASM.and_imm(RECT_LEFT, RECT_X, 1))            # starts on an odd column?
            emit(ASM.and_imm(ACC, RECT_RIGHT, 1))
            emit(ASM.rsb_imm(ACC, ACC, 1))                     # ends on an even one?
            emit(ASM.sub_reg(RECT_MIDDLE, RECT_MIDDLE, RECT_LEFT)) # what the two ends
            emit(ASM.sub_reg(RECT_MIDDLE, RECT_MIDDLE, ACC))       # do not cover

            # Turn that into a transfer count, or leave it at zero to mean "no middle".
            no_middle = gensym
            emit(ASM.cmp_imm(RECT_MIDDLE, 0))
            emit_branch(:bcond, no_middle, cond: :eq)
            emit(ASM.lsr_imm(RECT_MIDDLE, RECT_MIDDLE, 1)) # two pixels per unit moved
            emit(ASM.load_immediate(TMP, dma_fill_control_16(0)))
            emit(ASM.orr_reg(RECT_MIDDLE, RECT_MIDDLE, TMP))
            place_label(no_middle)

            height = const_int(node.h)
            emit(ASM.load_immediate(RECT_ROWS_LEFT, height)) if height
            emit_row_address_setup
            emit_row_loop(RECT_ROWS_LEFT) do
              emit_buffered_computed_row(index: index, scratch: scratch)
              emit_advance_row
            end
            place_label(done)
          end

          # One row of a computed-width rect: skipped outright if its y falls outside
          # the area (a row above or below it draws NOTHING, not a row wrapped onto its
          # neighbor); else at most two spliced pixels with a block fill between them,
          # which of the three actually run having been decided above the loop.
          def emit_buffered_computed_row(index:, scratch:)
            row_skip = gensym
            emit(ASM.cmp_imm(RECT_Y, @framebuffer.clip_top))
            emit_branch(:bcond, row_skip, cond: :lt)
            emit(ASM.cmp_imm(RECT_Y, @framebuffer.clip_bottom))
            emit_branch(:bcond, row_skip, cond: :ge)

            skip_left = gensym
            emit(ASM.cmp_imm(RECT_LEFT, 0))
            emit_branch(:bcond, skip_left, cond: :eq)
            emit_splice_column(index: index, col_reg: RECT_X, high: true)
            place_label(skip_left)

            skip_middle = gensym
            emit(ASM.cmp_imm(RECT_MIDDLE, 0))
            emit_branch(:bcond, skip_middle, cond: :eq)
            emit(ASM.add_reg(RECT_ADDR, RECT_ROW, RECT_X))
            emit(ASM.add_reg(RECT_ADDR, RECT_ADDR, RECT_LEFT)) # past a spliced first pixel
            store_word_immediate(scratch, REG_DMA3SAD)
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(RECT_ADDR, TMP))
            emit(ASM.load_immediate(TMP, REG_DMA3CNT))
            emit(ASM.str(RECT_MIDDLE, TMP))
            place_label(skip_middle)

            skip_right = gensym
            emit(ASM.and_imm(ACC, RECT_RIGHT, 1))
            emit(ASM.cmp_imm(ACC, 0))
            emit_branch(:bcond, skip_right, cond: :ne) # ends on an odd column: nothing to splice
            emit_splice_column(index: index, col_reg: RECT_RIGHT, high: false)
            place_label(skip_right)

            place_label(row_skip)
          end

          # Splice one pixel of a rect into the hidden page: the pixel in the column
          # +col_reg+ holds, on the row whose address r4 holds. Its unit also holds a
          # pixel outside the rect, so read the unit, replace only this pixel's half,
          # and write it back. An odd column is the HIGH half of its unit, so its
          # address needs the low bit cleared to name the unit.
          def emit_splice_column(index:, col_reg:, high:)
            emit(ASM.add_reg(RECT_ADDR, RECT_ROW, col_reg))
            if high
              emit(ASM.lsr_imm(RECT_ADDR, RECT_ADDR, 1))
              emit(ASM.lsl_imm(RECT_ADDR, RECT_ADDR, 1))
            end
            emit(ASM.load_halfword(ACC, RECT_ADDR))
            splice_index_byte(ACC, index, high)
            emit(ASM.store_halfword(ACC, RECT_ADDR))
          end

          def emit_rect_fill_value(index)
            emit(ASM.load_immediate(RECT_FILL, (index << 8) | index))
          end

          # Fill the middle of one row of a fits-whole, run-time-positioned rect: +w+
          # pixels starting +offset+ columns right of the rect's x, on the row whose
          # address r4 holds.
          #
          # A NARROW middle is written straight out, one 16-bit store per pair of pixels,
          # rather than handing it to the block-fill engine. Starting that engine costs the
          # same whatever it then moves — the register writes, and the stall while it copies
          # — so for a pair or two the starting is nearly all of the work, and a two-pixel
          # column would cost more per row than a one-pixel one that only splices.
          #
          # Past DIRECT_STORE_UNITS the engine is worth starting; see the constant above for
          # where that line sits and what it is measured against.
          def emit_buffered_rect_row_middle(offset:, w:, scratch:)
            return emit_buffered_rect_row_dma(offset: offset, w: w, scratch: scratch) unless direct_fill?(w)

            emit(ASM.add_reg(RECT_ADDR, RECT_ROW, RECT_X))
            emit_add_const(RECT_ADDR, RECT_ADDR, offset, ACC)
            (w / 2).times { |unit| emit(ASM.store_halfword_offset(RECT_FILL, RECT_ADDR, unit * 2)) }
          end

          # DMA one row of a fits-whole, run-time-positioned rect: +w+ pixels starting
          # +offset+ columns right of the rect's x, on the row whose address r4 holds.
          def emit_buffered_rect_row_dma(offset:, w:, scratch:)
            emit(ASM.add_reg(RECT_ADDR, RECT_ROW, RECT_X))
            emit_add_const(RECT_ADDR, RECT_ADDR, offset, ACC)
            store_word_immediate(scratch, REG_DMA3SAD)
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(RECT_ADDR, TMP))
            store_word_immediate(dma_fill_control_16(w / 2), REG_DMA3CNT)
          end

          # Splice one edge pixel of a fits-whole, run-time-positioned rect into the
          # hidden page: the pixel +offset+ columns right of the rect's x, on the row
          # whose address r4 holds. Its 16-bit unit also holds a pixel outside the rect,
          # so read the unit, replace only this pixel's half, and write it back. The
          # rect's x is odd here, which makes the left edge the high half of its unit and
          # the right edge (x + w - 1, an even column, since the width is even) the low
          # half of its own — so only the left edge's address needs its low bit cleared.
          def emit_splice_rect_edge(index:, offset:, high:)
            emit(ASM.add_reg(RECT_ADDR, RECT_ROW, RECT_X))
            emit_add_const(RECT_ADDR, RECT_ADDR, offset, ACC)
            if high
              emit(ASM.lsr_imm(RECT_ADDR, RECT_ADDR, 1)) # clear the low bit ->
              emit(ASM.lsl_imm(RECT_ADDR, RECT_ADDR, 1)) # r5 = the containing unit's address
            end
            emit(ASM.load_halfword(ACC, RECT_ADDR))      # r0 = the current pixel pair
            splice_index_byte(ACC, index, high)
            emit(ASM.store_halfword(ACC, RECT_ADDR))
          end

          # Stash a solid fill color as a word of four packed indices in IWRAM and
          # return its address — the fixed source a Mode 4 DMA fill re-reads. A 16-bit
          # fill reads its low half (two indices); a 32-bit fill reads all four.
          def hold_index_word(color)
            index = @layout.palette.index_of(color)
            word = index * 0x01010101 # the same index in all four bytes
            scratch = var_addr(:_dma_scratch)
            store_word_immediate(word, scratch)
            scratch
          end

          # Point DMA3's destination at the hidden page's base (a run-time value).
          def point_dma_dest_at_backbuf
            load_var(ACC, BACKBUF)
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(ACC, TMP))
          end

          # The DMA3 control word for a source-fixed 16-bit fill of +count+ halfwords —
          # the Mode 4 fill unit (two packed indices per halfword).
          def dma_fill_control_16(count)
            count | DMA_ENABLE | DMA_SRC_FIXED # 16-bit is the default (DMA_16BIT == 0)
          end

          # Draw a line of text on the hidden page. Each lit font pixel is a single
          # color index (one byte), but the indexed screen can't take a lone byte
          # write, so each pixel is a read-modify-write: read the 16-bit unit that
          # contains it, splice the index into the correct half, write it back. The
          # glyph positions are known while building, so which half each pixel lands in
          # is settled here, not at run time. Off-screen pixels are dropped.
          def emit_draw_text_buffered(node)
            x, y = constant_ints!(node, x: node.x, y: node.y)
            index = @layout.palette.index_of(node.color)
            base = 6
            load_var(base, BACKBUF) # the hidden page base, held for the whole line

            Fonts.get(node.font).each_pixel(node.text) do |dx, dy|
              px = x + dx
              py = y + dy
              next unless @framebuffer.in_bounds?(px, py)

              emit_write_index_pixel_const(base, px, py, index)
            end
          end

          # Render one run-time digit on the hidden page through the shared glyph-
          # walking routine for this font (see #emit_digit_routines) — the tear-free
          # (indexed) counterpart of Drawing#emit_draw_digit_data, and built the same
          # way: the digit is already in r0 from evaluating node.value, and x, y and
          # the palette index follow as arguments in r1-r3 rather than being baked
          # into a fresh copy of the loop at every digit place.
          def emit_draw_digit_data_buffered(node, font, width, x, y)
            index = @layout.palette.index_of(node.color)
            @lowering.value(node.value)             # r0 = the digit (0..9)
            emit(ASM.load_immediate(1, x))
            emit(ASM.load_immediate(2, y))
            emit(ASM.load_immediate(3, index))
            emit_call_cold_routine(digit_routine_label(node.font, font, width))
          end

          # The shared routine's label for a font, reserved the first time a digit in
          # that font is drawn on this screen and emitted once, later, by
          # #emit_digit_routines. Named apart from Drawing's own digit routine (same
          # font, different plot) since a program can cross between the two screens.
          def digit_routine_label(font_name, font, width)
            @digit_routines ||= {}
            @digit_routines[font_name] ||= begin
              @pending_digit_routines ||= []
              @pending_digit_routines << [font_name, font, width]
              :"__digit_routine_buffered_#{font_name}"
            end
          end

          # Emit every shared digit routine this screen actually used, once each, after
          # the program's own code (see GBA#lower) — same shape as Drawing's own (a
          # fall-through guard, a label, a body, a return), because like that one this
          # is only ever reached by a call.
          #
          # x, y and the palette index arrive as arguments (r1, r2, r3); they move into
          # r10, r11 and r8 first, because the glyph table lookup that follows needs
          # r1-r3 back as scratch — and because loading the hidden page base in the
          # :hold phase below reaches for r12 (ADDR, see Primitives#emit_var_base) to
          # build its address, which would silently overwrite the index if it were
          # held there instead.
          def emit_digit_routines
            return unless @pending_digit_routines

            @pending_digit_routines.each do |font_name, font, width|
              emit(ASM.loop_forever) # fall-through guard: only ever entered by the call above
              place_label(:"__digit_routine_buffered_#{font_name}")
              emit(ASM.push(14))
              emit(ASM.mov_reg(10, 1)) # r10 = x, held across the routine
              emit(ASM.mov_reg(11, 2)) # r11 = y
              emit(ASM.mov_reg(8, 3))  # r8 = the palette index
              @framebuffer.emit_digit_glyph_loop(font_name, font, width) do |phase|
                case phase
                when :hold then load_var(9, BACKBUF)          # r9 = the hidden page base, held
                when :plot then emit_plot_digit_index(10, 11, 8)
                end
              end
              emit(ASM.pop(15))
            end
          end

          # Splice one glyph pixel's palette index onto the hidden page: find its byte at
          # (x+col, y+row), read the 16-bit unit that contains it, overwrite just that
          # pixel's byte — low for an even column, high for an odd one — and write it
          # back, since the indexed screen can't take a lone byte write. r9 holds the page
          # base; x_reg/y_reg/index_reg are the shared routine's arguments (see
          # #emit_digit_routines); r5/r4 are the live row/col; r0–r3 are scratch.
          def emit_plot_digit_index(x_reg, y_reg, index_reg)
            emit(ASM.add_reg(0, y_reg, 5))          # r0 = screen_y = y + row
            emit(ASM.load_immediate(1, SCREEN_WIDTH))
            emit(ASM.mul(2, 0, 1))                  # r2 = screen_y * width
            emit(ASM.add_reg(0, x_reg, 4))          # r0 = screen_x = x + col
            emit(ASM.add_reg(2, 2, 0))              # r2 = byte offset = screen_y*width + screen_x
            emit(ASM.add_reg(1, 9, 2))              # r1 = page_base + offset (the pixel's byte, maybe odd)
            emit(ASM.lsr_imm(1, 1, 1))              # clear the low bit ->
            emit(ASM.lsl_imm(1, 1, 1))              # r1 = the containing 16-bit unit's address
            emit(ASM.load_halfword(0, 1))           # r0 = the current pixel pair
            # width is even, so the offset's parity is the column's: 0 = low/even byte.
            emit(ASM.and_imm(3, 2, 1))              # r3 = screen_x & 1
            emit(ASM.cmp_imm(3, 0))
            high = gensym
            done = gensym
            emit_branch(:bcond, high, cond: :ne)
            splice_index_byte_reg(0, index_reg, false) # even column: the low byte
            emit_branch(:b, done)
            place_label(high)
            splice_index_byte_reg(0, index_reg, true)  # odd column: the high byte
            place_label(done)
            emit(ASM.store_halfword(0, 1))          # write the spliced pair back
          end

          # The same splice as #splice_index_byte, with the index arriving in a
          # register rather than a build-time constant — what the shared digit routine
          # needs, since one routine's index varies with which digit call reached it.
          def splice_index_byte_reg(reg, index_reg, high)
            if high
              emit(ASM.and_imm(reg, reg, 0x00FF))         # keep the left (low) pixel
              emit(ASM.orr_reg_lsl(reg, reg, index_reg, 8)) # set the right (high) pixel
            else
              emit(ASM.and_imm(reg, reg, 0xFF00))         # keep the right (high) pixel
              emit(ASM.orr_reg(reg, reg, index_reg))      # set the left (low) pixel
            end
          end

          # Plot one pixel on the hidden page. With constant coordinates the target
          # half is known while building; with a computed coordinate it's found from
          # the live x at run time.
          def emit_pixel_buffered(node)
            index = @layout.palette.index_of(node.color)
            xi = const_int(node.x)
            yi = const_int(node.y)

            if xi && yi
              return unless @framebuffer.in_bounds?(xi, yi)

              base = 6
              load_var(base, BACKBUF)
              emit_write_index_pixel_const(base, xi, yi, index)
            else
              emit_pixel_buffered_runtime(node, index)
            end
          end

          # Read-modify-write one pixel at a build-time-constant position: overwrite
          # its byte inside the 16-bit unit, leaving the paired pixel untouched.
          # +base_reg+ holds the hidden page base. Uses r0/r1 as scratch.
          def emit_write_index_pixel_const(base_reg, px, py, index)
            halfword_offset = ((py * SCREEN_WIDTH) + px) & ~1 # start of the pixel's 16-bit unit
            emit_add_const(1, base_reg, halfword_offset, ACC) # r1 = &unit (scratch r0)
            emit(ASM.load_halfword(ACC, 1))                   # r0 = the current pixel pair
            splice_index_byte(ACC, index, px.odd?)
            emit(ASM.store_halfword(ACC, 1))
          end

          # Read-modify-write one pixel whose coordinates are computed at run time: the
          # address and which half to touch both come from the live x/y. r2/r3 hold
          # x/y; r1 the unit address; r0 the value being spliced; r4/r5 scratch.
          def emit_pixel_buffered_runtime(node, index)
            @lowering.value(node.x)
            emit(ASM.mov_reg(2, ACC))
            @lowering.value(node.y)
            emit(ASM.mov_reg(3, ACC))

            emit(ASM.load_immediate(4, SCREEN_WIDTH))
            emit(ASM.mul(4, 3, 4))          # r4 = y * width
            emit(ASM.add_reg(4, 4, 2))      # r4 = y*width + x (byte offset)
            load_var(5, BACKBUF)            # r5 = hidden page base
            emit(ASM.add_reg(1, 5, 4))      # r1 = base + byte offset (maybe odd)
            emit(ASM.lsr_imm(1, 1, 1))      # clear the low bit ->
            emit(ASM.lsl_imm(1, 1, 1))      # r1 = the containing 16-bit unit's address
            emit(ASM.load_halfword(ACC, 1)) # r0 = the current pixel pair

            emit(ASM.and_imm(4, 2, 1))      # r4 = x & 1 (0 = left/low byte, 1 = right/high)
            emit(ASM.cmp_imm(4, 0))
            high = gensym
            done = gensym
            emit_branch(:bcond, high, cond: :ne)
            splice_index_byte(ACC, index, false) # even x: low byte
            emit_branch(:b, done)
            place_label(high)
            splice_index_byte(ACC, index, true)  # odd x: high byte
            place_label(done)
            emit(ASM.store_halfword(ACC, 1))
          end

          # Replace one byte of the 16-bit pixel pair in +reg+ with +index+, keeping
          # the other pixel: the high byte when +high+ (an odd column), else the low.
          def splice_index_byte(reg, index, high)
            if high
              emit(ASM.and_imm(reg, reg, 0x00FF))     # keep the left (low) pixel
              emit(ASM.orr_imm(reg, reg, index << 8)) # set the right (high) pixel
            else
              emit(ASM.and_imm(reg, reg, 0xFF00))     # keep the right (high) pixel
              emit(ASM.orr_imm(reg, reg, index))      # set the left (low) pixel
            end
          end

          # One column of a picture, stretched to a height the game works out — on the
          # tear-free screen.
          #
          # It walks DOWN THE SCREEN and asks which picture row belongs at each screen row,
          # exactly as the direct-color screen does, because that is what makes the two
          # screens and the interpreter land every pixel in the same place. What differs is
          # the two things this screen forces: a pixel is one BYTE (a number picking a color
          # out of the shared table) rather than two, and video memory refuses a lone byte —
          # the smallest write covers a side-by-side PAIR of pixels. So every pixel is a
          # read of its pair, a splice of its own half, and a write back.
          #
          # TWO QUESTIONS ARE ANSWERED ONCE HERE THAT THE OTHER SCREEN ASKS AT EVERY PIXEL,
          # and both come from the same fact: a column has ONE x for its whole height.
          #
          #   - The screen's left and right edges. A column is either on the screen or it is
          #     not, so it is tested before the first row instead of at every one.
          #   - WHICH HALF OF THE PAIR to write. A row is an even number of bytes across, so
          #     the parity of a pixel's address is the parity of its column — the same half,
          #     every row, all the way down. That also means the unit's address needs no
          #     rounding as it walks: it starts on the pair the column sits in and steps one
          #     screen width per row.
          def emit_draw_column_at_buffered(node)
            bmp = @layout.bitmaps.fetch(node.name) do
              raise LoweringError, "draw_column_at of undefined image #{node.name.inspect}"
            end
            width = node.width || 1
            clear = @layout.indexed_bitmaps[node.name]

            done = gensym
            @framebuffer.emit_column_setup(node, bmp, done, blob: @framebuffer.indexed_blob(node.name), pixel_bytes: 1)
            @framebuffer.emit_column_runs(node.name, bmp, done) do |leave|
              # Clipped BEFORE the destination is worked out, so the destination points at the
              # first row that shows rather than at a row above the screen.
              @framebuffer.emit_clip_column_rows(leave)
              emit_column_destination

              # A strip wholly inside the edges writes with nothing to test; one hanging over an
              # edge takes a second copy of the rows that tests each of its pixels. A strip one
              # pixel wide has no second case — it is inside or it draws nothing.
              clipped = gensym
              emit(ASM.cmp_imm(COLUMN_X, @framebuffer.clip_left))
              emit_branch(:bcond, clipped, cond: :lt)
              emit(ASM.load_immediate(TMP, @framebuffer.clip_right - width))
              emit(ASM.cmp_reg(COLUMN_X, TMP))
              emit_branch(:bcond, clipped, cond: :gt)

              emit_buffered_column_bodies(bmp, width, clear, Parity.of(node.x))
              emit_branch(:b, leave) if width > 1
              place_label(clipped)
              emit_buffered_column_rows { emit_buffered_column_row(bmp, width, clear, nil) } if width > 1
            end
            place_label(done)
          end

          # THE STRIP WRITES WHOLE PAIRS WHERE IT CAN, which needs to know whether it starts on
          # an even column or an odd one. Proved while building, that is one copy of the rows —
          # a view drawing its strips two pixels wide writes `col * 2`, and twice anything is
          # even. Otherwise the low bit is tested ONCE, here, and each answer gets its own copy:
          # every row of a strip starts in the same column, so a test inside the walk would ask
          # the same question a hundred and sixty times over.
          def emit_buffered_column_bodies(bmp, width, clear, parity)
            if parity
              return emit_buffered_column_rows do
                emit_buffered_column_row(bmp, width, clear, parity == :odd)
              end
            end

            odd = gensym
            both = gensym
            emit(ASM.and_imm(ACC, COLUMN_X, 1))
            emit(ASM.cmp_imm(ACC, 0))
            emit_branch(:bcond, odd, cond: :ne)
            emit_buffered_column_rows { emit_buffered_column_row(bmp, width, clear, false) }
            emit_branch(:b, both)
            place_label(odd)
            emit_buffered_column_rows { emit_buffered_column_row(bmp, width, clear, true) }
            place_label(both)
          end

          # The unit the strip's first row writes into: the hidden page, that row, and the
          # column rounded down to the pair it shares. A top above the screen makes this an
          # address before the page, which is fine — the walk steps forward to it and writes
          # nothing until the row is on screen.
          def emit_column_destination
            emit(ASM.load_immediate(TMP, SCREEN_WIDTH))
            emit(ASM.mul(COLUMN_DEST, COLUMN_Y, TMP)) # 1 byte a pixel, so this is bytes
            load_var(TMP, BACKBUF)
            emit(ASM.add_reg(COLUMN_DEST, COLUMN_DEST, TMP))
            emit(ASM.lsr_imm(TMP, COLUMN_X, 1)) # clear the low bit ->
            emit(ASM.lsl_imm(TMP, TMP, 1))      # ...the pair this column sits in
            emit(ASM.add_reg(COLUMN_DEST, COLUMN_DEST, TMP))
          end

          # The walk down the screen. The destination steps one screen width a row, which is
          # why the pair it points at needed rounding only once: a row is an even number of
          # bytes across, so every row of a strip sits the same way inside its pair.
          def emit_buffered_column_rows
            emit_row_loop(COLUMN_ROWS) do
              yield
              emit(ASM.add_reg(COLUMN_POS, COLUMN_POS, COLUMN_STEP))
              emit(ASM.add_imm(COLUMN_Y, COLUMN_Y, 1))
              emit(ASM.add_imm(COLUMN_DEST, COLUMN_DEST, SCREEN_WIDTH)) # one row down
            end
          end

          # One row of the strip: which picture row belongs at this screen row, read it, and
          # write it across — unless the row is off the top or bottom of the screen, in which
          # case the walk goes on without drawing, so a wall taller than the screen still lands
          # where it should. +starts_odd+ is nil in the copy that has to test each pixel.
          def emit_buffered_column_row(bmp, width, clear, starts_odd)
            skip = gensym
            emit_read_column_number(bmp, clear, skip)

            if starts_odd.nil?
              width.times { |dx| emit_buffered_column_pixel_clipped(dx) }
            else
              emit_buffered_column_units(width, starts_odd)
            end
            place_label(skip)
          end

          # number = picture[(pos >> 16) * width + slice], the slice already folded into
          # COLUMN_SRC. Leaves it in ACC, or jumps to +skip+ when the pixel is see-through.
          # Nothing holds the row back — see the note on the direct screen's reader for why it
          # cannot run past the picture.
          def emit_read_column_number(bmp, clear, skip)
            emit(ASM.lsr_imm(ACC, COLUMN_POS, COLUMN_FIXED))
            emit(ASM.load_immediate(TMP, bmp.width))
            emit(ASM.mul(ACC, ACC, TMP))
            emit(ASM.add_reg(ACC, COLUMN_SRC, ACC))
            emit(ASM.ldrb_offset(ACC, ACC, 0))

            # A see-through pixel carries the one number that is not any color in the table,
            # so it means "leave this one alone" and the pair is not touched at all.
            return unless clear

            emit(ASM.load_immediate(TMP, clear))
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, skip, cond: :eq)
          end

          # WHICH 16-BIT UNITS a strip of +width+ pixels touches, and what each one needs. A
          # unit whose BOTH pixels belong to the strip is written outright — no read, no
          # splice, since nothing of it survives. Only a unit the strip half covers has to be
          # read and spliced. That is what makes a strip cheaper than its pixels: three pixels
          # are one whole pair and one splice, not three splices.
          def column_units(width, starts_odd)
            first = starts_odd ? 1 : 0 # the strip's first pixel, as a byte within its pair
            (first...(first + width)).group_by { |byte| byte / 2 }.map do |unit, bytes|
              kind = if bytes.length == 2 then :both
                     elsif bytes.first.even? then :low
                     else :high
                     end
              [unit * 2, kind]
            end
          end

          def emit_buffered_column_units(width, starts_odd)
            units = column_units(width, starts_odd)
            # The number in both halves, for the units the strip covers whole.
            emit(ASM.orr_reg_lsl(SPARE, ACC, ACC, 8)) if units.any? { |(_, kind)| kind == :both }

            units.each do |offset, kind|
              next emit(ASM.store_halfword_offset(SPARE, COLUMN_DEST, offset)) if kind == :both

              emit(ASM.load_halfword_offset(TMP, COLUMN_DEST, offset))
              if kind == :high
                emit(ASM.and_imm(TMP, TMP, 0x00FF))
                emit(ASM.orr_reg_lsl(TMP, TMP, ACC, 8))
              else
                emit(ASM.and_imm(TMP, TMP, 0xFF00))
                emit(ASM.orr_reg(TMP, TMP, ACC))
              end
              emit(ASM.store_halfword_offset(TMP, COLUMN_DEST, offset))
            end
          end

          # One pixel of a strip that hangs off an edge: its own column is tested, and which
          # half of its pair it lands in is worked out as it goes. The dear way of doing it,
          # and only the strips at the edges of the screen ever run it.
          def emit_buffered_column_pixel_clipped(offset)
            past = gensym
            emit(ASM.add_imm(SPARE, COLUMN_X, offset))
            emit(ASM.cmp_imm(SPARE, @framebuffer.clip_left))
            emit_branch(:bcond, past, cond: :lt)
            emit(ASM.cmp_imm(SPARE, @framebuffer.clip_right))
            emit_branch(:bcond, past, cond: :ge)

            # The pixel's own byte, then the pair it sits in and which half of it that is.
            emit(ASM.and_imm(TMP, COLUMN_X, 1))
            emit(ASM.add_imm(TMP, TMP, offset))
            emit(ASM.add_reg(TMP, TMP, COLUMN_DEST))
            emit(ASM.and_imm(HIGH, TMP, 1))
            emit(ASM.lsr_imm(TMP, TMP, 1))
            emit(ASM.lsl_imm(TMP, TMP, 1))
            emit(ASM.load_halfword(SPARE, TMP))

            high = gensym
            wrote = gensym
            emit(ASM.cmp_imm(HIGH, 0))
            emit_branch(:bcond, high, cond: :ne)
            emit(ASM.and_imm(SPARE, SPARE, 0xFF00))
            emit(ASM.orr_reg(SPARE, SPARE, ACC))
            emit_branch(:b, wrote)
            place_label(high)
            emit(ASM.and_imm(SPARE, SPARE, 0x00FF))
            emit(ASM.orr_reg_lsl(SPARE, SPARE, ACC, 8))
            place_label(wrote)
            emit(ASM.store_halfword(SPARE, TMP))
            place_label(past)
          end

          # DRAW A WHOLE PICTURE on the hidden page.
          #
          # The picture is shipped a second time as one NUMBER a pixel (see
          # GBA#prepare_indexed_bitmaps), so a row of it is already the bytes the screen
          # wants and a row copy is a straight run of memory — the same shape the
          # direct-color blit has, with a byte a pixel instead of two.
          #
          # WHAT MAKES IT A STRAIGHT COPY IS THAT EVERYTHING LINES UP IN PAIRS. Video
          # memory here takes two pixels at a time and will not take one, so the copying
          # engine moves 16-bit units and every end of the run has to fall on one: the
          # column the picture starts at, the picture's own width, and therefore the part
          # of each row that survives clipping. An even column and an even width give all
          # three, which is why both are asked for rather than worked around.
          def emit_blit_buffered(node, bmp)
            see_through_not_drawn_here!(node.name) if @layout.indexed_bitmaps[node.name]
            odd_column_not_drawn_here!(node) unless Parity.even?(node.x)
            odd_width_not_drawn_here!(node.name, bmp) unless bmp.width.even?

            emit_blit_rows_buffered(node, bmp)
          end

          # Registers held for the whole picture: r6 the picture's numbers in the
          # cartridge, r7 its left column, r8 its top row. The rest are worked out afresh
          # each row, exactly as the direct-color engine does — a picture is a handful of
          # rows, not the hundreds a per-column renderer walks, so there is nothing here
          # worth hoisting.
          BLIT_SRC = 6
          BLIT_X = 7
          BLIT_Y = 8
          BLIT_ROW_Y = 9
          BLIT_UNITS = 4
          BLIT_FROM = 5
          BLIT_TO = 3
          BLIT_LEFT = 10
          BLIT_RIGHT = 11

          # One clipped row copy per row of the picture, unrolled. A row above or below
          # the area is dropped whole; a row hanging off a side is narrowed to the part
          # that shows, so nothing is ever written past the end of a line and onto the
          # start of the next one.
          def emit_blit_rows_buffered(node, bmp)
            @lowering.value(node.x)
            emit(ASM.mov_reg(BLIT_X, ACC))
            @lowering.value(node.y)
            emit(ASM.mov_reg(BLIT_Y, ACC))
            emit_load_data_address(BLIT_SRC, @framebuffer.indexed_blob(node.name))

            bmp.height.times { |row| emit_blit_row_buffered(bmp, row) }
          end

          def emit_blit_row_buffered(bmp, row)
            skip = gensym
            emit_add_const(BLIT_ROW_Y, BLIT_Y, row, SPARE)
            emit(ASM.cmp_imm(BLIT_ROW_Y, @framebuffer.clip_top))
            emit_branch(:bcond, skip, cond: :lt)
            emit(ASM.cmp_imm(BLIT_ROW_Y, @framebuffer.clip_bottom))
            emit_branch(:bcond, skip, cond: :ge)

            emit_blit_row_span(bmp, skip)
            emit_blit_row_addresses(bmp, row)
            emit_blit_row_copy
            place_label(skip)
          end

          # What is left of this row after the sides: r10 its first column, r11 one past
          # its last, r4 how many pixels that is. A row entirely off to one side leaves.
          def emit_blit_row_span(bmp, skip)
            emit(ASM.mov_reg(BLIT_LEFT, BLIT_X))
            emit(ASM.cmp_imm(BLIT_X, @framebuffer.clip_left))
            keep_left = gensym
            emit_branch(:bcond, keep_left, cond: :ge)
            emit(ASM.load_immediate(BLIT_LEFT, @framebuffer.clip_left))
            place_label(keep_left)

            emit_add_const(BLIT_RIGHT, BLIT_X, bmp.width, SPARE)
            emit(ASM.cmp_imm(BLIT_RIGHT, @framebuffer.clip_right))
            keep_right = gensym
            emit_branch(:bcond, keep_right, cond: :le)
            emit(ASM.load_immediate(BLIT_RIGHT, @framebuffer.clip_right))
            place_label(keep_right)

            emit(ASM.sub_reg(BLIT_UNITS, BLIT_RIGHT, BLIT_LEFT))
            emit(ASM.cmp_imm(BLIT_UNITS, 0))
            emit_branch(:bcond, skip, cond: :le)
          end

          # Where the row is read from (r5) and written to (r3). Both are byte addresses
          # and both are even: the picture's width is even so a row starts on a pair, and
          # the column is even so what the sides cut off is a whole number of pairs.
          def emit_blit_row_addresses(bmp, row)
            emit(ASM.sub_reg(BLIT_FROM, BLIT_LEFT, BLIT_X))     # how much of the row the left edge ate
            emit_add_const(BLIT_FROM, BLIT_FROM, row * bmp.width, SPARE)
            emit(ASM.add_reg(BLIT_FROM, BLIT_SRC, BLIT_FROM))

            emit(ASM.load_immediate(SPARE, SCREEN_WIDTH))
            emit(ASM.mul(BLIT_TO, BLIT_ROW_Y, SPARE)) # a byte a pixel, so this is already bytes
            emit(ASM.add_reg(BLIT_TO, BLIT_TO, BLIT_LEFT))
            load_var(SPARE, BACKBUF)
            emit(ASM.add_reg(BLIT_TO, BLIT_TO, SPARE))
          end

          # Hand the row to the copying engine: two pixels a unit, source and destination
          # both stepping forward.
          def emit_blit_row_copy
            emit(ASM.lsr_imm(BLIT_UNITS, BLIT_UNITS, 1))
            emit(ASM.load_immediate(SPARE, DMA_ENABLE))
            emit(ASM.orr_reg(BLIT_UNITS, BLIT_UNITS, SPARE))
            emit(ASM.load_immediate(TMP, REG_DMA3SAD))
            emit(ASM.str(BLIT_FROM, TMP))
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(BLIT_TO, TMP))
            emit(ASM.load_immediate(TMP, REG_DMA3CNT))
            emit(ASM.str(BLIT_UNITS, TMP))
          end

          # WHY THE SCREEN WANTS PAIRS, said the same way in every one of these three. It is
          # the one fact behind all of them, and a person who reads it once has read it.
          TAKES_PAIRS = "The screen takes two pixels at a time and will not take one."

          def see_through_not_drawn_here!(name)
            raise LoweringError,
                  "The picture :#{name} has see-through pixels. The tear-free screen " \
                  "(`tear_free: true`) cannot draw a see-through picture yet. It draws a solid " \
                  "picture. Draw this picture with no see-through pixels, or drop `tear_free:` to " \
                  "use the direct-color screen, where a see-through picture works."
          end

          def odd_column_not_drawn_here!(node)
            column = const_int(node.x)
            found = column ? "This picture starts at column #{column}." : "The game works this column out as it runs."
            fix = column ? "Move the picture one pixel." : "Work the column out as an even number. Multiply it by 2."
            raise LoweringError,
                  "On the tear-free screen (`tear_free: true`), a picture must start at an even " \
                  "column. #{found} #{TAKES_PAIRS} The framework cannot copy a picture that starts " \
                  "halfway through a pair. #{fix}"
          end

          def odd_width_not_drawn_here!(name, bmp)
            raise LoweringError,
                  "On the tear-free screen (`tear_free: true`), a picture must have an even width. " \
                  "The picture :#{name} is #{bmp.width} pixels wide. #{TAKES_PAIRS} The framework " \
                  "cannot copy a row that ends halfway through a pair. Add a column to the picture, " \
                  "or drop `tear_free:` to use the direct-color screen."
          end
        end
      end
    end
  end
end
