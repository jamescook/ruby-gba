# frozen_string_literal: true

module VBlank
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
          include Console::Hardware

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
          # The multiplier is rounded DOWN, so its answer can land one row early. Where the walk
          # asks each row whether its pixel is see-through, that is the safe direction at the
          # near end of a stretch (a row too early draws nothing extra) and the unsafe one at the
          # far end, which is why that end takes a second spare row. Where it asks nothing, both
          # ends are stepped on to the exact row anyway (see #emit_exact_stretch_ends), and an
          # early guess only means a step more.
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

          # The last step a column worked out, and the strip height and picture height it was
          # worked out for (see #emit_column_step).
          LAST_STEP = :_column_last_step
          LAST_STEP_ROWS = :_column_last_step_rows
          LAST_STEP_PICTURE_HEIGHT = :_column_last_step_picture_height

          def initialize(emitter:, primitives:, lowering:, divide:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @divide = divide
            @stretched_columns = nil
          end

          # The pictures a stretched column draws, and where each of their columns holds
          # pixels — handed over once the program is known (see GBA#lower), since that is
          # what says which pictures those are.
          attr_writer :stretched_columns

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
          def emit_color_fill_word(color)
            value = Graphics::Color.resolve(color)
            word = (value << 16) | value
            scratch = @primitives.var_addr(Primitives::FILL_SCRATCH)
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
          def emit_dma_fill_row(source_addr, dest_addr, control)
            @primitives.emit_start_copy_engine(from: source_addr, to: dest_addr, control: control)
          end

          # Guard the fast block-fill's even-width assumption: it moves two pixels at
          # a time, so an odd width would drop the last column (and a width of 0 or 1
          # would ask DMA for a runaway transfer).
          def refuse_odd_width!(w, kind)
            return if w.positive? && w.even?

            raise LoweringError,
                  "#{kind} needs an even, positive width (got #{w}) — the fast " \
                  "block fill moves two pixels per step"
          end

          # What a picture's palette-number form is filed under, beside its colors.
          def indexed_blob(name) = :"#{name}#{INDEXED_SUFFIX}"

          # ...and the same numbers COLUMN BY COLUMN, for a picture a stretched column draws on
          # the tear-free screen. The walk goes down one column of the picture, so kept that way
          # the next row's number is the next byte; kept row by row it is a whole picture width
          # further on, and finding it is a multiply every row. The copy costs the cartridge the
          # picture's size once more, which is far cheaper than the multiplies.
          def column_blob(name) = :"#{name}#{COLUMNS_SUFFIX}"

          # A picture's palette numbers, row by row, turned into the same numbers column by
          # column.
          def self.numbers_by_column(numbers, width, height)
            (0...width).flat_map { |x| (0...height).map { |y| numbers.getbyte((y * width) + x) } }.pack("C*")
          end

          # The number a line of text is painted with, into +reg+: a colour on the direct
          # screen, a slot of the colour table on the tear-free one — the block turns a
          # colour into whichever of those this screen wants.
          #
          # ONE COLOUR IS ONE LOAD, exactly as it always was. Two are the test worked out
          # first and then one load or the other, so the words that follow are painted once
          # whichever colour they come out — a handful of instructions, where painting the
          # words under the test and again under its opposite was every pixel of them twice.
          def emit_text_color(node, reg)
            return @emitter.emit_number(reg, yield(node.color)) unless node.picked

            @lowering.value(node.showing) # r0 = the test: not zero picks the second colour
            first = @emitter.gensym
            done = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, first, cond: :eq)
            @emitter.emit_number(reg, yield(node.picked))
            @emitter.emit_branch(:b, done)
            @emitter.place_label(first)
            @emitter.emit_number(reg, yield(node.color))
            @emitter.place_label(done)
          end

          # Everything a column needs before its first row: how many rows, how far down
          # the picture each one moves, where it starts on screen, and where its pixels
          # come from.
          #
          # +blob+ and +pixel_bytes+ differ by screen: the direct-color one reads the
          # picture's colors, two bytes each, row by row, and the tear-free one reads the
          # same picture as palette numbers, one byte each, column by column (+by_column+,
          # which is only ever one byte a pixel).
          def emit_column_setup(node, bmp, done, blob: node.name, pixel_bytes: 2, by_column: false)
            @lowering.value(node.height)
            @emitter.emit(ASM.mov_reg(COLUMN_ROWS, ACC))
            @emitter.emit(ASM.cmp_imm(COLUMN_ROWS, 0))
            @emitter.emit_branch(:bcond, done, cond: :le) # a column of no height draws nothing

            emit_column_step(bmp)

            @lowering.value(node.x)
            @emitter.emit(ASM.mov_reg(COLUMN_X, ACC))
            @lowering.value(node.top)
            @emitter.emit(ASM.mov_reg(COLUMN_Y, ACC))

            # The picture's column: its first pixel is `slice` pixels along its first
            # row, and its rows are a whole picture width apart — or, in a copy kept column
            # by column, `slice` whole columns along, its rows one after another.
            @lowering.value(node.slice)
            emit_clamp_to(ACC, bmp.width - 1)
            emit_column_runs_pointer(node.name) # ...and where THIS column holds its pixels
            if by_column
              @emitter.emit_number(TMP, bmp.height)
              @emitter.emit(ASM.mul(ACC, ACC, TMP))
            elsif pixel_bytes == 2
              @emitter.emit(ASM.lsl_imm(ACC, ACC, 1))
            end
            @emitter.emit_load_data_address(COLUMN_SRC, blob)
            @emitter.emit(ASM.add_reg(COLUMN_SRC, COLUMN_SRC, ACC))
          end

          # HOW FAR DOWN THE PICTURE EACH SCREEN ROW MOVES: (picture height << 16) / height, by
          # the shared divide routine — which takes the numerator in TMP and the divisor in
          # ACC, and hands the answer back in ACC.
          #
          # A DIVIDE IS A CALL AND A LOOP, AND MOST STRIPS DO NOT NEED ONE. A thing on screen is
          # many strips of one height, and a wall's strips change height a row at a time, so
          # the strip before this one has very often just worked out this very step. The last
          # step is kept with the two numbers it came from, and a strip whose numbers match takes
          # it as it stands: a handful of loads and compares in place of the call, and the same
          # step to the bit, since it is the answer the same divide gave. A strip whose numbers
          # do not match pays those, the divide, and three stores to keep its answer — a few
          # instructions on top of a routine that costs many times that.
          def emit_column_step(bmp)
            return emit_divide_for_column_step(bmp) unless @stretched_columns.reuses_last_step?

            divide = @emitter.gensym
            known = @emitter.gensym
            @primitives.load_var(TMP, LAST_STEP_ROWS)
            @emitter.emit(ASM.cmp_reg(TMP, COLUMN_ROWS))
            @emitter.emit_branch(:bcond, divide, cond: :ne)
            @primitives.load_var(TMP, LAST_STEP_PICTURE_HEIGHT)
            @emitter.emit_number(ACC, bmp.height)
            @emitter.emit(ASM.cmp_reg(TMP, ACC))
            @emitter.emit_branch(:bcond, divide, cond: :ne)
            @primitives.load_var(COLUMN_STEP, LAST_STEP)
            @emitter.emit_branch(:b, known)

            @emitter.place_label(divide)
            emit_divide_for_column_step(bmp)
            @primitives.store_var(COLUMN_STEP, LAST_STEP)
            @primitives.store_var(COLUMN_ROWS, LAST_STEP_ROWS)
            @emitter.emit_number(ACC, bmp.height)
            @primitives.store_var(ACC, LAST_STEP_PICTURE_HEIGHT)
            @emitter.place_label(known)
          end

          def emit_divide_for_column_step(bmp)
            @emitter.emit_number(TMP, bmp.height << COLUMN_FIXED)
            @emitter.emit(ASM.mov_reg(ACC, COLUMN_ROWS))
            @divide.emit_call_divide_routine
            @emitter.emit(ASM.mov_reg(COLUMN_STEP, ACC))
          end

          # NO STEP IS KNOWN AT POWER-ON. The memory holds whatever it held, which could pass for
          # a height and a step that were never worked out. A height of nothing never reaches
          # the step (a column of no height draws nothing), so it is the one that cannot match.
          def emit_clear_remembered_column_step
            return unless @stretched_columns.reuses_last_step?

            @emitter.emit_number(ACC, 0)
            @primitives.store_var(ACC, LAST_STEP_ROWS)
          end

          # Does every row the walk reaches in this picture hold a pixel? Then no row needs
          # asking whether it is see-through (see #emit_exact_stretch_ends).
          def column_rows_all_pixels?(name) = @stretched_columns.stretches_are_all_pixels?(name)

          # This column's list of the stretches of rows that hold pixels. ACC holds the
          # picture's column coming in and still holds it going out.
          def emit_column_runs_pointer(name)
            return unless @stretched_columns.skips_empty_rows?(name)

            @emitter.emit(ASM.lsl_imm(SPARE, ACC, 1)) # a halfword a column
            @emitter.emit_load_data_address(TMP, @stretched_columns.runs_start_blob(name))
            @emitter.emit(ASM.add_reg(TMP, TMP, SPARE))
            @emitter.emit(ASM.load_halfword(SPARE, TMP))
            @emitter.emit_load_data_address(COLUMN_RUNS, @stretched_columns.runs_blob(name))
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
          # THE PICTURE CANNOT CHANGE, however the arithmetic rounds. Where every row of
          # every stretch is a pixel, each end is stepped on to exactly the screen row the
          # walk shows it at (see #emit_exact_stretch_ends), so the walk meets only pixels and
          # asks no row whether it is see-through. Where one is not (see
          # ColumnStretches#stretches_are_all_pixels?), the walk asks each row, so a stretch a
          # row too wide costs one row and draws nothing extra; and it is never too NARROW,
          # because its first row is rounded down and its last is rounded up with a row to
          # spare. See {ColumnDivide} for how each end is rounded and why the far one sometimes
          # wants a second spare row.
          def emit_column_runs(name, bmp, bail)
            unless @stretched_columns.skips_empty_rows?(name)
              @emitter.emit_number(SPARE, 0)
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
            @emitter.emit_number(ACC, divide.magic) if divide.by_multiply?
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
            # Where the ends are stepped on to the exact row, each is rounded UP rather than
            # down (a picture row's worth less one is added before dividing): still never past
            # the answer, and now usually on it, so the stepping seldom goes round.
            exact = column_rows_all_pixels?(name)
            round_up = exact && bmp.height > 1 ? bmp.height - 1 : 0
            @emitter.emit(ASM.mul(TMP, ACC, COLUMN_ROWS))
            @emitter.emit(ASM.add_imm(TMP, TMP, round_up)) if round_up.positive?
            @emitter.emit(ASM.lsl_imm(COLUMN_POS, ACC, COLUMN_FIXED)) if exact
            @emitter.emit(ASM.add_imm(HIGH, HIGH, 1))
            @emitter.emit(ASM.lsl_imm(COLUMN_DEST, HIGH, COLUMN_FIXED)) if exact
            @emitter.emit(ASM.mul(COLUMN_Y, HIGH, COLUMN_ROWS))
            @emitter.emit(ASM.add_imm(COLUMN_Y, COLUMN_Y, round_up)) if round_up.positive?
            @emitter.emit(ASM.ldr_offset(ACC, STACK, at[ACC])) if divide.by_multiply?
            emit_column_divide(divide, from: TMP, into: SPARE, spill: HIGH) # the first screen row...
            emit_column_divide(divide, from: COLUMN_Y, into: HIGH, spill: TMP) # ...and one past the last
            @emitter.emit(ASM.ldr_offset(COLUMN_Y, STACK, at[COLUMN_Y]))
            if exact
              emit_exact_stretch_ends
            else
              @emitter.emit(ASM.add_imm(HIGH, HIGH, divide.spare_rows)) # ...with a row to spare
            end

            after = @emitter.gensym
            yield(after)
            @emitter.place_label(after)
            @emitter.emit_branch(:b, top)
            @emitter.place_label(finish)
            @emitter.emit(ASM.pop(*held))
          end

          # A STRETCH'S ENDS LANDED EXACTLY, so the walk between them meets only pixels.
          #
          # The walk shows, at screen row r, picture row (r × step) >> 16 — so a stretch from
          # picture row a to picture row b begins at the first r whose r × step reaches a << 16,
          # and ends before the first r whose r × step reaches (b + 1) << 16. Dividing would give
          # those straight off; the divide above gives a guess instead, and this steps each guess
          # on a row at a time until it sits on the answer.
          #
          # NEITHER GUESS IS EVER TOO LATE, so neither has to step back. A guess is the picture
          # row times the height over the picture's height, rounded up; the true row is that
          # same picture row over a step that was itself rounded down, which can only come out
          # later. How much later grows with how tall the strip is drawn: on a strip a few times
          # the picture's height it is nothing, or a row; on one drawn a hundred times taller and
          # more, many rows. So neither end steps past the bottom of the area drawing may land
          # in, and the first starts no higher than its top — the rows outside are cut off
          # anyway (see #emit_clip_column_rows), so what the walk draws is the same, and the
          # stepping costs at most the rows that show however tall the strip is. That also
          # ends it on a strip so tall that its step is nothing at all, where no number of rows
          # would ever reach the next picture row.
          #
          # COLUMN_Y holds the strip's top coming in. The stretch's first picture row and the row
          # after its last wait in COLUMN_POS and COLUMN_DEST, shifted up to the walk's fixed
          # point: both are free until the stretch's rows are settled, since the walk sets its
          # position and its destination only after that. TMP and ACC are used up.
          def emit_exact_stretch_ends
            low_enough = @emitter.gensym
            @emitter.emit(ASM.rsb_imm(TMP, COLUMN_Y, clip_top)) # the first row drawing may land on
            @emitter.emit(ASM.cmp_reg(SPARE, TMP))
            @emitter.emit_branch(:bcond, low_enough, cond: :ge)
            @emitter.emit(ASM.mov_reg(SPARE, TMP))
            @emitter.place_label(low_enough)

            @emitter.emit(ASM.rsb_imm(ACC, COLUMN_Y, clip_bottom)) # one past the last row it may land on
            emit_step_row_on_to(SPARE, COLUMN_POS, limit: ACC)
            emit_step_row_on_to(HIGH, COLUMN_DEST, limit: ACC)
          end

          # Move the screen row in +row+ on until (row × step) reaches +target+, or until it
          # reaches +limit+. A row already there costs a multiply, a compare and a branch.
          def emit_step_row_on_to(row, target, limit:)
            again = @emitter.gensym
            found = @emitter.gensym
            @emitter.emit(ASM.mul(TMP, row, COLUMN_STEP))
            @emitter.place_label(again)
            @emitter.emit(ASM.cmp_reg(TMP, target))
            @emitter.emit_branch(:bcond, found, cond: :ge)
            @emitter.emit(ASM.cmp_reg(row, limit))
            @emitter.emit_branch(:bcond, found, cond: :ge)
            @emitter.emit(ASM.add_reg(TMP, TMP, COLUMN_STEP))
            @emitter.emit(ASM.add_imm(row, row, 1))
            @emitter.emit_branch(:b, again)
            @emitter.place_label(found)
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
            @emitter.emit_number(TMP, clip_bottom)
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
            @emitter.emit_number(reg, 0)
            @emitter.place_label(keep)

            under = @emitter.gensym
            @emitter.emit_number(TMP, top)
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
          # digit renders. The ten glyphs live in ROM as rows of bits (glyph d at
          # d*height rows, the low +width+ bits of each being that row, leftmost = the
          # top bit). A row is a byte when the font is no wider than eight pixels, and a
          # whole word when it is wider: one load either way, so a game's own big
          # figures cost a table four times as long rather than an instruction a pixel.
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
            row_size = digit_row_size(width)

            @emitter.emit_load_data_address(1, table) # r1 = the glyph table's ROM address
            @emitter.emit_number(2, font.height * row_size)
            @emitter.emit(ASM.mul(3, 0, 2))          # r3 = digit * a glyph's bytes (its offset)
            @emitter.emit(ASM.add_reg(6, 1, 3))      # r6 = &glyph[digit], row 0
            yield :hold                              # the plot loads its per-glyph register(s)
            @emitter.emit_number(5, 0)  # r5 = row = 0

            row_loop = @emitter.gensym
            @emitter.place_label(row_loop)
            # r7 = this row's bits
            @emitter.emit(row_size == 1 ? ASM.ldrb_offset(7, 6, 0) : ASM.ldr_offset(7, 6, 0))
            @emitter.emit_number(4, 0)  # r4 = col = 0

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

            @emitter.emit(ASM.add_imm(6, 6, row_size)) # advance to the next row
            @emitter.emit(ASM.add_imm(5, 5, 1))
            @emitter.emit(ASM.cmp_imm(5, font.height))
            @emitter.emit_branch(:bcond, row_loop, cond: :lt)
          end

          # The width the ten digit glyphs share, if the data-driven loop can render
          # them: they must all exist, agree on a width, and be no wider than a word
          # (so a row is one load). Otherwise nil — a font with missing, ragged, or
          # oversized digits falls back to the per-digit fan-out, which reads each
          # glyph's own width. Fixed-width fonts always qualify; a proportional font
          # does when its figures are tabular.
          def uniform_digit_width(font)
            widths = (0..9).map { |d| font.glyph_width(d.to_s) }
            width = widths.first
            width if width && width <= 32 && widths.all?(width)
          end

          # How many bytes one row of a digit glyph takes in the table: a byte for a font
          # up to eight pixels wide, a word for anything wider.
          def digit_row_size(width) = width <= 8 ? 1 : 4

          # True when the whole width×height digit cell at (x, y) fits on-screen, so
          # the data-driven loop can skip per-pixel clipping.
          def digit_cell_on_screen?(x, y, width, height)
            x >= 0 && y >= 0 && (x + width) <= SCREEN_WIDTH && (y + height) <= SCREEN_HEIGHT
          end

          private

          # Embed a font's ten digit glyphs as a ROM blob once, returning its blob
          # name. Laid out as glyph 0's +height+ rows, then glyph 1's, and so on, so
          # digit d begins at d*height rows — each row a byte or a word, as
          # #digit_row_size says. A digit the font happens to lack contributes blank
          # rows (it simply draws nothing), matching the fan-out's skip. Every blob
          # starts on a word boundary, so a table of words is read whole.
          def ensure_digit_table(name, font)
            blob = :"__digits_#{name}"
            unless @emitter.data_blobs.key?(blob)
              rows = (0..9).flat_map { |d| font.glyph(d.to_s) || Array.new(font.height, 0) }
              wide = digit_row_size(font.glyph_width("0")) == 4
              @emitter.data_blobs[blob] = rows.pack(wide ? "V*" : "C*")
            end
            blob
          end
        end
      end
    end
  end
end
