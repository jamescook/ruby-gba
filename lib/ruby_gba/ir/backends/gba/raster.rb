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
        # WHERE THE ROWS ARE WORKED OUT. In the gap between frames, all 160 of them, into a
        # table — the program's own expression run 160 times in an ordinary loop. That is
        # the whole of what a bend costs, and it is the same either way the table is then
        # fed to the display.
        #
        # THE GAP IS WHERE IT BELONGS, not a convenience. Everything else about a frame is
        # settled there — where the sprites are, where each background is scrolled to — so
        # a bend worked out there shows the frame that moved it at the same moment they do.
        # Work the rows out while the picture is being drawn instead, which is the obvious
        # thing to try, and the bend answers the frame's body one frame before the sprite
        # standing on it does; and the display is meanwhile reading the same rows we are
        # writing, so a long frame tears its own wave part way down.
        #
        # HOW WE GET IN BETWEEN THE LINES. After the display finishes drawing a line it
        # pauses briefly before starting the next (the gap is there so the hardware can
        # fetch what it needs). Two different things can move a row's number out of the
        # table in that pause, and which one a bend gets is {BendForm}'s answer.
        #
        # THE COPIER is the cheap one. The console has four small copying engines, and one
        # of them can be told "at the end of every line, move one number from here into
        # that register". Point it at the table and at the layer's scroll register and it
        # feeds the display by itself, with the CPU untouched: the per-line cost is nothing
        # at all.
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
        # THE INTERRUPT is what answers when there is no engine left. The display can raise
        # an interrupt at the start of that same pause: the handler reads the NEXT line's
        # number out of the table and writes the scroll register, and the display picks
        # that up as it draws it. Same numbers, same picture — only the CPU carries them.
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
        #
        # A PROGRAM WITH NO FRAME has no gap to fill a table in, and then the handler runs
        # the block itself, line by line, which is what this did everywhere before there
        # was a table. Nothing is paced in such a program, so there is nothing for the bend
        # to be a frame out of step with.
        #
        # Owns the five maps/flags that answer "which layers bend, and how": which nodes
        # bend (@row_bends), each one's own scroll to measure from (@row_bend_base), its
        # table of worked-out offsets when one is latched ahead of the frame
        # (@row_bend_table), which copying engine feeds that table (@row_bend_engine), and
        # whether a copier is doing the feeding at all (@copies_row_bends). `backgrounds:`
        # is a live reference to the backend's own name -> layer map — it is filled after
        # this object is built (tiled backgrounds are prepared first), so only bg_number,
        # called at emission time, ever actually reads it.
        class Raster
          include Constants

          # The lines the picture is drawn on. The display counts on past the bottom of the
          # picture (through 227) while nothing is being drawn, so a line at or past this
          # has nothing to bend — except the very last one, which is where the top line of
          # the NEXT frame is set up.
          VISIBLE_LINES = 160
          LAST_LINE = 227

          attr_reader :row_bends # name -> :scroll_rows node (Drawing reads this to skip a bending layer's own scroll)

          def initialize(emitter:, primitives:, memory:, lowering:, backgrounds:, framebuffer:)
            @emitter = emitter
            @primitives = primitives
            @memory = memory
            @lowering = lowering
            @backgrounds = backgrounds
            # dma_fill_control lives on Framebuffer, alongside the other shared clip/fill
            # machinery a bend's boot table also needs.
            @framebuffer = framebuffer
            @row_bends = {}         # name -> :scroll_rows node giving each of that layer's rows its own offset
            @row_bend_base = {}     # name -> the layer's own scroll, which a row's offset is measured from
            @row_bend_table = {}    # name -> where its table of row offsets sits, worked out each frame
            @row_bend_engine = {}   # name -> which copying engine feeds it from that table
            @copies_row_bends = false # are those tables fed by a copying engine rather than per-line interrupts?
          end

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

          # Whether the rows are worked out ahead of the frame into a table. True for every
          # bend in a paced program, whichever moves the numbers afterwards; false only where
          # there is no frame to work them out in, and the handler runs the block per line.
          def latches_row_bends?
            !@row_bend_table.empty?
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
            return unless BendForm.latched?(program)

            # A table per bending layer, and an engine each for as many as there are engines
            # to give. The table lives in the same quick memory the variables do, and holds a
            # row's offset per entry with one to spare: the engine's last move of a frame
            # reads one past the bottom of the picture, on a line nothing is drawn on.
            engines = @copies_row_bends ? BendForm.engines(program) : []
            @row_bends.each_key.with_index do |name, i|
              @row_bend_table[name] = @memory.alloc(TABLE_BYTES)
              @row_bend_engine[name] = engines[i] if @copies_row_bends
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

          # Set the tables up once, at boot. Each starts flat, because quick memory does not
          # come up as zeroes and a table of leftovers would show as a scrambled first frame.
          # Then, where an engine is feeding one, it is aimed at the layer's scroll register
          # and started.
          def emit_boot_row_bends
            scratch = @primitives.var_addr(:_bend_clear)
            @primitives.store_word_immediate(0, scratch)
            @row_bend_table.each do |name, base|
              @primitives.store_word_immediate(scratch, REG_DMA3SAD) # one word of zeroes, read over and over
              @primitives.store_word_immediate(base, REG_DMA3DAD)
              @primitives.store_word_immediate(@framebuffer.dma_fill_control(TABLE_BYTES / 4), REG_DMA3CNT)
              next unless copies_row_bends?

              @primitives.store_word_immediate(Drawing::BG_HOFS_REGS[bg_number(name)], COPIER_DAD[engine_for(name)])
            end
            emit_rearm_row_bend_copiers if copies_row_bends?
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
              @primitives.store_word_immediate(0, COPIER_CNT[engine])
              @primitives.store_word_immediate(base + 2, COPIER_SAD[engine])
              @primitives.store_word_immediate(COPIER_CONTROL, COPIER_CNT[engine])
            end
          end

          # Which engine feeds this layer, settled in #prepare_row_bends.
          def engine_for(name)
            @row_bend_engine.fetch(name)
          end

          # Work out where every row of every bending layer sits, into the table the display
          # is fed from. Run once a frame, from the frame boundary — so the program's block
          # is worked out 160 times here instead of once per line while the picture is drawn.
          #
          # EVERY LAYER'S ROW 0 GOES FIRST, before any layer's remaining rows, and that
          # ordering is load-bearing. Row 0 is the one that is written straight into the
          # display's register, and it has to be there before the picture starts. The rest
          # is a table nobody reads until the line it belongs to, so it may take as long as
          # it likes — a program bending four layers from the cartridge spends longer on
          # this than the gap between frames is, and if a register write were at the end of
          # that it would land on a line being drawn and put a seam across the picture.
          def emit_fill_row_bend_tables
            @row_bends.each_value { |node| emit_first_row_bend(node) }
            @row_bends.each_value { |node| emit_fill_row_bend_table(node) }
          end

          # One layer's row 0: into the table, and straight into the scroll register, since
          # whatever feeds the rest only starts moving numbers at the end of line 0. Nothing
          # else writes that register for a bending layer — a `scroll_by` on one leaves it
          # alone, because the layer's scroll is already in every entry of the table (see
          # Drawing#emit_scroll_background).
          def emit_first_row_bend(node)
            @primitives.store_word_immediate(0, @primitives.var_addr(node.row))
            emit_row_offset(node)
            @emitter.emit(ASM.load_immediate(ADDR, @row_bend_table.fetch(node.name)))
            @emitter.emit(ASM.store_halfword(ACC, ADDR))
            @primitives.store_halfword_acc(Drawing::BG_HOFS_REGS[bg_number(node.name)])
          end

          # ...and the rest of that layer's rows, 1 up. The loop keeps its count in the
          # block's own row variable, which the block reads anyway: the block is free to
          # reach a routine or the console's divide, and either would land in whatever
          # register a count was being held in.
          def emit_fill_row_bend_table(node)
            base = @row_bend_table.fetch(node.name)
            top = @emitter.gensym
            @primitives.store_word_immediate(1, @primitives.var_addr(node.row))
            @emitter.place_label(top)
            emit_row_offset(node)
            @primitives.load_var(TMP, node.row)
            @emitter.emit(ASM.lsl_imm(SPARE, TMP, 1))         # two bytes an entry
            @emitter.emit(ASM.load_immediate(ADDR, base))
            @emitter.emit(ASM.add_reg(ADDR, ADDR, SPARE))
            @emitter.emit(ASM.store_halfword(ACC, ADDR))
            @emitter.emit(ASM.add_imm(TMP, TMP, 1))
            @primitives.store_var(TMP, node.row)
            @emitter.emit(ASM.cmp_imm(TMP, VISIBLE_LINES))
            @emitter.emit_branch(:bcond, top, cond: :lt)
          end

          # Where the row now in the block's row variable sits: whatever else the block
          # does, then its offset, measured from the layer's own scroll. Left in r0.
          def emit_row_offset(node)
            node.children.each { |child| @lowering.statement(child) }
            @lowering.value(Build.binop(:+, node.offset, @row_bend_base[node.name]))
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
            done = @emitter.gensym
            @emitter.emit(ASM.load_immediate(TMP, REG_VCOUNT))
            @emitter.emit(ASM.load_halfword(ACC, TMP))         # r0 = the line just finished
            @emitter.emit(ASM.cmp_imm(ACC, LAST_LINE))
            @emitter.emit(ASM.mov_imm_cond(:eq, ACC, 0))       # the last line sets up the next frame's first
            @emitter.emit(ASM.add_imm_cond(:ne, ACC, ACC, 1))  # ...otherwise the next line down
            @emitter.emit(ASM.cmp_imm(ACC, VISIBLE_LINES))
            @emitter.emit_branch(:bcond, done, cond: :ge)      # below the picture: nothing to bend
            if latches_row_bends?
              @emitter.emit(ASM.lsl_imm(SPARE, ACC, 1))        # two bytes an entry, held for them all
              @row_bends.each_value { |node| emit_read_row_from_table(node) }
            else
              # Every bend is told the line first, because working one offset out needs the
              # accumulator the line number is sitting in.
              @row_bends.each_value { |node| @primitives.store_var(ACC, node.row) }
              @row_bends.each_value { |node| emit_one_row_bend(node) }
            end
            @emitter.place_label(done)
          end

          # One background's row, out of the table and into the scroll register. The display
          # reads that register as it draws the line, so this is the whole of the handler's
          # work — the number was worked out in the gap between frames.
          def emit_read_row_from_table(node)
            @emitter.emit(ASM.load_immediate(ADDR, @row_bend_table.fetch(node.name)))
            @emitter.emit(ASM.add_reg(ADDR, ADDR, SPARE))
            @emitter.emit(ASM.load_halfword(ACC, ADDR))
            @primitives.store_halfword_acc(Drawing::BG_HOFS_REGS[bg_number(node.name)])
          end

          # One background's offset for this line, worked out here and now: run whatever the
          # program put in the block, work the offset out, add the layer's own scroll, and
          # write it. This is what a program with no frame gets, having had no gap to work
          # its rows out in ahead of time.
          def emit_one_row_bend(node)
            node.children.each { |child| @lowering.statement(child) }
            @lowering.value(Build.binop(:+, node.offset, @row_bend_base[node.name]))
            @primitives.store_halfword_acc(Drawing::BG_HOFS_REGS[bg_number(node.name)])
          end
        end
      end
    end
  end
end
