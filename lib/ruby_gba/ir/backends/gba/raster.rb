# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Bending a background row by row — the lowering of `:scroll_rows`.
        #
        # HOW THE PICTURE IS BUILT. The console does not hold a finished picture anywhere.
        # It builds the screen one horizontal line at a time, top to bottom, and for every
        # single line it re-reads where each background layer is scrolled to. So the scroll
        # position is not one setting for the whole picture — it is a setting the display
        # asks for 160 times a frame, and nobody says the answer has to be the same each
        # time.
        #
        # That is the whole trick. Give line 40 an offset two pixels to the left and line
        # 41 two to the right, and the picture BENDS. Move the pattern down a little every
        # frame and the bend travels: water rippling, a reflection wobbling, hot air
        # shimmering over a desert. Nothing is redrawn, and the layer costs exactly what a
        # still one costs — the picture is made of the same tiles, just fetched from a
        # different place per line.
        #
        # HOW WE GET IN BETWEEN THE LINES. After the display finishes drawing a line it
        # pauses briefly before starting the next (the gap is there so the hardware can
        # fetch what it needs). Two different things can act in that gap, and which one a
        # bend gets is decided by its block — see {BendForm}.
        #
        # THE COPIER, where the block is one number. The console has four small copying
        # engines, and one of them can be told "at the end of every line, move one number
        # from here into that register". Point it at a table of 160 offsets and at the
        # layer's scroll register and it feeds the display by itself, with the CPU
        # untouched: the per-line cost is nothing at all. What is left is filling the table
        # once a frame, which is the program's own expression run 160 times in an ordinary
        # loop — and that is the whole of what a bend costs this way.
        #
        # An engine feeds one register, so a bending layer needs one of its own: three
        # layers, three tables, three engines, all filled in the same pass at the frame
        # boundary. Which engines there are to give out is {BendForm}'s answer.
        #
        # Two details make the table line up. The engine's first move happens at the end of
        # LINE 0, so what it moves is row 1's offset, and the table it walks starts one
        # entry in; row 0 is written straight to the register by the frame instead. And an
        # engine keeps walking forward, so at the frame boundary it has to be pointed back
        # at the top — which is done in the gap between frames, where it is idle (the
        # display raises no line-ends while it is not drawing).
        #
        # THE INTERRUPT, where the block does more. The display can raise an interrupt at
        # the start of that same gap: the handler works out where the NEXT line should sit
        # and writes the scroll register, and the display picks that up as it draws it.
        # This is the general answer — the handler is ordinary code with the whole program
        # in reach — and it is what a block that calls a routine or sets a variable gets.
        #
        # WHAT THE INTERRUPT COSTS. An interrupt per line is real work — the console stops
        # the game, saves registers, runs the handler, and resumes, 228 times a frame (the
        # display keeps counting lines past the bottom of the picture). Three things keep
        # it small. The handler is the FIRST thing the dispatcher checks, because it fires
        # far more often than anything else. It stops early on the lines below the picture,
        # where there is nothing to bend — about a third of them. And the dispatcher itself
        # is normally worth keeping in the console's quick memory, which the build works out
        # on its own (see Placement#IRQ_ROUTINE) and which measured a shade under half the
        # cost off. What is left is the part of an interrupt the console does itself, which
        # nothing we can do reaches.
        module Raster
          include Constants

          # The lines the picture is drawn on. The display counts on past the bottom of the
          # picture (through 227) while nothing is being drawn, so a line at or past this
          # has nothing to bend — except the very last one, which is where the top line of
          # the NEXT frame is set up.
          VISIBLE_LINES = 160
          LAST_LINE = 227

          # Which backgrounds bend, name -> its :scroll_rows node. Collected in the
          # definitions pass so whichever mechanism answers them can be set up at boot,
          # before any of the program's own code runs.
          def register_row_bends(program)
            program.walk.each do |node|
              @row_bends[node.name] = node if node.kind == :scroll_rows # last wins if repeated
            end
          end

          # Whether any bend is answered per line by an interrupt — which is what decides
          # whether the display is asked to announce its lines at all.
          def interrupts_rows?
            !@row_bends.empty? && !@copies_row_bends
          end

          def copies_row_bends?
            @copies_row_bends
          end

          # Where a bending background's rows are measured from: the layer's own scroll
          # position, so a background can scroll AND bend. Every scroll_by/scroll_to on a
          # background reads the same hidden variable, so any one of its scroll statements
          # names it; a background that never scrolls sits at 0.
          def row_bend_base(program, name)
            node = program.walk.find { |n| n.kind == :scroll_background && n.name == name }
            node ? node.x : Build.int(0)
          end

          def prepare_row_bends(program)
            @row_bends.each_key { |name| @row_bend_base[name] = row_bend_base(program, name) }
            @copies_row_bends = BendForm.copier?(program)
            return unless @copies_row_bends

            # One table AND one engine per bending layer. The table lives in the same quick
            # memory the variables do, and holds a row's offset per entry with one to spare:
            # the engine's last move of a frame reads one past the bottom of the picture, on
            # a line nothing is drawn on.
            engines = BendForm.engines(program)
            @row_bends.each_key.with_index do |name, i|
              @row_bend_table[name] = @next_var
              @row_bend_engine[name] = engines.fetch(i)
              @next_var += TABLE_BYTES
            end
          end

          # The table the copier walks: one 16-bit offset per row, and one spare (see
          # above), rounded up to a whole word so the next thing given room stays aligned.
          TABLE_ENTRIES = VISIBLE_LINES + 1
          TABLE_BYTES = ((TABLE_ENTRIES * 2) + 3) & ~3

          # The three registers of each engine a bend can ride, by engine number: where it
          # reads from, where it writes to, and what it is doing. Which engines are free to
          # be handed out, and in what order, is {BendForm}'s answer — the cost model asks it
          # too, so it cannot live here.
          COPIER_SAD = [REG_DMA0SAD, REG_DMA1SAD, REG_DMA2SAD].freeze
          COPIER_DAD = [REG_DMA0DAD, REG_DMA1DAD, REG_DMA2DAD].freeze
          COPIER_CNT = [REG_DMA0CNT, REG_DMA1CNT, REG_DMA2CNT].freeze

          # Move ONE 16-bit number at the end of every line the display draws, and keep
          # doing it: the destination stays put (it is a register, not a run of memory)
          # while the source walks forward through the table.
          COPIER_CONTROL = DMA_ENABLE | DMA_AT_HBLANK | DMA_REPEAT | DMA_DEST_FIXED | 1

          # Set the copier up once, at boot: the table starts flat (quick memory does not
          # come up as zeroes, and a table of leftovers would show as a scrambled first
          # frame), then the engine is aimed at the layer's scroll register and started.
          def emit_boot_row_bend_copiers
            scratch = var_addr(:_bend_clear)
            store_word_immediate(0, scratch)
            @row_bend_table.each do |name, base|
              store_word_immediate(scratch, REG_DMA3SAD) # one word of zeroes, read over and over
              store_word_immediate(base, REG_DMA3DAD)
              store_word_immediate(dma_fill_control(TABLE_BYTES / 4), REG_DMA3CNT)
              store_word_immediate(Drawing::BG_HOFS_REGS[bg_number(name)], COPIER_DAD[engine_for(name)])
            end
            emit_rearm_row_bend_copiers
          end

          # Point the engine back at the top of the table, in the gap between frames. It
          # walks forward as it feeds the display and there is no telling it to start over,
          # so this is how a table gets read again: stop it, aim it, start it.
          #
          # It aims one entry IN, because the engine's first move of a frame lands on row 1
          # — the end of line 0 is the first line-end there is. Row 0 is the frame's own to
          # write (see #emit_fill_row_bend_tables).
          def emit_rearm_row_bend_copiers
            @row_bend_table.each do |name, base|
              engine = engine_for(name)
              store_word_immediate(0, COPIER_CNT[engine])
              store_word_immediate(base + 2, COPIER_SAD[engine])
              store_word_immediate(COPIER_CONTROL, COPIER_CNT[engine])
            end
          end

          # Which engine feeds this layer, settled in #prepare_row_bends.
          def engine_for(name)
            @row_bend_engine.fetch(name)
          end

          # Work out where every row of every bending layer sits, into the table the copier
          # reads. Run once a frame, from the frame boundary — so the program's expression
          # is worked out 160 times here instead of once per line inside an interrupt.
          def emit_fill_row_bend_tables
            @row_bends.each_value { |node| emit_fill_row_bend_table(node) }
          end

          # One layer's table. The loop keeps its count in the block's own row variable,
          # which the block reads anyway: the expression in the block is free to reach a
          # routine or the console's divide, and either would land in whatever register a
          # count was being held in.
          def emit_fill_row_bend_table(node)
            base = @row_bend_table.fetch(node.name)
            top = gensym
            store_word_immediate(0, var_addr(node.row))
            place_label(top)
            eval_value(Build.binop(:+, node.offset, @row_bend_base[node.name])) # r0 = this row
            load_var(TMP, node.row)
            emit(ASM.lsl_imm(SPARE, TMP, 1))         # two bytes an entry
            emit(ASM.load_immediate(ADDR, base))
            emit(ASM.add_reg(ADDR, ADDR, SPARE))
            emit(ASM.store_halfword(ACC, ADDR))
            emit(ASM.add_imm(TMP, TMP, 1))
            store_var(TMP, node.row)
            emit(ASM.cmp_imm(TMP, VISIBLE_LINES))
            emit_branch(:bcond, top, cond: :lt)
            emit_write_first_row(node, base)
          end

          # Row 0 goes straight into the scroll register, because the copier's first move
          # of the frame is row 1's. It is written here, at the END of the frame's work,
          # for the same reason the table is filled here: a `scroll_by` in the frame writes
          # that register too, and whichever of the two goes last is what the top row shows.
          def emit_write_first_row(node, base)
            emit(ASM.load_immediate(ADDR, base))
            emit(ASM.load_halfword(ACC, ADDR))
            store_halfword_acc(Drawing::BG_HOFS_REGS[bg_number(node.name)])
          end

          # Which of the console's layers draws this background. Outside tile mode there is
          # none, and the scroll registers do nothing — the same harmless fallback a plain
          # scroll takes.
          def bg_number(name)
            @backgrounds[name]&.bg || 0
          end

          # The per-line handler, run from the interrupt dispatcher.
          #
          # The line the display is ABOUT to draw is one past the one it just finished, so
          # the offset written here is the next line's. On the display's last line that
          # wraps to the top line of the next frame, which is what keeps the topmost row of
          # the picture bent like all the others.
          def emit_row_bend_handler
            done = gensym
            emit(ASM.load_immediate(TMP, REG_VCOUNT))
            emit(ASM.load_halfword(ACC, TMP))              # r0 = the line just finished
            emit(ASM.cmp_imm(ACC, LAST_LINE))
            emit(ASM.mov_imm_cond(:eq, ACC, 0))            # the last line sets up the next frame's first
            emit(ASM.add_imm_cond(:ne, ACC, ACC, 1))       # ...otherwise the next line down
            emit(ASM.cmp_imm(ACC, VISIBLE_LINES))
            emit_branch(:bcond, done, cond: :ge)           # below the picture: nothing to bend
            # Every bend is told the line first, because working one offset out needs the
            # accumulator the line number is sitting in.
            @row_bends.each_value { |node| store_var(ACC, node.row) }
            @row_bends.each_value { |node| emit_one_row_bend(node) }
            place_label(done)
          end

          # One background's offset for this line: run whatever the program put in the
          # block, work the offset out, add the layer's own scroll, and write it. The write
          # is what the display reads as it draws the line.
          def emit_one_row_bend(node)
            node.children.each { |child| emit_statement(child) }
            eval_value(Build.binop(:+, node.offset, @row_bend_base[node.name]))
            store_halfword_acc(Drawing::BG_HOFS_REGS[bg_number(node.name)])
          end
        end
      end
    end
  end
end
