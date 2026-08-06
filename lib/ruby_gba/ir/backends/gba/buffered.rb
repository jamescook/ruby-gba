# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Double-buffered (Mode 4) drawing, onto the hidden page.
        module Buffered
          include Constants

          #
          # These mirror the direct-color fills above, with two differences forced by
          # the indexed screen: a pixel is one byte (an index into the color table),
          # not two, so addresses and counts are in bytes; and video memory can't be
          # written a single byte at a time (a lone byte write hits both halves of its
          # 16-bit slot), so fills move whole 16-bit units — two pixels — at once, and
          # a block fill must start on an even column (a rect asked for an odd one
          # gets its two edge pixels written singly instead). The destination is the
          # hidden page, whose address lives in a run-time variable (BACKBUF) and
          # swaps every flip.

          # Clear the hidden page to a solid color: one DMA that repeats the packed
          # index word across the whole page.
          def emit_clear_screen_buffered(node)
            scratch = hold_index_word(node[:color])
            store_word_immediate(scratch, REG_DMA3SAD)
            point_dma_dest_at_backbuf
            count = SCREEN_WIDTH * SCREEN_HEIGHT / 4 # 32-bit words, 4 indices each
            store_word_immediate(dma_fill_control(count), REG_DMA3CNT)
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
            x, y, w, h = constant_ints!(node, :x, :y, :w, :h)
            even_width!(w, node.kind)
            scratch = hold_index_word(node[:color])
            index = @palette.index_of(node[:color])
            edges = x.odd?
            middle_x = edges ? x + 1 : x
            middle_w = edges ? w - 2 : w # a two-pixel rect at an odd column is all edge

            base = 6
            load_var(base, BACKBUF) # the hidden page base, held for the whole rect

            h.times do |dy|
              row = y + dy
              next unless (0...SCREEN_HEIGHT).cover?(row)

              emit_write_index_pixel_const(base, x, row, index) if edges && in_bounds?(x, row)
              emit_buffered_row_fill(base: base, x: middle_x, row: row, w: middle_w, scratch: scratch) if middle_w.positive?
              emit_write_index_pixel_const(base, x + w - 1, row, index) if edges && in_bounds?(x + w - 1, row)
            end
          end

          # DMA one row of a rect into the hidden page: +w+ pixels from the even column
          # +x+ of +row+. +base+ is the register holding the hidden page base.
          def emit_buffered_row_fill(base:, x:, row:, w:, scratch:)
            store_word_immediate(scratch, REG_DMA3SAD)
            emit_add_const(ACC, base, (row * SCREEN_WIDTH) + x, TMP) # + byte offset (1 byte/pixel)
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(ACC, TMP))                                  # destination = that row
            store_word_immediate(dma_fill_control_16(w / 2), REG_DMA3CNT)
          end

          # A rectangle at a run-time position, filled per row into the hidden page.
          # Only its row moves in the general case — but an odd column fills
          # differently from an even one (see emit_fill_rect_buffered), so the shape of
          # a row depends on a number the game works out as it runs.
          #
          # A rect whose column is a plain number still settles it while building, and
          # only that one shape is emitted. Otherwise the low bit of x is tested ONCE
          # here and each case gets its own copy of the rows: every row of a rect starts
          # on the same column, so a test inside the loop would ask the same question
          # over and over, and the common even column keeps costing exactly what it did.
          # r2/r3 hold x/y across both copies.
          def emit_draw_rect_at_buffered(node)
            w, h = constant_ints!(node, :w, :h)
            even_width!(w, :draw_rect_at)
            scratch = hold_index_word(node[:color])
            index = @palette.index_of(node[:color])
            rows = { w: w, h: h, scratch: scratch, index: index }

            eval_value(node[:x])
            emit(ASM.mov_reg(RECT_X, ACC))
            eval_value(node[:y])
            emit(ASM.mov_reg(RECT_Y, ACC))

            column = const_int(node[:x])
            return emit_buffered_rect_rows(**rows, edges: column.odd?) if column

            odd_column = gensym
            done = gensym
            emit(ASM.and_imm(ACC, RECT_X, 1))
            emit(ASM.cmp_imm(ACC, 0))
            emit_branch(:bcond, odd_column, cond: :ne)
            emit_buffered_rect_rows(**rows, edges: false)
            emit_branch(:b, done)
            place_label(odd_column)
            emit_buffered_rect_rows(**rows, edges: true)
            place_label(done)
          end

          # The unrolled rows of a run-time-positioned rect. +edges+ says the column is
          # odd, so each row's first and last pixel are spliced in one at a time and the
          # DMA covers only the even middle. Registers through the whole run: r2 the
          # rect's x, r3 its y, r4 the address of the row's first column, r5 scratch.
          RECT_X = 2
          RECT_Y = 3
          RECT_ROW = 4
          RECT_ADDR = 5

          def emit_buffered_rect_rows(w:, h:, scratch:, index:, edges:)
            middle_w = edges ? w - 2 : w

            h.times do |dy|
              # r4 = the hidden page's address of column 0 on row (y + dy)
              if dy.zero?
                emit(ASM.mov_reg(RECT_ROW, RECT_Y))
              else
                emit(ASM.add_imm(RECT_ROW, RECT_Y, dy))
              end
              emit(ASM.load_immediate(RECT_ADDR, SCREEN_WIDTH))
              emit(ASM.mul(RECT_ROW, RECT_ADDR, RECT_ROW)) # r4 = SCREEN_WIDTH * (y + dy), 1 byte/pixel
              load_var(RECT_ADDR, BACKBUF)                 # r5 = hidden page base
              emit(ASM.add_reg(RECT_ROW, RECT_ROW, RECT_ADDR))

              emit_splice_rect_edge(index: index, offset: 0, high: true) if edges
              emit_buffered_rect_row_dma(offset: edges ? 1 : 0, w: middle_w, scratch: scratch) if middle_w.positive?
              emit_splice_rect_edge(index: index, offset: w - 1, high: false) if edges
            end
          end

          # DMA one row of a run-time-positioned rect: +w+ pixels starting +offset+
          # columns right of the rect's x, on the row whose address r4 holds.
          def emit_buffered_rect_row_dma(offset:, w:, scratch:)
            emit(ASM.add_reg(RECT_ADDR, RECT_ROW, RECT_X))
            emit_add_const(RECT_ADDR, RECT_ADDR, offset, ACC)
            store_word_immediate(scratch, REG_DMA3SAD)
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(RECT_ADDR, TMP))
            store_word_immediate(dma_fill_control_16(w / 2), REG_DMA3CNT)
          end

          # Splice one edge pixel of a run-time-positioned rect into the hidden page:
          # the pixel +offset+ columns right of the rect's x, on the row whose address
          # r4 holds. Its 16-bit unit also holds a pixel outside the rect, so read the
          # unit, replace only this pixel's half, and write it back. The rect's x is
          # odd here, which makes the left edge the high half of its unit and the right
          # edge (x + w - 1, an even column, since the width is even) the low half of
          # its own — so only the left edge's address needs its low bit cleared.
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
            index = @palette.index_of(color)
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
            x, y = constant_ints!(node, :x, :y)
            index = @palette.index_of(node[:color])
            base = 6
            load_var(base, BACKBUF) # the hidden page base, held for the whole line

            Fonts.get(node[:font]).each_pixel(node[:text]) do |dx, dy|
              px = x + dx
              py = y + dy
              next unless in_bounds?(px, py)

              emit_write_index_pixel_const(base, px, py, index)
            end
          end

          # Render one run-time digit on the hidden page from the embedded glyph table —
          # the tear-free (indexed) counterpart of emit_draw_digit_data. It walks the ten
          # digit glyphs with the same shared loop, but plots a palette index into VRAM
          # instead of a color. The hidden page base flips each frame, so it's held live
          # in r9 for the whole glyph; the index is a build-time constant.
          def emit_draw_digit_data_buffered(node, font, width, x, y)
            index = @palette.index_of(node[:color])
            emit_digit_glyph_loop(node, font, width) do |phase|
              case phase
              when :hold then load_var(9, BACKBUF)         # r9 = the hidden page base, held
              when :plot then emit_plot_digit_index(x, y, index)
              end
            end
          end

          # Splice one glyph pixel's palette index onto the hidden page: find its byte at
          # (x+col, y+row), read the 16-bit unit that contains it, overwrite just that
          # pixel's byte — low for an even column, high for an odd one — and write it
          # back, since the indexed screen can't take a lone byte write. r9 holds the page
          # base; r5/r4 are the live row/col; r0–r3 are scratch.
          def emit_plot_digit_index(x, y, index)
            emit_add_const(0, 5, y, 1)              # r0 = screen_y = y + row
            emit(ASM.load_immediate(1, SCREEN_WIDTH))
            emit(ASM.mul(2, 0, 1))                  # r2 = screen_y * width
            emit_add_const(0, 4, x, 1)              # r0 = screen_x = x + col
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
            splice_index_byte(0, index, false)      # even column: the low byte
            emit_branch(:b, done)
            place_label(high)
            splice_index_byte(0, index, true)       # odd column: the high byte
            place_label(done)
            emit(ASM.store_halfword(0, 1))          # write the spliced pair back
          end

          # Plot one pixel on the hidden page. With constant coordinates the target
          # half is known while building; with a computed coordinate it's found from
          # the live x at run time.
          def emit_pixel_buffered(node)
            index = @palette.index_of(node[:color])
            xi = const_int(node[:x])
            yi = const_int(node[:y])

            if xi && yi
              return unless in_bounds?(xi, yi)

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
            eval_value(node[:x])
            emit(ASM.mov_reg(2, ACC))
            eval_value(node[:y])
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

          # blit doesn't work on the indexed screen: its images are stored as direct
          # colors, which need converting to palette indices first. Point at what does.
          def blit_unsupported_in_buffered!
            raise LoweringError,
                  "`blit` cannot draw on the tear-free screen (`tear_free: true`). Its images hold direct " \
                  "colors. The tear-free screen shows colors from a color table, so it cannot show them. " \
                  "To draw there, use the rectangle fills, `draw_text`, or `pixel`. Or drop `tear_free:` " \
                  "to use the direct-color screen, where `blit` works."
          end
        end
      end
    end
  end
end
