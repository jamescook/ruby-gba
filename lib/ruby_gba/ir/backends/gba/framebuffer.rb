# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # What the direct-color and tear-free screens share: both are a flat run of
        # pixels the console never redraws for you, so both need the same handful of
        # things worked out — where drawing may land right now (an `inside` area, or
        # the whole screen), a solid fill's control words, walking a stretched picture
        # column, and the run-time digit glyph loop. Neither screen owns this; it is
        # the shape a framebuffer has, whichever one is live.
        class Framebuffer
          include Constants

          # HOW A PICTURE ROW BECOMES A SCREEN ROW, which is a divide by the picture's own
          # height: a stretch that covers rows 8 to 15 of a 64-row picture covers the eighth
          # to the fifteenth part of however tall the column is drawn.
          #
          # The chip has no divide instruction, so a divide is normally a subroutine — far too
          # dear for something a stretch does twice. A height that is a power of two escapes
          # that by SHIFTING, which is one instruction, and for a long time that was the only
          # height a picture could have and still ship its stretches.
          #
          # ANY OTHER HEIGHT MULTIPLIES INSTEAD. Dividing by 38 is the same as multiplying by
          # 1/38, and while the chip holds no fractions it does hold the whole 64-bit answer of
          # a multiply — so multiplying by 2^32/38 and keeping the TOP half divides by 38. The
          # multiplier is worked out here, while the program is being built, and costs the walk
          # one instruction over the shift.
          #
          # The multiplier is rounded DOWN, so its answer can land one row early. That is the
          # safe direction at the near end of a stretch (a row too early draws nothing extra,
          # since the walk still asks each row whether its pixel is see-through) and the unsafe
          # one at the far end, which is why that end takes a second spare row.
          ColumnDivide = Data.define(:shift, :magic, :spare_rows) do
            def self.for(height)
              if height.positive? && (height & (height - 1)).zero?
                new(shift: height.bit_length - 1, magic: nil, spare_rows: 1)
              else
                new(shift: nil, magic: (1 << 32) / height, spare_rows: 2)
              end
            end

            def by_multiply? = !magic.nil?
          end

          def initialize(emitter:, primitives:, lowering:, divide:, run_bitmaps:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @divide = divide
            @run_bitmaps = run_bitmaps
          end

          # WHERE DRAWING MAY LAND. The whole screen, unless an `inside` says otherwise
          # — and then these four are what every shape cuts itself against.
          def clip_left = (area = @lowering.draw_area) ? area[0] : 0
          def clip_top = (area = @lowering.draw_area) ? area[1] : 0
          def clip_right = (area = @lowering.draw_area) ? area[0] + area[2] : SCREEN_WIDTH
          def clip_bottom = (area = @lowering.draw_area) ? area[1] + area[3] : SCREEN_HEIGHT
          def clipping? = !@lowering.draw_area.nil?

          # Is this cell one drawing may land on? The screen, held further to whatever
          # area is in force — so a shape whose place is known while building is simply
          # not emitted for the parts that fall outside.
          def in_bounds?(x, y)
            (clip_left...clip_right).cover?(x) && (clip_top...clip_bottom).cover?(y)
          end

          # Stash a solid fill color as a packed two-pixel word in IWRAM and return its
          # address — the fixed source a DMA fill re-reads for every pixel.
          def hold_fill_word(color)
            value = Color.resolve(color)
            word = (value << 16) | value
            scratch = @primitives.var_addr(:_dma_scratch)
            @primitives.store_word_immediate(word, scratch)
            scratch
          end

          # The DMA3 control word for a source-fixed 32-bit fill of +count+ words.
          def dma_fill_control(count)
            count | DMA_ENABLE | DMA_32BIT | DMA_SRC_FIXED
          end

          # The same fill, one pixel per transfer instead of two.
          #
          # DMA moves whole units and quietly rounds the destination address DOWN to
          # that unit's size. A 32-bit transfer therefore needs a 4-byte-aligned
          # destination — and at 2 bytes per pixel, only EVEN screen columns are.
          # Aim a 32-bit fill at an odd column and the hardware silently shifts it a
          # pixel to the left, with nothing to say it did. A 16-bit transfer needs
          # only 2-byte alignment, which every pixel address has, so it lands where
          # it was asked to whatever the column.
          #
          # The cost is twice as many transfers, so it is used only where an odd
          # column is possible: see #fill_control_for_column.
          def dma_fill_control_halfwords(count)
            count | DMA_ENABLE | DMA_SRC_FIXED # 16-bit is the default (DMA_16BIT == 0)
          end

          # Pick the widest fill unit that lands on +x+. Pass the column when it is
          # known at build time (an even one keeps the fast two-pixel transfer), or
          # nil when the program computes it at run time and either parity is
          # possible — then correctness decides and we fill a pixel at a time.
          # A whole-word transfer moves two pixels at once, so it needs a run that both
          # STARTS on an even column and holds an even number. A run held to an area
          # can fail either test, and then it goes a pixel at a time.
          def fill_control_for_column(x, w)
            return dma_fill_control(w / 2) if x&.even? && w.even?

            dma_fill_control_halfwords(w)
          end

          # Point DMA3 at (source, destination), then kick it off — one filled row.
          def fire_dma_fill(source_addr, dest_addr, control)
            @primitives.store_word_immediate(source_addr, REG_DMA3SAD)
            @primitives.store_word_immediate(dest_addr, REG_DMA3DAD)
            @primitives.store_word_immediate(control, REG_DMA3CNT)
          end

          # Guard the fast block-fill's even-width assumption: it moves two pixels at
          # a time, so an odd width would drop the last column (and a width of 0 or 1
          # would ask DMA for a runaway transfer).
          def even_width!(w, kind)
            return if w.positive? && w.even?

            raise LoweringError,
                  "#{kind} needs an even, positive width (got #{w}) — the fast " \
                  "block fill moves two pixels per step"
          end

          # What a blob that ships where a picture's columns hold pixels is filed
          # under, beside its colors — see #register_column_runs on the backend.
          def indexed_blob(name) = :"#{name}#{INDEXED_SUFFIX}"
          def runs_blob(name) = :"#{name}#{RUNS_SUFFIX}"
          def runs_start_blob(name) = :"#{name}#{RUNS_START_SUFFIX}"

          # Everything a column needs before its first row: how many rows, how far down
          # the picture each one moves, where it starts on screen, and where its pixels
          # come from.
          #
          # +blob+ and +pixel_bytes+ differ by screen: the direct-color one reads the
          # picture's colors, two bytes each, and the tear-free one reads the same
          # picture as palette numbers, one byte each.
          def emit_column_setup(node, bmp, done, blob: node.name, pixel_bytes: 2)
            @lowering.value(node.height)
            @emitter.emit(ASM.mov_reg(COLUMN_ROWS, ACC))
            @emitter.emit(ASM.cmp_imm(COLUMN_ROWS, 0))
            @emitter.emit_branch(:bcond, done, cond: :le) # a column of no height draws nothing

            # step = (picture height << 16) / height, by the shared divide routine —
            # which takes the numerator in TMP and the divisor in ACC, and hands the
            # answer back in ACC.
            @emitter.emit(ASM.load_immediate(TMP, bmp.height << COLUMN_FIXED))
            @emitter.emit(ASM.mov_reg(ACC, COLUMN_ROWS))
            @divide.emit_call_divide_routine
            @emitter.emit(ASM.mov_reg(COLUMN_STEP, ACC))

            @lowering.value(node.x)
            @emitter.emit(ASM.mov_reg(COLUMN_X, ACC))
            @lowering.value(node.top)
            @emitter.emit(ASM.mov_reg(COLUMN_Y, ACC))

            # The picture's column: its first pixel is `slice` pixels along its first
            # row, and its rows are a whole picture width apart.
            @lowering.value(node.slice)
            emit_clamp_to(ACC, bmp.width - 1)
            emit_column_runs_pointer(node.name) # ...and where THIS column holds its pixels
            @emitter.emit(ASM.lsl_imm(ACC, ACC, 1)) if pixel_bytes == 2
            @emitter.emit_load_data_address(COLUMN_SRC, blob)
            @emitter.emit(ASM.add_reg(COLUMN_SRC, COLUMN_SRC, ACC))
          end

          # This column's list of the stretches of rows that hold pixels. ACC holds the
          # picture's column coming in and still holds it going out.
          def emit_column_runs_pointer(name)
            return unless @run_bitmaps.include?(name)

            @emitter.emit(ASM.lsl_imm(SPARE, ACC, 1)) # a halfword a column
            @emitter.emit_load_data_address(TMP, runs_start_blob(name))
            @emitter.emit(ASM.add_reg(TMP, TMP, SPARE))
            @emitter.emit(ASM.load_halfword(SPARE, TMP))
            @emitter.emit_load_data_address(COLUMN_RUNS, runs_blob(name))
            @emitter.emit(ASM.add_reg(COLUMN_RUNS, COLUMN_RUNS, SPARE))
          end

          # THE WALK, ONCE PER STRETCH OF PIXELS instead of once down the whole square.
          #
          # A picture that ships no list is drawn in one pass over its full height,
          # which is what every picture did before there were lists and what an opaque
          # one still does. One that ships one goes round here, and the body it yields
          # to is emitted once however many stretches a column turns out to have.
          #
          # +bail+ is where a column with no rows left to draw goes; the block is
          # handed the label to jump to when ITS stretch has none, which is the next
          # stretch rather than the end.
          #
          # THE PICTURE CANNOT CHANGE, however the arithmetic rounds. The walk still
          # asks each row it does reach whether its pixel is see-through, so a stretch
          # a row too wide costs one row and draws nothing extra; and a stretch is
          # never too NARROW, because its first row is rounded down and its last is
          # rounded up with a row to spare. See {ColumnDivide} for how each end is
          # rounded and why the far one sometimes wants a second spare row.
          def emit_column_runs(name, bmp, bail)
            unless @run_bitmaps.include?(name)
              @emitter.emit(ASM.load_immediate(SPARE, 0))
              @emitter.emit(ASM.mov_reg(HIGH, COLUMN_ROWS))
              return yield(bail)
            end

            divide = ColumnDivide.for(bmp.height)
            # The full height and the unclipped top, which every stretch measures itself
            # against and the walk itself spends. There is one register spare in a
            # column and the list needs it, so these two wait here — and the multiplier,
            # on a picture whose height needs one, waits with them.
            held = divide.by_multiply? ? [ACC, COLUMN_Y, COLUMN_ROWS] : [COLUMN_Y, COLUMN_ROWS]
            at = ->(reg) { held.index(reg) * 4 } # where each one waits, since the list has two lengths
            @emitter.emit(ASM.load_immediate(ACC, divide.magic)) if divide.by_multiply?
            @emitter.emit(ASM.push(*held))

            top = @emitter.gensym
            finish = @emitter.gensym
            @emitter.place_label(top)
            @emitter.emit(ASM.ldrb_offset(ACC, COLUMN_RUNS, 0))
            @emitter.emit(ASM.cmp_imm(ACC, RUNS_END))
            @emitter.emit_branch(:bcond, finish, cond: :eq)
            @emitter.emit(ASM.ldrb_offset(HIGH, COLUMN_RUNS, 1))
            @emitter.emit(ASM.add_imm(COLUMN_RUNS, COLUMN_RUNS, 2))
            @emitter.emit(ASM.ldr_offset(COLUMN_ROWS, STACK, at[COLUMN_ROWS]))

            # Both ends of the stretch, each a picture row times the height on screen and
            # then divided by the picture's own height. COLUMN_Y is somewhere to keep the
            # second product while the first is divided; it is loaded back below.
            @emitter.emit(ASM.mul(TMP, ACC, COLUMN_ROWS))
            @emitter.emit(ASM.add_imm(HIGH, HIGH, 1))
            @emitter.emit(ASM.mul(COLUMN_Y, HIGH, COLUMN_ROWS))
            @emitter.emit(ASM.ldr_offset(ACC, STACK, at[ACC])) if divide.by_multiply?
            emit_column_divide(divide, from: TMP, into: SPARE, spill: HIGH) # the first screen row...
            emit_column_divide(divide, from: COLUMN_Y, into: HIGH, spill: TMP)
            # ...and one past the last, with a row to spare.
            @emitter.emit(ASM.add_imm(HIGH, HIGH, divide.spare_rows))
            @emitter.emit(ASM.ldr_offset(COLUMN_Y, STACK, at[COLUMN_Y]))

            after = @emitter.gensym
            yield(after)
            @emitter.place_label(after)
            @emitter.emit_branch(:b, top)
            @emitter.place_label(finish)
            @emitter.emit(ASM.pop(*held))
          end

          # One end of a stretch, from a picture row times the height on screen to the screen
          # row it lands on. A shift where the picture's height allows one; otherwise the long
          # multiply, whose top half IS the answer — and which writes a whole 64-bit product,
          # so it needs somewhere to put the half nothing reads (+spill+). ACC carries the
          # multiplier, loaded from the stack by the caller.
          #
          # A picture ONE row tall is the odd one out: dividing by one changes nothing, so the
          # number is carried across as it stands.
          def emit_column_divide(divide, from:, into:, spill:)
            if divide.by_multiply?
              @emitter.emit(ASM.smull(spill, into, from, ACC))
            elsif divide.shift.zero?
              @emitter.emit(ASM.mov_reg(into, from))
            else
              @emitter.emit(ASM.lsr_imm(into, from, divide.shift))
            end
          end

          # WHICH ROWS OF THE COLUMN ARE ACTUALLY ON THE SCREEN, worked out once before
          # the walk starts.
          #
          # A wall you are nose-to-nose with is many times taller than the screen.
          # Walking every one of its rows and throwing away the ones above and below
          # is work that grows with how close you stand — and it is why a game would
          # otherwise have to hold its wall heights to a ceiling, which is a lie about
          # perspective at exactly the moment the player can see it best. So the walk
          # starts on the first row that shows and stops after the last, and a column
          # of any height costs what is on screen.
          #
          # COLUMN_ROWS holds the height coming in and how many rows to walk going out;
          # COLUMN_Y and COLUMN_POS are moved to that first visible row. Jumps to +done+
          # when nothing of the column shows at all.
          def emit_clip_column_rows(done)
            above = @emitter.gensym
            @emitter.emit(ASM.rsb_imm(ACC, COLUMN_Y, clip_top)) # rows above where drawing may land...
            @emitter.emit(ASM.cmp_reg(ACC, SPARE))
            @emitter.emit_branch(:bcond, above, cond: :ge)
            @emitter.emit(ASM.mov_reg(ACC, SPARE))       # ...or where the picture's own pixels start
            @emitter.place_label(above)

            # Stop at the bottom edge, or after the picture's last pixel in this column,
            # whichever comes first — then take off the rows skipped at the top.
            under = @emitter.gensym
            @emitter.emit(ASM.load_immediate(TMP, clip_bottom))
            @emitter.emit(ASM.sub_reg(TMP, TMP, COLUMN_Y)) # one past the last row that shows
            @emitter.emit(ASM.cmp_reg(TMP, HIGH))
            @emitter.emit_branch(:bcond, under, cond: :le)
            @emitter.emit(ASM.mov_reg(TMP, HIGH))
            @emitter.place_label(under)
            past = @emitter.gensym
            @emitter.emit(ASM.cmp_reg(COLUMN_ROWS, TMP))
            @emitter.emit_branch(:bcond, past, cond: :le)
            @emitter.emit(ASM.mov_reg(COLUMN_ROWS, TMP))
            @emitter.place_label(past)
            @emitter.emit(ASM.sub_reg(COLUMN_ROWS, COLUMN_ROWS, ACC))
            @emitter.emit(ASM.cmp_imm(COLUMN_ROWS, 0))
            @emitter.emit_branch(:bcond, done, cond: :le)

            # Start the walk where it becomes visible, which is what keeps the picture
            # in the same place: the rows skipped are stepped over rather than left out.
            @emitter.emit(ASM.add_reg(COLUMN_Y, COLUMN_Y, ACC))
            @emitter.emit(ASM.mul(COLUMN_POS, ACC, COLUMN_STEP))
          end

          # Hold a register between 0 and +top+, so a slice or a row worked out past
          # the edge of the picture reads its last pixel rather than whatever is next
          # in memory.
          def emit_clamp_to(reg, top)
            keep = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(reg, 0))
            @emitter.emit_branch(:bcond, keep, cond: :ge)
            @emitter.emit(ASM.load_immediate(reg, 0))
            @emitter.place_label(keep)

            under = @emitter.gensym
            @emitter.emit(ASM.load_immediate(TMP, top))
            @emitter.emit(ASM.cmp_reg(reg, TMP))
            @emitter.emit_branch(:bcond, under, cond: :le)
            @emitter.emit(ASM.mov_reg(reg, TMP))
            @emitter.place_label(under)
          end

          # Work out a run-time rect's x, y, row count and width into their registers.
          #
          # The two coordinates go via the stack rather than straight into their
          # registers, because working out the SECOND one can use the register the
          # first was just parked in — a multiply of two numbers holding a fraction
          # borrows exactly those. The stack is the one place nothing else touches.
          # The size registers are high enough that nothing evaluating an expression
          # reaches them, so those can be filled in place.
          def eval_rect_position(node, x_reg:, y_reg:, rows_reg:, width_reg: nil)
            @lowering.value(node.x)
            @emitter.emit(ASM.push(ACC))
            @lowering.value(node.y)
            @emitter.emit(ASM.push(ACC))
            unless @primitives.const_int(node.h)
              @lowering.value(node.h)
              @emitter.emit(ASM.mov_reg(rows_reg, ACC))
            end
            if width_reg && !@primitives.const_int(node.w)
              @lowering.value(node.w)
              @emitter.emit(ASM.mov_reg(width_reg, ACC))
            end
            @emitter.emit(ASM.pop(y_reg))
            @emitter.emit(ASM.pop(x_reg))
          end

          # Walk the ten-glyph table for a run-time digit, calling +block+ once per set
          # pixel to plot it — the shared skeleton behind the direct and tear-free
          # digit renders. The ten glyphs live in ROM as row bytes (glyph d at
          # d*height, one byte per row, the low +width+ bits being that row, leftmost =
          # the top bit).
          # +width+ is the digits' shared width (the caller checked all ten match) and
          # the cell is on-screen, so the walk needs no clipping.
          #
          # Called once per font, to build the ONE shared routine each screen mode's
          # digit calls reach with a BL rather than a copy of this loop apiece (see
          # Drawing#emit_digit_routines) — the digit itself already sits in r0 when
          # this runs, left there by whichever call evaluated it before branching in.
          #
          # The block is called with :hold once — after the glyph pointer is set up, to
          # load any register the plot keeps for the whole glyph — and with :plot for
          # each lit pixel, when r5 (row) and r4 (column) are live. Registers held
          # across the loop: r4 column, r5 row, r6 the glyph's row pointer, r7 the
          # current row byte; r0–r3 are per-pixel scratch and the plot owns r8 up.
          def emit_digit_glyph_loop(font_name, font, width)
            table = ensure_digit_table(font_name, font)
            top_bit = 1 << (width - 1)

            @emitter.emit_load_data_address(1, table) # r1 = the glyph table's ROM address
            @emitter.emit(ASM.load_immediate(2, font.height))
            @emitter.emit(ASM.mul(3, 0, 2))          # r3 = digit * height (its row offset)
            @emitter.emit(ASM.add_reg(6, 1, 3))      # r6 = &glyph[digit], row 0
            yield :hold                              # the plot loads its per-glyph register(s)
            @emitter.emit(ASM.load_immediate(5, 0))  # r5 = row = 0

            row_loop = @emitter.gensym
            @emitter.place_label(row_loop)
            @emitter.emit(ASM.ldrb_offset(7, 6, 0))  # r7 = this row's byte
            @emitter.emit(ASM.load_immediate(4, 0))  # r4 = col = 0

            col_loop = @emitter.gensym
            @emitter.place_label(col_loop)
            next_col = @emitter.gensym
            @emitter.emit(ASM.tst_imm(7, top_bit))   # is the leftmost remaining column lit?
            @emitter.emit_branch(:bcond, next_col, cond: :eq)
            yield :plot                              # yes: stamp it
            @emitter.place_label(next_col)
            @emitter.emit(ASM.lsl_imm(7, 7, 1))      # shift the next column into the top bit
            @emitter.emit(ASM.add_imm(4, 4, 1))
            @emitter.emit(ASM.cmp_imm(4, width))
            @emitter.emit_branch(:bcond, col_loop, cond: :lt)

            @emitter.emit(ASM.add_imm(6, 6, 1))      # advance to the next row's byte
            @emitter.emit(ASM.add_imm(5, 5, 1))
            @emitter.emit(ASM.cmp_imm(5, font.height))
            @emitter.emit_branch(:bcond, row_loop, cond: :lt)
          end

          # The width the ten digit glyphs share, if the data-driven loop can render
          # them: they must all exist, agree on a width, and be no wider than a byte
          # (so a row is one ldrb). Otherwise nil — a font with missing, ragged, or
          # oversized digits falls back to the per-digit fan-out, which reads each
          # glyph's own width. Fixed-width fonts always qualify; a proportional font
          # does when its figures are tabular.
          def uniform_digit_width(font)
            widths = (0..9).map { |d| font.glyph_width(d.to_s) }
            width = widths.first
            width if width && width <= 8 && widths.all?(width)
          end

          # True when the whole width×height digit cell at (x, y) fits on-screen, so
          # the data-driven loop can skip per-pixel clipping.
          def digit_cell_on_screen?(x, y, width, height)
            x >= 0 && y >= 0 && (x + width) <= SCREEN_WIDTH && (y + height) <= SCREEN_HEIGHT
          end

          private

          # Embed a font's ten digit glyphs as a ROM blob once, returning its blob
          # name. Laid out as glyph 0's +height+ row bytes, then glyph 1's, and so on,
          # so digit d begins at d*height. A digit the font happens to lack contributes
          # blank rows (it simply draws nothing), matching the fan-out's skip.
          def ensure_digit_table(name, font)
            blob = :"__digits_#{name}"
            unless @emitter.data_blobs.key?(blob)
              bytes = (0..9).flat_map { |d| font.glyph(d.to_s) || Array.new(font.height, 0) }
              @emitter.data_blobs[blob] = bytes.pack("C*")
            end
            blob
          end
        end
      end
    end
  end
end
