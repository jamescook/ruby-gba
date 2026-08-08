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
        # fetch what it needs). It can raise an interrupt at the start of that gap, which
        # is our chance: the handler works out where the NEXT line should sit and writes
        # the scroll register, and the display picks that up as it draws it.
        #
        # WHAT IT COSTS. An interrupt per line is real work — the console stops the game,
        # saves registers, runs the handler, and resumes, 228 times a frame (the display
        # keeps counting lines past the bottom of the picture). Two things keep it small.
        # The handler is the FIRST thing the dispatcher checks, because it fires far more
        # often than anything else. And it stops early on the lines below the picture,
        # where there is nothing to bend — about a third of them.
        module Raster
          include Constants

          # The lines the picture is drawn on. The display counts on past the bottom of the
          # picture (through 227) while nothing is being drawn, so a line at or past this
          # has nothing to bend — except the very last one, which is where the top line of
          # the NEXT frame is set up.
          VISIBLE_LINES = 160
          LAST_LINE = 227

          # Which backgrounds bend, name -> its :scroll_rows node. Collected in the
          # definitions pass so the interrupt can be armed at boot, before any of the
          # program's own code runs.
          def register_row_bends(program)
            program.walk.each do |node|
              @row_bends[node[:name]] = node if node.kind == :scroll_rows # last wins if repeated
            end
          end

          def bends_rows?
            !@row_bends.empty?
          end

          # Where a bending background's rows are measured from: the layer's own scroll
          # position, so a background can scroll AND bend. Every scroll_by/scroll_to on a
          # background reads the same hidden variable, so any one of its scroll statements
          # names it; a background that never scrolls sits at 0.
          def row_bend_base(program, name)
            node = program.walk.find { |n| n.kind == :scroll_background && n[:name] == name }
            node ? node[:x] : Build.int(0)
          end

          def prepare_row_bends(program)
            @row_bends.each_key { |name| @row_bend_base[name] = row_bend_base(program, name) }
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
            @row_bends.each_value { |node| store_var(ACC, node[:row]) }
            @row_bends.each_value { |node| emit_one_row_bend(node) }
            place_label(done)
          end

          # One background's offset for this line: run whatever the program put in the
          # block, work the offset out, add the layer's own scroll, and write it. The write
          # is what the display reads as it draws the line.
          def emit_one_row_bend(node)
            bg_num = (@backgrounds[node[:name]] || {})[:bg] || 0
            node.children.each { |child| emit_statement(child) }
            eval_value(Build.binop(:+, node[:offset], @row_bend_base[node[:name]]))
            store_halfword_acc(Drawing::BG_HOFS_REGS[bg_num])
          end
        end
      end
    end
  end
end
