# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      # Lowers an IR program to a Game Boy Advance ROM.
      #
      # This is the GBA backend: it walks the IR tree and emits ARM7TDMI machine
      # code — the CPU the GBA runs — targeting the console's actual hardware: its
      # memory map (IWRAM for variables, VRAM for the screen), its memory-mapped
      # I/O registers (the display-control register, the DMA registers, the key
      # register), and its cartridge layout. The output is a ROM that boots on a
      # GBA (or an emulator); it would mean nothing to any other ARM device.
      #
      # How the "two passes" work. Emitting jumps is the hard part: a branch to a
      # block further down the program can't know its target address until that
      # block has been emitted (a *forward reference*). Rather than compute jump
      # distances by hand, we do it in two passes:
      #
      #   1. Walk the tree once, emitting real machine code into a buffer. Every
      #      point a jump might target gets a named *label* recorded at its byte
      #      position, and every jump is written as a 4-byte placeholder that
      #      remembers which label it wants.
      #   2. Resolve: now that every label's position is known, rewrite each
      #      placeholder as a real branch to its label.
      #
      # This works cleanly because only branches depend on addresses, and a branch
      # is always 4 bytes no matter how far it jumps — so emitting the placeholder
      # never changes any later position. Everything else (loading a number,
      # writing a pixel) has a fixed, value-determined size we emit immediately.
      #
      # Register conventions (no allocator yet — that's a later refinement). Between
      # statements the only live state lives in memory (variables in IWRAM, pixels
      # in VRAM); registers are all scratch, so each statement is free to reuse
      # them:
      #   * r0  — the value / expression accumulator
      #   * r1  — a temporary, and the address register for I/O writes
      #   * r2, r3 — scratch for computing a pixel's VRAM address at run time
      #   * r12 — address scratch when loading/storing a variable
      #   * the CPU stack holds intermediate values inside a nested expression
      class GBA
        include RubyGBA::Constants

        class LoweringError < StandardError; end

        # Friendly display-mode names → the display-control register value. Only
        # the direct-color bitmap mode is lowered here; other modes are their own
        # work. (This mirrors the DSL's names.)
        DISPLAY_MODES = { bitmap: MODE_3 | BG2_ENABLE }.freeze

        # Button name → its bit in the key register. The key register is
        # active-low: a 0 bit means the button is down.
        BUTTON_BIT = {
          a: KEY_A, b: KEY_B, select: KEY_SELECT, start: KEY_START,
          right: KEY_RIGHT, left: KEY_LEFT, up: KEY_UP, down: KEY_DOWN,
          r: KEY_R, l: KEY_L,
        }.freeze

        # Hidden variables for edge-detected input. Each holds the set of buttons
        # that were down as of a frame — this frame and the previous one — stored
        # active-high (a 1 bit means the button is down). `pressed` is "down now,
        # up last frame" = CUR_KEYS AND NOT PREV_KEYS. They're snapshotted once per
        # vblank so every check within a frame compares against the same previous
        # frame, exactly like the interpreter does.
        CUR_KEYS = :__cur_keys
        PREV_KEYS = :__prev_keys
        KEY_MASK = 0x3FF # the ten button bits

        ACC = 0   # accumulator register
        TMP = 1   # temporary / I/O address register
        ADDR = 12 # variable address scratch

        # Comparison operator → the ARM condition that is TRUE for it and the
        # condition under which it is FALSE (used to skip setting the result to 1).
        COMPARISONS = {
          :>  => %i[gt le], :<  => %i[lt ge],
          :>= => %i[ge lt], :<= => %i[le gt],
          :== => %i[eq ne], :!= => %i[ne eq],
        }.freeze

        attr_reader :code, :labels, :func_ranges

        def initialize
          @code = +"".b          # emitted machine code; byte 0 is where execution starts
          @labels = {}           # label name -> byte offset within @code
          @fixups = []           # branch placeholders to resolve once labels are known
          @vars = {}             # variable name -> IWRAM address
          @next_var = IWRAM_START
          @funcs = {}            # func name -> its IR node (emitted after the main body)
          @func_ranges = {}      # func name -> byte span in @code (for dump_func)
          @defined_sounds = {}   # name -> musical params (from define_sound)
          @songs = {}            # name -> :song node (from song)
          @data_blobs = {}       # name -> bytes (embedded data, appended after code)
          @data_positions = {}   # name -> byte offset of its blob within @code
          @bitmaps = {}          # name -> { width:, height: } (a blob that has a shape)
          @label_seq = 0
          @uses_pressed = false  # whether the program reads edge-detected input
        end

        # Lower a program to finished GBA machine code: run the emit pass and
        # resolve the jumps, then return the raw code bytes. Packaging them into a
        # cartridge — header, entry branch, checksum, padding — is ROM.assemble's
        # job; this method knows only how to compile the IR, not how a ROM is laid
        # out.
        def lower(program)
          collect_definitions(program)
          @uses_pressed = program.walk.any? { |node| node.kind == :pressed }
          emit_input_init if @uses_pressed
          program.children.each { |stmt| emit_statement(stmt) }
          emit_functions
          emit_data_region
          resolve_fixups
          @code
        end

        private

        # Register every definition in the tree up front — funcs, named sound
        # effects, and songs — so a later reference can reach one defined earlier
        # or later (a forward reference). Func bodies are emitted after the main
        # code, never inline, so the main flow doesn't run into them; sounds and
        # songs are pure data with nothing to emit on their own.
        def collect_definitions(program)
          program.walk do |node|
            case node.kind
            when :func
              @funcs[node[:name]] = node
            when :define_sound
              @defined_sounds[node[:name]] = {
                frequency: node[:frequency], duty: node[:duty],
                decay: node[:decay], volume: node[:volume]
              }
            when :song
              @songs[node[:name]] = node
            when :data
              @data_blobs[node[:name]] = node[:bytes]
            when :bitmap
              @bitmaps[node[:name]] = { width: node[:width], height: node[:height],
                                        transparent: node[:transparent], pixels: node[:pixels] }
              # An opaque bitmap streams from ROM via DMA, so embed its pixels. A
              # transparent one is drawn pixel-by-pixel with its colors baked into
              # the code (letting transparent pixels be skipped), so it needs no
              # ROM copy.
              @data_blobs[node[:name]] = node[:pixels] unless node[:transparent]
            end
          end
        end

        # --- emit helpers -------------------------------------------------------

        def emit(bytes)
          @code << bytes
        end

        # The current byte position — the program counter of the emit pass.
        def pos
          @code.bytesize
        end

        def place_label(name)
          @labels[name] = pos
        end

        def gensym
          "L#{@label_seq += 1}"
        end

        # Emit a 4-byte branch placeholder now and remember to resolve it against
        # +target+ later. kind is :b (unconditional), :bcond (conditional), or
        # :bl (call). The real branch is written in resolve_fixups.
        def emit_branch(kind, target, cond: nil)
          @fixups << { pos: pos, kind: kind, cond: cond, target: target }
          emit(ASM.nop)
        end

        # Second pass: every label and data-blob position is known now, so patch
        # each placeholder — a branch to a label, or a load of a blob's address.
        def resolve_fixups
          @fixups.each do |fix|
            fix[:kind] == :data_addr ? resolve_data_address(fix) : resolve_branch(fix)
          end
        end

        # Rewrite a branch placeholder as a real branch. The word offset is
        # (target - here)/4; ASM folds in the pipeline adjustment.
        def resolve_branch(fix)
          target = @labels.fetch(fix[:target]) do
            raise LoweringError, "unresolved jump to #{fix[:target].inspect}"
          end
          word_offset = (target - fix[:pos]) / 4
          encoded =
            case fix[:kind]
            when :b then ASM.branch(word_offset)
            when :bcond then ASM.branch_cond(fix[:cond], word_offset)
            when :bl then ASM.branch_link(word_offset)
            end
          @code[fix[:pos], 4] = encoded
        end

        # Patch a data-address load with the blob's run-time address. The blob
        # sits at +position+ within @code, and ROM.assemble drops @code into the
        # cartridge right after the header, so its address is the cartridge base
        # plus the header plus that position.
        def resolve_data_address(fix)
          position = @data_positions.fetch(fix[:target]) do
            raise LoweringError, "reference to undefined data #{fix[:target].inspect}"
          end
          address = ROM_START + RubyGBA::ROM::ENTRY_OFFSET + position
          @code[fix[:pos], 16] = ASM.load_immediate_fixed(fix[:reg], address)
        end

        # Lay the embedded blobs out after all the code, remembering where each
        # landed so resolve_data_address can turn a name into an address. Data
        # after the code means the main flow never runs into it.
        def emit_data_region
          @data_blobs.each do |name, bytes|
            @data_positions[name] = pos
            emit(bytes)
          end
        end

        # Load the run-time address of a named blob into +reg+. The address isn't
        # known until the data region is placed, so emit a fixed-size placeholder
        # and record a fixup to patch in the real address. Consumers (a blit's DMA
        # source, a sequencer's cursor) build on this.
        def emit_load_data_address(reg, name)
          @fixups << { pos: pos, kind: :data_addr, reg: reg, target: name }
          emit(ASM.load_immediate_fixed(reg, 0))
        end

        # --- statements ---------------------------------------------------------

        def emit_statement(node)
          case node.kind
          when :func then nil # emitted separately, after the main body
          when :set then emit_set(node)
          when :add then emit_accumulate(node, :add_reg)
          when :sub then emit_accumulate(node, :sub_reg)
          when :copy then emit_copy(node)
          when :negate then emit_negate(node)
          when :abs then emit_conditional_negate(node[:var], skip_when: :ge)
          when :negate_abs then emit_conditional_negate(node[:var], skip_when: :le)
          when :clamp then emit_clamp(node)
          when :if then emit_if(node)
          when :loop then emit_loop(node)
          when :call then emit_branch(:bl, func_label(node[:target]))
          when :case then emit_case(node)
          when :raw then emit(node[:bytes]) # escape hatch: pre-assembled bytes, verbatim
          when :halt then emit(ASM.loop_forever)
          when :wait_vblank then emit_wait_vblank
          when :display then emit_display(node)
          when :pixel then emit_pixel(node)
          when :fill_rect then emit_fill_rect(node)
          when :clear_screen then emit_clear_screen(node)
          when :dma_fill_rect then emit_dma_fill_rect(node)
          when :draw_rect_at then emit_draw_rect_at(node)
          when :draw_text then emit_draw_text(node)
          when :blit then emit_blit(node)
          when :enable_sound then emit_enable_sound
          when :define_sound, :song, :data, :bitmap then nil # definitions: collected, nothing to emit
          when :beep then emit_beep(node)
          when :play_song then emit_play_song(node)
          when :stop_music then emit_stop_music
          else
            raise LoweringError, "the GBA backend cannot lower #{node.kind.inspect} yet"
          end
        end

        def emit_set(node)
          eval_value(node[:value])
          store_var(ACC, node[:var])
        end

        # add/sub: new value = var (op) operand. Evaluate the operand into the
        # accumulator, load the variable alongside it, combine, store back.
        def emit_accumulate(node, op)
          eval_value(node[:operand])       # r0 = operand
          load_var(TMP, node[:var])        # r1 = current value
          emit(ASM.send(op, ACC, TMP, ACC)) # r0 = r1 (op) r0
          store_var(ACC, node[:var])
        end

        def emit_copy(node)
          load_var(ACC, node[:src])
          store_var(ACC, node[:dest])
        end

        def emit_negate(node)
          load_var(ACC, node[:var])
          emit(ASM.rsb_imm(ACC, ACC, 0))   # r0 = 0 - r0
          store_var(ACC, node[:var])
        end

        # Negate a variable only when it sits on one side of zero — the shared
        # shape of abs (|v|: negate when < 0, so skip when >= 0) and negate_abs
        # (-|v|: negate when > 0, so skip when <= 0). Compare to zero, jump over
        # the negate when the value is already on the wanted side.
        def emit_conditional_negate(var, skip_when:)
          load_var(ACC, var)
          emit(ASM.cmp_imm(ACC, 0))
          done = gensym
          emit_branch(:bcond, done, cond: skip_when)
          emit(ASM.rsb_imm(ACC, ACC, 0))
          place_label(done)
          store_var(ACC, var)
        end

        # Clamp a variable into [min, max] with two compare-and-maybe-replace steps.
        def emit_clamp(node)
          load_var(ACC, node[:var])

          below = gensym
          emit(ASM.load_immediate(TMP, node[:min]))
          emit(ASM.cmp_reg(ACC, TMP))                 # var - min
          emit_branch(:bcond, below, cond: :ge)       # var >= min? leave it
          emit(ASM.mov_reg(ACC, TMP))                 # else clamp up to min
          place_label(below)

          above = gensym
          emit(ASM.load_immediate(TMP, node[:max]))
          emit(ASM.cmp_reg(ACC, TMP))                 # var - max
          emit_branch(:bcond, above, cond: :le)       # var <= max? leave it
          emit(ASM.mov_reg(ACC, TMP))                 # else clamp down to max
          place_label(above)

          store_var(ACC, node[:var])
        end

        # if: run the then-body when the condition is non-zero. With no else, a
        # false condition jumps past the body. With an else, a false condition
        # jumps to the else-body, and the then-body jumps over it to the end.
        def emit_if(node)
          eval_value(node[:cond])
          emit(ASM.cmp_imm(ACC, 0))
          else_node = node[:else]

          if else_node
            else_label = gensym
            end_label = gensym
            emit_branch(:bcond, else_label, cond: :eq) # false => run the else
            node.children.each { |stmt| emit_statement(stmt) }
            emit_branch(:b, end_label)                 # then done => skip the else
            place_label(else_label)
            else_node.children.each { |stmt| emit_statement(stmt) }
            place_label(end_label)
          else
            skip = gensym
            emit_branch(:bcond, skip, cond: :eq) # zero => condition false => skip
            node.children.each { |stmt| emit_statement(stmt) }
            place_label(skip)
          end
        end

        # loop: an endless repeat of the body — a jump back to the top. A `halt`
        # (or the step budget, on the interpreter) is what ends it.
        def emit_loop(node)
          top = gensym
          place_label(top)
          node.children.each { |stmt| emit_statement(stmt) }
          emit_branch(:b, top)
        end

        # Func bodies live after the main code. A leading endless loop guards
        # against the main flow running off its end into the first body. Each func
        # saves the return address and restores it as the program counter.
        def emit_functions
          return if @funcs.empty?

          emit(ASM.loop_forever) # fall-through guard
          @funcs.each do |name, fnode|
            start = pos
            place_label(func_label(name))
            emit(ASM.push(14))                          # push {lr}
            fnode.children.each { |stmt| emit_statement(stmt) }
            emit(ASM.pop(15))                           # pop {pc}  (return)
            @func_ranges[name] = (start...pos)          # byte span, for dump_func
          end
        end

        def func_label(name)
          "func_#{name}"
        end

        # Multi-way dispatch lowers to one "if the variable equals this value, call
        # that scene" per clause — reusing the ordinary if/compare/call path, so
        # each comparison reloads the variable itself and no register survives a
        # scene call (the old case_var r10-reload workaround isn't needed).
        def emit_case(node)
          node[:clauses].each do |value, target|
            test = Build.binop(:==, Build.var_ref(node[:var]), Build.int(value))
            emit_statement(Build.if_(test, Build.call(target)))
          end
        end

        # --- hardware / drawing -------------------------------------------------

        # Turn the screen on by writing the chosen mode to the display-control
        # register. Until this runs the screen stays black.
        def emit_display(node)
          mode = node[:mode]
          value = mode.is_a?(Integer) ? mode : DISPLAY_MODES.fetch(mode) do
            raise LoweringError, "the GBA backend cannot lower display mode #{mode.inspect} yet"
          end
          write_reg16(REG_DISPCNT, value)
        end

        # Plot one pixel. With constant coordinates the VRAM address is known now,
        # so it's a single store. With a computed coordinate (e.g. a variable) the
        # address is built at run time from the evaluated x/y.
        def emit_pixel(node)
          color = Color.resolve(node[:color])
          xi = const_int(node[:x])
          yi = const_int(node[:y])

          if xi && yi
            return unless in_bounds?(xi, yi) # off-screen: clip, like the framebuffer

            write_reg16(VRAM_START + ((yi * SCREEN_WIDTH) + xi) * 2, color)
          else
            eval_value(node[:y])            # r0 = y
            emit(ASM.push(ACC))
            eval_value(node[:x])            # r0 = x
            emit(ASM.pop(TMP))              # r1 = y
            emit(ASM.load_immediate(2, SCREEN_WIDTH))
            emit(ASM.mul(3, TMP, 2))        # r3 = y * width
            emit(ASM.add_reg(3, 3, ACC))    # r3 = y*width + x
            emit(ASM.lsl_imm(3, 3, 1))      # r3 = offset * 2 bytes
            emit(ASM.load_immediate(2, VRAM_START))
            emit(ASM.add_reg(3, 2, 3))      # r3 = VRAM address
            emit(ASM.load_immediate(ACC, color))
            emit(ASM.store_halfword(ACC, 3))
          end
        end

        # Fill a rectangle of constant size. Load the color once, then write each
        # on-screen pixel (off-screen pixels are clipped).
        def emit_fill_rect(node)
          x, y, w, h = constant_ints!(node, :x, :y, :w, :h)
          color = Color.resolve(node[:color])
          emit(ASM.load_immediate(ACC, color))
          h.times do |dy|
            row = y + dy
            next unless (0...SCREEN_HEIGHT).cover?(row)

            w.times do |dx|
              col = x + dx
              next unless (0...SCREEN_WIDTH).cover?(col)

              emit(ASM.load_immediate(TMP, VRAM_START + ((row * SCREEN_WIDTH) + col) * 2))
              emit(ASM.store_halfword(ACC, TMP))
            end
          end
        end

        # Clear the whole screen with one DMA transfer: repeat a packed two-pixel
        # word across VRAM. The DMA engine copies far faster than a pixel loop.
        def emit_clear_screen(node)
          color = Color.resolve(node[:color])
          word = (color << 16) | color
          count = SCREEN_WIDTH * SCREEN_HEIGHT / 2
          scratch = var_addr(:_dma_scratch)

          store_word_immediate(word, scratch)                 # hold the fill word in IWRAM
          store_word_immediate(scratch, REG_DMA3SAD)          # source: the fixed word
          store_word_immediate(VRAM_START, REG_DMA3DAD)       # destination: the screen
          store_word_immediate(dma_fill_control(count), REG_DMA3CNT) # kick off the transfer
        end

        # A rectangle at a fixed position and size, filled fast with per-row DMA:
        # each row is one block transfer of a repeated two-pixel word. Rows off the
        # top/bottom of the screen are skipped.
        def emit_dma_fill_rect(node)
          x, y, w, h = constant_ints!(node, :x, :y, :w, :h)
          even_width!(w, :dma_fill_rect)
          scratch = hold_fill_word(node[:color])
          control = dma_fill_control(w / 2)

          h.times do |dy|
            row = y + dy
            next unless (0...SCREEN_HEIGHT).cover?(row)

            row_addr = VRAM_START + ((row * SCREEN_WIDTH) + x) * 2
            fire_dma_fill(scratch, row_addr, control)
          end
        end

        # A rectangle whose position is computed at run time (x/y may be
        # variables), its size a constant. Same per-row DMA fill as
        # dma_fill_rect, but each row's destination address is built from the
        # live x/y instead of known up front. r2/r3 hold x/y across the loop;
        # r4/r5 are address scratch. (No run-time bounds clip yet — the caller is
        # expected to keep it on-screen, as pong does by clamping.)
        def emit_draw_rect_at(node)
          w, h = constant_ints!(node, :w, :h)
          even_width!(w, :draw_rect_at)
          scratch = hold_fill_word(node[:color])
          control = dma_fill_control(w / 2)

          x_reg = 2
          y_reg = 3
          eval_value(node[:x])
          emit(ASM.mov_reg(x_reg, ACC))
          eval_value(node[:y])
          emit(ASM.mov_reg(y_reg, ACC))

          h.times do |dy|
            # r4 = VRAM_START + ((y + dy) * width + x) * 2
            if dy.zero?
              emit(ASM.mov_reg(4, y_reg))
            else
              emit(ASM.add_imm(4, y_reg, dy))
            end
            emit(ASM.load_immediate(5, SCREEN_WIDTH))
            emit(ASM.mul(4, 5, 4))           # r4 = width * (y + dy)
            emit(ASM.add_reg(4, 4, x_reg))   # + x
            emit(ASM.lsl_imm(4, 4, 1))       # * 2 bytes per pixel
            emit(ASM.load_immediate(5, VRAM_START))
            emit(ASM.add_reg(4, 4, 5))       # + VRAM base

            store_word_immediate(scratch, REG_DMA3SAD)
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(4, TMP))            # destination is the computed address
            store_word_immediate(control, REG_DMA3CNT)
          end
        end

        # Draw a defined bitmap at a runtime (x, y). An opaque bitmap streams from
        # ROM by DMA; one with transparency is drawn pixel-by-pixel so its
        # transparent pixels can be skipped. (No run-time clip either way — the
        # caller keeps it on-screen, as pong does by clamping.)
        def emit_blit(node)
          bmp = @bitmaps.fetch(node[:name]) do
            raise LoweringError, "blit of undefined image #{node[:name].inspect}"
          end
          bmp[:transparent] ? emit_blit_transparent(node, bmp) : emit_blit_opaque(node, bmp)
        end

        # Opaque bitmap: one 16-bit DMA per row, source in the cartridge (source
        # and destination both increment, unlike a fill), so each row's pixels
        # stream straight from ROM into VRAM. r2/r3 hold x/y and r6 the bitmap base
        # across the loop; r4/r5 are the destination and source addresses.
        def emit_blit_opaque(node, bmp)
          width = bmp[:width]
          control = width | DMA_ENABLE # 16-bit, source and destination increment

          x_reg = 2
          y_reg = 3
          base_reg = 6
          eval_value(node[:x])
          emit(ASM.mov_reg(x_reg, ACC))
          eval_value(node[:y])
          emit(ASM.mov_reg(y_reg, ACC))
          emit_load_data_address(base_reg, node[:name]) # r6 = bitmap address in the cartridge

          bmp[:height].times do |row|
            # r4 = VRAM_START + ((y + row) * screen_width + x) * 2
            row.zero? ? emit(ASM.mov_reg(4, y_reg)) : emit(ASM.add_imm(4, y_reg, row))
            emit(ASM.load_immediate(5, SCREEN_WIDTH))
            emit(ASM.mul(4, 5, 4))
            emit(ASM.add_reg(4, 4, x_reg))
            emit(ASM.lsl_imm(4, 4, 1))
            emit(ASM.load_immediate(5, VRAM_START))
            emit(ASM.add_reg(4, 4, 5))

            # r5 = bitmap base + this row's byte offset into the pixels
            row_offset = row * width * 2
            if row.zero?
              emit(ASM.mov_reg(5, base_reg))
            else
              emit(ASM.load_immediate(5, row_offset))
              emit(ASM.add_reg(5, base_reg, 5))
            end

            emit(ASM.load_immediate(TMP, REG_DMA3SAD))
            emit(ASM.str(5, TMP))                       # source: this row in ROM
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(4, TMP))                       # destination: this row in VRAM
            store_word_immediate(control, REG_DMA3CNT)  # kick off the row copy
          end
        end

        # Transparent bitmap: the art is known at build time, so unroll it. Emit a
        # store only for each NON-transparent pixel — with its color baked in, at
        # the run-time-computed destination — and simply skip transparent ones, so
        # the background shows through. r2/r3 hold x/y; r4 is the destination and
        # r5 a scratch.
        def emit_blit_transparent(node, bmp)
          width = bmp[:width]
          colors = bmp[:pixels].unpack("v*")

          x_reg = 2
          y_reg = 3
          eval_value(node[:x])
          emit(ASM.mov_reg(x_reg, ACC))
          eval_value(node[:y])
          emit(ASM.mov_reg(y_reg, ACC))

          bmp[:height].times do |row|
            width.times do |col|
              color = colors[(row * width) + col]
              next if color == bmp[:transparent] # skip transparent pixels at build time

              # r4 = VRAM_START + ((y + row) * screen_width + x + col) * 2
              row.zero? ? emit(ASM.mov_reg(4, y_reg)) : emit(ASM.add_imm(4, y_reg, row))
              emit(ASM.load_immediate(5, SCREEN_WIDTH))
              emit(ASM.mul(4, 5, 4))
              emit(ASM.add_reg(4, 4, x_reg))
              emit(ASM.add_imm(4, 4, col)) unless col.zero?
              emit(ASM.lsl_imm(4, 4, 1))
              emit(ASM.load_immediate(5, VRAM_START))
              emit(ASM.add_reg(4, 4, 5))
              emit(ASM.load_immediate(5, color))
              emit(ASM.store_halfword(5, 4))
            end
          end
        end

        # Draw a line of text with the built-in bitmap font. The color loads once,
        # then every set pixel of every glyph is a single halfword store at its
        # fixed VRAM address; off-screen pixels are dropped. Positions are constant.
        def emit_draw_text(node)
          x, y = constant_ints!(node, :x, :y)
          emit(ASM.load_immediate(ACC, Color.resolve(node[:color])))

          Font.each_pixel(node[:text]) do |dx, dy|
            px = x + dx
            py = y + dy
            next unless in_bounds?(px, py)

            emit(ASM.load_immediate(TMP, VRAM_START + ((py * SCREEN_WIDTH) + px) * 2))
            emit(ASM.store_halfword(ACC, TMP))
          end
        end

        # Stash a solid fill color as a packed two-pixel word in IWRAM and return
        # its address — the fixed source a DMA fill re-reads for every pixel.
        def hold_fill_word(color)
          value = Color.resolve(color)
          word = (value << 16) | value
          scratch = var_addr(:_dma_scratch)
          store_word_immediate(word, scratch)
          scratch
        end

        # The DMA3 control word for a source-fixed 32-bit fill of +count+ words.
        def dma_fill_control(count)
          count | DMA_ENABLE | DMA_32BIT | DMA_SRC_FIXED
        end

        # Point DMA3 at (source, destination), then kick it off — one filled row.
        def fire_dma_fill(source_addr, dest_addr, control)
          store_word_immediate(source_addr, REG_DMA3SAD)
          store_word_immediate(dest_addr, REG_DMA3DAD)
          store_word_immediate(control, REG_DMA3CNT)
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

        # --- audio ---------------------------------------------------------------
        #
        # Each op resolves to a short list of sound-register writes via the shared
        # Sound module, so the ROM and the interpreter play the same thing. A write
        # is just "put this 16-bit value at this register address."

        def emit_writes(writes)
          writes.each { |address, value| write_reg16(address, value) }
        end

        # Power on the audio hardware.
        def emit_enable_sound
          emit_writes(Sound::Registers.enable)
        end

        # A one-off sound effect on channel 2. Resolve the beep to concrete musical
        # values (a defined-sound name, a preset, or a raw frequency), then write
        # the channel-2 registers.
        def emit_beep(node)
          effect = Sound.resolve_effect(node[:tone], duty: node[:duty], decay: node[:decay],
                                                     volume: node[:volume], defined: @defined_sounds)
          emit_writes(Sound::Registers.channel2(**effect))
        end

        # Silence the music channel.
        def emit_stop_music
          emit_writes(Sound::Registers.stop_music)
        end

        # Advance a song by one frame. A per-song counter in IWRAM ticks up; each
        # note whose frame matches the counter triggers, and once the counter
        # reaches the song's length it wraps to 0 so the tune loops. This unrolls
        # the whole score into frame comparisons — the same sequencer the legacy
        # emitter builds, so migrated songs sound identical.
        def emit_play_song(node)
          song = @songs.fetch(node[:name]) do
            raise LoweringError, "play_song for undefined song #{node[:name].inspect}"
          end
          counter = :"_music_frame_#{node[:name]}"

          load_var(ACC, counter)             # counter += 1
          emit(ASM.add_imm(ACC, ACC, 1))
          store_var(ACC, counter)

          song[:events].each do |frame, frequency|
            skip = gensym
            load_var(ACC, counter)
            compare_acc_to(frame)
            emit_branch(:bcond, skip, cond: :ne) # counter != this note's frame? skip it
            emit_writes(Sound::Registers.channel1_note(frequency: frequency,
                                                       duty: song[:duty], volume: song[:volume]))
            place_label(skip)
          end

          wrap = gensym                        # loop: if counter >= length, reset to 0
          load_var(ACC, counter)
          compare_acc_to(song[:total_frames])
          emit_branch(:bcond, wrap, cond: :lt)
          emit(ASM.load_immediate(ACC, 0))
          store_var(ACC, counter)
          place_label(wrap)
        end

        # Compare the accumulator to a constant. The constant loads into a temp
        # first, so any 32-bit value works (the immediate compare form only encodes
        # small constants, and frame counts can exceed that).
        def compare_acc_to(value)
          emit(ASM.load_immediate(TMP, value))
          emit(ASM.cmp_reg(ACC, TMP))
        end

        # Busy-wait for the vertical blank — the brief pause between drawn frames,
        # the safe moment to change what's on screen. We poll the scanline counter:
        # first let any current blank finish, then wait for the next to begin. The
        # two back-jumps are a fixed two instructions, so they need no label.
        def emit_wait_vblank
          emit(ASM.load_immediate(ACC, REG_VCOUNT))
          emit(ASM.load_halfword(TMP, ACC))
          emit(ASM.cmp_imm(TMP, 160))
          emit(ASM.branch_cond(:ge, -2))  # still past line 160: keep waiting
          emit(ASM.load_halfword(TMP, ACC))
          emit(ASM.cmp_imm(TMP, 160))
          emit(ASM.branch_cond(:lt, -2))  # not yet at line 160: keep waiting

          # A new frame begins now, so refresh the input snapshot: last frame's
          # keys become "previous", and we latch this frame's keys as "current".
          snapshot_keys if @uses_pressed
        end

        # --- value expressions --------------------------------------------------

        # Emit code that leaves the value of +node+ in the accumulator (r0).
        def eval_value(node)
          case node.kind
          when :int then emit(ASM.load_immediate(ACC, Int32.wrap(node[:value])))
          when :var_ref then load_var(ACC, node[:name])
          when :neg
            eval_value(node[:operand])
            emit(ASM.rsb_imm(ACC, ACC, 0))
          when :binop then eval_binop(node)
          when :held then eval_held(node[:button])
          when :pressed then eval_pressed(node[:button])
          when :data_byte then eval_data_byte(node)
          else
            raise LoweringError, "the GBA backend cannot evaluate #{node.kind.inspect}"
          end
        end

        # Read one byte of a named blob: point the address register at the blob,
        # then load the byte at its fixed index into the accumulator.
        def eval_data_byte(node)
          emit_load_data_address(ADDR, node[:name])
          emit(ASM.ldrb_offset(ACC, ADDR, node[:index]))
        end

        # Evaluate lhs and rhs, holding lhs on the stack while rhs is computed, then
        # combine. Using the stack for the intermediate keeps arbitrarily nested
        # expressions correct without a register allocator.
        def eval_binop(node)
          eval_value(node[:lhs])
          emit(ASM.push(ACC))
          eval_value(node[:rhs])
          emit(ASM.pop(TMP))             # r1 = lhs, r0 = rhs

          op = node[:op]
          case op
          when :+ then emit(ASM.add_reg(ACC, TMP, ACC))
          when :- then emit(ASM.sub_reg(ACC, TMP, ACC))
          when :* then emit(ASM.mul(ACC, TMP, ACC))
          # Condition composition: both sides are already 0/1, so a bitwise
          # and/or gives the combined 0/1 the branch tests for.
          when :and then emit(ASM.and_reg(ACC, TMP, ACC))
          when :or then emit(ASM.orr_reg(ACC, TMP, ACC))
          when :/ then emit_division
          else emit_comparison(op)
          end
        end

        # Divide through the BIOS Div routine — the ARM7TDMI has no divide
        # instruction, so a division traps into the BIOS. It wants the numerator
        # in r0 and the denominator in r1; after the binop setup r1 already holds
        # lhs (numerator) and r0 holds rhs (denominator), so swap them (via r2)
        # and trap. The quotient comes back in r0, our accumulator — right where
        # an expression's result belongs. (r1 gets the remainder, r3 is clobbered;
        # neither survives a statement here, so that's fine.)
        def emit_division
          emit(ASM.mov_reg(2, ACC))   # r2 = denominator (rhs)
          emit(ASM.mov_reg(ACC, TMP)) # r0 = numerator (lhs)
          emit(ASM.mov_reg(TMP, 2))   # r1 = denominator
          emit(ASM.swi(0x06 << 16))   # BIOS Div: r0 = r0 / r1
        end

        # A comparison yields 1 or 0. Compare, default the result to 0, and set it
        # to 1 only when the comparison holds.
        def emit_comparison(op)
          _true_cond, false_cond = COMPARISONS.fetch(op) do
            raise LoweringError, "unknown operator #{op.inspect}"
          end
          emit(ASM.cmp_reg(TMP, ACC))          # lhs - rhs
          done = gensym
          emit(ASM.load_immediate(ACC, 0))
          emit_branch(:bcond, done, cond: false_cond)
          emit(ASM.load_immediate(ACC, 1))
          place_label(done)
        end

        # `held` reads the key register and tests the button's bit. The register is
        # active-low, so the bit reads 0 while the button is down: TST sets the zero
        # flag exactly then, and we turn that into 1 (held) or 0 (not).
        def eval_held(button)
          mask = BUTTON_BIT.fetch(button) do
            raise LoweringError, "unknown button #{button.inspect}"
          end
          emit(ASM.load_immediate(TMP, REG_KEYINPUT))
          emit(ASM.load_halfword(ACC, TMP))
          emit(ASM.tst_imm(ACC, mask))         # zero flag set => button down
          done = gensym
          emit(ASM.load_immediate(ACC, 0))
          emit_branch(:bcond, done, cond: :ne) # bit not zero => not held => leave 0
          emit(ASM.load_immediate(ACC, 1))
          place_label(done)
        end

        # `pressed` is the down-edge: down this frame, up last frame. The snapshots
        # are active-high, so newly-pressed buttons = CUR_KEYS AND NOT PREV_KEYS;
        # test the button's bit in that.
        def eval_pressed(button)
          mask = BUTTON_BIT.fetch(button) do
            raise LoweringError, "unknown button #{button.inspect}"
          end
          load_var(ACC, CUR_KEYS)
          load_var(TMP, PREV_KEYS)
          emit(ASM.mvn_reg(TMP, TMP))          # ~prev
          emit(ASM.and_reg(ACC, ACC, TMP))     # cur & ~prev = buttons newly down
          emit(ASM.tst_imm(ACC, mask))
          done = gensym
          emit(ASM.load_immediate(ACC, 0))
          emit_branch(:bcond, done, cond: :eq) # bit zero => not a fresh press => 0
          emit(ASM.load_immediate(ACC, 1))
          place_label(done)
        end

        # Start both snapshots empty (no button pressed) before the game runs.
        def emit_input_init
          emit(ASM.load_immediate(ACC, 0))
          store_var(ACC, CUR_KEYS)
          store_var(ACC, PREV_KEYS)
        end

        # Once per frame: shift this frame's "current" into "previous", then latch
        # the live key state as the new "current". The key register is active-low,
        # so invert it and keep the ten button bits to get an active-high set.
        def snapshot_keys
          load_var(ACC, CUR_KEYS)
          store_var(ACC, PREV_KEYS)              # previous = last frame's current
          emit(ASM.load_immediate(TMP, REG_KEYINPUT))
          emit(ASM.load_halfword(ACC, TMP))
          emit(ASM.mvn_reg(ACC, ACC))            # invert: 1 bit now means "down"
          emit(ASM.lsl_imm(ACC, ACC, 22))        # drop everything above the
          emit(ASM.lsr_imm(ACC, ACC, 22))        # ten button bits
          store_var(ACC, CUR_KEYS)               # current = this frame's keys
        end

        # --- variables & small emit primitives ----------------------------------

        # A variable is 4 bytes in IWRAM, addresses handed out on first mention.
        def var_addr(name)
          @vars[name] ||= begin
            address = @next_var
            @next_var += 4
            address
          end
        end

        def load_var(reg, name)
          emit(ASM.load_immediate(ADDR, var_addr(name)))
          emit(ASM.ldr(reg, ADDR))
        end

        def store_var(reg, name)
          emit(ASM.load_immediate(ADDR, var_addr(name)))
          emit(ASM.str(reg, ADDR))
        end

        # Write a 16-bit value to a memory-mapped register / VRAM halfword.
        def write_reg16(address, value)
          emit(ASM.load_immediate(ACC, value))
          emit(ASM.load_immediate(TMP, address))
          emit(ASM.store_halfword(ACC, TMP))
        end

        # Write a full 32-bit word to an address (used for the DMA registers).
        def store_word_immediate(value, address)
          emit(ASM.load_immediate(ACC, value))
          emit(ASM.load_immediate(TMP, address))
          emit(ASM.str(ACC, TMP))
        end

        # The integer value of a constant operand, or nil if it isn't a constant.
        def const_int(node)
          return Int32.wrap(node) if node.is_a?(Integer)
          return Int32.wrap(node[:value]) if node.is_a?(Node) && node.kind == :int

          nil
        end

        def constant_ints!(node, *keys)
          keys.map do |key|
            const_int(node[key]) ||
              raise(LoweringError,
                    "the GBA backend needs a constant #{key} for #{node.kind} " \
                    "(a computed one is the runtime-rect work, tracked separately)")
          end
        end

        def in_bounds?(x, y)
          (0...SCREEN_WIDTH).cover?(x) && (0...SCREEN_HEIGHT).cover?(y)
        end
      end
    end
  end
end
