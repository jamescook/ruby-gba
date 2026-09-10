# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Direct-color (Mode 3) drawing, and the screen-mode/page management around it.
        #
        # What the prepare passes in gba.rb decide about a program — which images,
        # objects, and backgrounds it has, the shared palette, the picture, the mode
        # facts — arrives as one record, `layout`, handed over through `layout=` once
        # those passes finish (the same shape Functions#modes= is set in: none of it
        # exists yet when this object is built). Clip/column/digit-glyph work shared
        # with the tear-free screen lives in {Framebuffer}; the tear-free screen's own
        # drawing lives in {Buffered}, an explicit collaborator here rather than a bare
        # cross-file call.
        #
        # Ten statement kinds fork on which screen is live —
        # `return @buffered.emit_x_buffered(node) if @lowering.mode == :buffered` — and
        # that fork stays written out here rather than moving into the Lowering's
        # dispatch table, which would otherwise have to pick one of two handlers per
        # kind instead of one.
        class Drawing
          include Constants

          def initialize(emitter:, primitives:, lowering:, divide:, framebuffer:, raster:, palette_tint:,
                          layer_blend:, buffered:, backing_info:, fade_targets:, effect_line:,
                          call_cold_routine:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @divide = divide
            @framebuffer = framebuffer
            @raster = raster
            @palette_tint = palette_tint
            @layer_blend = layer_blend
            @buffered = buffered
            @backing_info = backing_info
            @fade_targets = fade_targets
            @effect_line = effect_line
            @call_cold_routine = call_cold_routine
            @layout = nil
          end

          attr_writer :layout

          # The prepare-pass results this file reads, bundled into one record and handed
          # over through #layout= once every pass that decides them has run.
          # +map_cells+ is each background's grid size and +map_entries+ what to write into
          # a cell to show one of its tiles — the two things a run-time tile change needs
          # and nothing else does.
          Layout = Data.define(:bitmaps, :objects, :window_twins, :backgrounds, :bg_shared, :palette,
                                :indexed_bitmaps, :run_bitmaps, :blob_codecs, :blob_raw_bytes, :picture,
                                :modes, :tiled, :has_objects, :obj_palette_blob, :obj_palette_units,
                                :default_mode, :any_buffered, :mixed_display, :manage_modes, :func_mode,
                                :map_cells, :map_entries, :scene_art)

          # Fill the area itself, which is what clearing means when only part of the picture may
          # be painted: a row-at-a-time block fill over exactly those edges. It does not go
          # through the rectangle verb because that one holds authors to an even width, and an
          # area's width is whatever the author said.
          def emit_fill_area(color)
            scratch = @framebuffer.hold_fill_word(color)
            control = @framebuffer.fill_control_for_column(@framebuffer.clip_left,
                                                            @framebuffer.clip_right - @framebuffer.clip_left)
            (@framebuffer.clip_top...@framebuffer.clip_bottom).each do |row|
              @framebuffer.fire_dma_fill(scratch, VRAM_START + ((row * SCREEN_WIDTH) + @framebuffer.clip_left) * 2,
                                         control)
            end
          end

          # Turn the screen on by writing the chosen mode to the display-control
          # register. Until this runs the screen stays black.
          #
          # In a program that switches the hardware per scene — some scene double-
          # buffered, or crossing the bitmap/tiled boundary — the screen mode is managed
          # for the whole program by the boot setup and each scene's mode-switch
          # preamble, so a `screen` node is only a build-time declaration of a scene's
          # mode and emits nothing here. Otherwise it's the plain one-time register write.
          def emit_screen(node)
            return if @layout.manage_modes

            mode = node.mode
            value = if mode == :tiled
                      # Tile mode turns on exactly the background layers the program declared,
                      # so a stack of two or three composites; a single background is just BG0.
                      MODE_0 | tiled_bg_enable_bits
                    elsif mode == :rotozoom
                      # The rotate/scale layer: this feature always lands the one affine
                      # background it supports on BG2 (see AFFINE_BG in gba.rb), so that's the
                      # one layer Mode 2 needs on here. A single-mode program never runs
                      # #enter_affine_mode (that's only for per-scene mode switching), so the
                      # one-time "no turn, no resize yet" starting matrix is set here instead.
                      reset_bg2_affine_matrix
                      MODE_2 | BG2_ENABLE
                    elsif mode.is_a?(Integer)
                      mode
                    else
                      SCREEN_MODES.fetch(mode) do
                        raise LoweringError, "the GBA backend cannot lower screen mode #{mode.inspect} yet"
                      end
                    end
            # Turn the sprite layer on alongside the chosen mode when the program has
            # sprites, and pick the simple 1D tile arrangement they're packed for.
            value |= OBJ_ENABLE | OBJ_1D_MAP if @layout.has_objects
            @emitter.write_reg16(REG_DISPCNT, value)
          end

          # The DISPCNT enable bit per layer, and the OR of them for the layers this
          # program declared — at least BG0, so a tiled screen always has one layer on.
          BG_ENABLES = [BG0_ENABLE, BG1_ENABLE, BG2_ENABLE, BG3_ENABLE].freeze
          def tiled_bg_enable_bits
            layers = [@layout.backgrounds.size, 1].max
            bits = BG_ENABLES.first(layers).reduce(0, :|)
            # ...and the object window, for a program that keeps sprites out of a fade.
            bits |= OBJ_WINDOW_ENABLE unless @layout.window_twins.empty?
            bits
          end

          # One-time boot for a program that switches the hardware per scene: put the
          # display in the default scene's mode. A buffered program also uploads its
          # color table here (palette memory survives mode switches), then starts by
          # showing page 0 and drawing into page 1; a tiled default brings up the tile
          # layers and sprites; a direct default is the plain Mode 3 write.
          def emit_boot_screen
            upload_palette if @layout.any_buffered # the palette exists only for the buffered path
            case @layout.default_mode
            when :tiled then enter_tiled_mode
            when :affine then enter_affine_mode
            when :buffered then enter_buffered_mode
            else enter_direct_mode
            end
          end

          # Switch the hardware into double-buffered (Mode 4): remember the live DISPCNT
          # so a flip is a cheap bit-toggle, draw into page 1 first, show page 0, and
          # record that buffered is now the live mode.
          def enter_buffered_mode
            reset_bg2_affine_if_needed
            base = MODE_4 | BG2_ENABLE
            @primitives.store_word_immediate(base, @primitives.var_addr(DISPCNT_STATE))
            @primitives.store_word_immediate(PAGE1, @primitives.var_addr(BACKBUF))
            @emitter.write_reg16(REG_DISPCNT, base)
            @primitives.store_word_immediate(MODE_BUFFERED, @primitives.var_addr(MODE_STATE))
            # A scene that tints leaves its color table blended, and one that remembers a
            # tint has to be able to trust what is in the table. In a program that crosses
            # to the tiled screen, that screen's own colors have been in this table since —
            # so put the originals back, which is also what makes the remembered tint true
            # again.
            upload_palette if @palette_tint.palette_tint? && @layout.mixed_display
          end

          # Switch the hardware into direct-color (Mode 3) and record it as live. Writing
          # the whole register also turns the tile and sprite layers off, so nothing a
          # tiled scene left on screen bleeds under the bitmap one — only BG2 (the
          # framebuffer) shows, which the bitmap scene redraws.
          def enter_direct_mode
            reset_bg2_affine_if_needed
            @emitter.write_reg16(REG_DISPCNT, MODE_3 | BG2_ENABLE)
            @primitives.store_word_immediate(MODE_DIRECT, @primitives.var_addr(MODE_STATE))
          end

          # Switch the hardware into tiled mode (Mode 0). Because the bitmap framebuffer
          # and the tiles share video memory, a bitmap scene overwrites the tile data, so
          # the tile pictures/colors and sprite tiles are (re)uploaded here on entry —
          # cheap, and only on the actual switch. Then turn on the declared background
          # layers (plus the sprite layer if the game has sprites) and record it live.
          # Each background's map and control register are re-set by its own node in the
          # scene body, which runs right after this preamble.
          def enter_tiled_mode
            reset_bg2_affine_if_needed
            emit_boot_backgrounds if @layout.tiled && !@layout.backgrounds.empty? # shared BG palette + tile pictures
            emit_boot_objects if @layout.has_objects                             # sprite palette + tiles, and clear OAM
            @layer_blend.emit_layer_blend_again if @layer_blend.see_through?     # ...and which one is see-through
            value = MODE_0 | tiled_bg_enable_bits
            value |= OBJ_ENABLE | OBJ_1D_MAP if @layout.has_objects
            @emitter.write_reg16(REG_DISPCNT, value)
            @primitives.store_word_immediate(MODE_TILED, @primitives.var_addr(MODE_STATE))
          end

          # Switch the hardware into the affine layer (Mode 2): re-upload the shared BG
          # palette/tile pictures on entry, same reason #enter_tiled_mode does — bitmap
          # and tile VRAM overlap, so a bitmap scene overwrites what the affine
          # background's tiles need. Its own map/matrix are re-set right after this by
          # the background's own node in the scene body (see #emit_background_hardware),
          # the same as a regular tiled layer's.
          def enter_affine_mode
            reset_bg2_affine_matrix # the one-time "no turn, no resize yet" starting matrix
            emit_boot_backgrounds if @layout.tiled && !@layout.backgrounds.empty?
            emit_boot_objects if @layout.has_objects
            @layer_blend.emit_layer_blend_again if @layer_blend.see_through?
            value = MODE_2 | BG2_ENABLE
            value |= OBJ_ENABLE | OBJ_1D_MAP if @layout.has_objects
            @emitter.write_reg16(REG_DISPCNT, value)
            @primitives.store_word_immediate(MODE_AFFINE, @primitives.var_addr(MODE_STATE))
          end

          # Emitted at the top of each scene when a program switches the hardware per
          # scene: switch into this scene's mode, but only if it isn't already there (a
          # transition). Steady frames — the same scene running again — cost just the
          # compare, and a buffered scene's DISPCNT is left to the page flip.
          def emit_scene_preamble(name)
            mode = @layout.func_mode[name]
            @primitives.load_var(ACC, MODE_STATE)
            @emitter.emit(ASM.cmp_imm(ACC, mode_state_marker(mode)))
            skip = @emitter.gensym
            @emitter.emit_branch(:bcond, skip, cond: :eq) # already in this mode? nothing to do
            enter_mode(mode)
            @emitter.place_label(skip)
          end

          # WHICH SCENE'S SPRITE PICTURES ARE IN MEMORY, so that a scene taking over sends
          # its own and a scene already running sends nothing.
          SCENE_ART_STATE = :_scene_art

          # Send a scene's sprite pictures when it takes over. Scenes share the room above
          # whatever is always there, so this is what makes a game's budget one scene's
          # rather than the whole game's — and it is guarded, so staying in a scene costs
          # one compare a frame while changing scene costs the copy.
          #
          # A scene with no art of its own emits nothing at all, which is every scene in a
          # game that declares its sprites at the top level.
          #
          # The copy lands where the scene's own routine runs, which is near the top of a
          # frame rather than strictly between frames. A sprite caught half-replaced would
          # show for one frame — on the frame a game changes what the whole screen is, and
          # where the scene it is leaving has already stopped drawing its own sprites.
          def emit_scene_art_upload(name)
            sending = @layout.scene_art[name]
            return if sending.nil? || sending.empty?

            @primitives.load_var(ACC, SCENE_ART_STATE)
            @emitter.emit(ASM.cmp_imm(ACC, @layout.scene_art.keys.index(name) + 1))
            skip = @emitter.gensym
            @emitter.emit_branch(:bcond, skip, cond: :eq) # already loaded? nothing to send
            sending.each { |blob, at, units| emit_dma_blob(blob, OBJ_TILE_BASE + (at * 32), units * 16) }
            @emitter.emit(ASM.load_immediate(ACC, @layout.scene_art.keys.index(name) + 1))
            @primitives.store_var(ACC, SCENE_ART_STATE)
            @emitter.place_label(skip)
          end

          # A scene's resolved mode -> the marker stored in MODE_STATE, and the routine
          # that switches the hardware into it. Kept as two small methods (not a load-time
          # table) so they resolve the MODE_* constants at call time.
          def mode_state_marker(mode)
            case mode
            when :tiled then MODE_TILED
            when :affine then MODE_AFFINE
            when :buffered then MODE_BUFFERED
            else MODE_DIRECT
            end
          end

          def enter_mode(mode)
            case mode
            when :tiled then enter_tiled_mode
            when :affine then enter_affine_mode
            when :buffered then enter_buffered_mode
            else enter_direct_mode
            end
          end

          # Copy the color table from the cartridge into background palette memory —
          # one DMA of `size` 16-bit entries, source and destination both advancing.
          def upload_palette
            emit_load_data_address(ACC, PALETTE_BLOB)     # r0 = table address in the cartridge
            emit(ASM.load_immediate(TMP, REG_DMA3SAD))
            emit(ASM.str(ACC, TMP))                       # DMA source = the table
            store_word_immediate(BG_PALETTE, REG_DMA3DAD) # DMA destination = palette memory
            store_word_immediate(@layout.palette.size | DMA_ENABLE, REG_DMA3CNT) # go: 16-bit, both increment
            @palette_tint.emit_tint_state_reset # the table now holds the originals again
          end

          # Forwards to @emitter/@primitives/@divide, the same shape every other
          # collaborator's do (see e.g. {Collision}) — this file calls them as bare
          # methods throughout.
          def emit(bytes) = @emitter.emit(bytes)
          def pos = @emitter.pos
          def place_label(name) = @emitter.place_label(name)
          def gensym = @emitter.gensym
          def emit_branch(kind, target, cond: nil) = @emitter.emit_branch(kind, target, cond: cond)
          def emit_load_data_address(reg, name) = @emitter.emit_load_data_address(reg, name)
          def emit_load_label_address(reg, label) = @emitter.emit_load_label_address(reg, label)
          def write_reg16(address, value) = @emitter.write_reg16(address, value)
          def var_addr(name) = @primitives.var_addr(name)
          def load_var(reg, name) = @primitives.load_var(reg, name)
          def store_var(reg, name) = @primitives.store_var(reg, name)
          def store_word_acc(address) = @primitives.store_word_acc(address)
          def store_halfword_acc(address) = @primitives.store_halfword_acc(address)
          def store_word_immediate(value, address) = @primitives.store_word_immediate(value, address)
          def const_int(node) = @primitives.const_int(node)
          def constant_ints!(node, **sides) = @primitives.constant_ints!(node, **sides)
          def emit_row_loop(counter, &block) = @primitives.emit_row_loop(counter, &block)
          def emit_add_const(rd, rn, imm, scratch) = @primitives.emit_add_const(rd, rn, imm, scratch)
          def emit_call_divide_routine = @divide.emit_call_divide_routine
          def backing_info(name) = @backing_info.call(name)
          def fade_targets(under) = @fade_targets.call(under)
          def effect_line(under) = @effect_line.call(under)
          def emit_call_cold_routine(label) = @call_cold_routine.call(label)

          # At the vblank boundary, flip the pages — but only while a buffered scene is
          # live (a direct scene draws straight to the screen and has nothing to flip).
          # The runtime check costs a compare; the mode rarely changes.
          def emit_flip_if_buffered
            load_var(ACC, MODE_STATE)
            emit(ASM.cmp_imm(ACC, MODE_BUFFERED))
            skip = gensym
            emit_branch(:bcond, skip, cond: :ne)
            emit_flip
            place_label(skip)
          end

          # Present the page just drawn and start drawing the other one — the page
          # flip, run once per frame at the vblank boundary. Toggle the DISPCNT bit
          # that selects the shown page (so the finished page becomes visible), then
          # point the back buffer at the other page (its address is the pair's sum
          # minus the current one).
          def emit_flip
            load_var(ACC, DISPCNT_STATE)
            emit(ASM.load_immediate(TMP, DISPCNT_FRAME_SELECT))
            emit(ASM.eor_reg(ACC, ACC, TMP))            # flip the page-select bit
            store_var(ACC, DISPCNT_STATE)
            emit(ASM.load_immediate(TMP, REG_DISPCNT))
            emit(ASM.store_halfword(ACC, TMP))          # the finished page is now shown

            load_var(ACC, BACKBUF)
            emit(ASM.load_immediate(TMP, PAGE_PAIR_SUM))
            emit(ASM.sub_reg(ACC, TMP, ACC))            # the other page
            store_var(ACC, BACKBUF)
          end

          # Plot one pixel. With constant coordinates the VRAM address is known now,
          # so it's a single store. With a computed coordinate (e.g. a variable) the
          # address is built at run time from the evaluated x/y.
          def emit_pixel(node)
            return @buffered.emit_pixel_buffered(node) if @lowering.mode == :buffered

            color = Color.resolve(node.color)
            xi = const_int(node.x)
            yi = const_int(node.y)

            if xi && yi
              return unless @framebuffer.in_bounds?(xi, yi) # off-screen: clip, like the framebuffer

              write_reg16(VRAM_START + ((yi * SCREEN_WIDTH) + xi) * 2, color)
            else
              @lowering.value(node.y)            # r0 = y
              emit(ASM.push(ACC))
              @lowering.value(node.x)            # r0 = x
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
            return @buffered.emit_fill_rect_buffered(node) if @lowering.mode == :buffered

            x, y, w, h = constant_ints!(node, x: node.x, y: node.y, w: node.w, h: node.h)
            color = Color.resolve(node.color)
            emit(ASM.load_immediate(ACC, color))
            h.times do |dy|
              row = y + dy
              next unless (@framebuffer.clip_top...@framebuffer.clip_bottom).cover?(row)

              w.times do |dx|
                col = x + dx
                next unless (@framebuffer.clip_left...@framebuffer.clip_right).cover?(col)

                emit(ASM.load_immediate(TMP, VRAM_START + ((row * SCREEN_WIDTH) + col) * 2))
                emit(ASM.store_halfword(ACC, TMP))
              end
            end
          end

          # Clear the whole screen with one DMA transfer: repeat a packed two-pixel
          # word across VRAM. The DMA engine copies far faster than a pixel loop.
          def emit_clear_screen(node)
            return @buffered.emit_clear_screen_buffered(node) if @lowering.mode == :buffered
            # Inside an area, "the whole screen" is that area — which is a rectangle, and there
            # is already one way to fill one of those.
            return emit_fill_area(node.color) if @framebuffer.clipping?

            color = Color.resolve(node.color)
            word = (color << 16) | color
            count = SCREEN_WIDTH * SCREEN_HEIGHT / 2
            scratch = var_addr(:_dma_scratch)

            store_word_immediate(word, scratch)                 # hold the fill word in IWRAM
            store_word_immediate(scratch, REG_DMA3SAD)          # source: the fixed word
            store_word_immediate(VRAM_START, REG_DMA3DAD)       # destination: the screen
            store_word_immediate(@framebuffer.dma_fill_control(count), REG_DMA3CNT) # kick off the transfer
          end

          # A rectangle at a fixed position and size, filled fast with per-row DMA:
          # each row is one block transfer of a repeated two-pixel word. Rows off the
          # top/bottom of the screen are skipped.
          def emit_dma_fill_rect(node)
            return @buffered.emit_fill_rect_buffered(node) if @lowering.mode == :buffered

            x, y, w, h = constant_ints!(node, x: node.x, y: node.y, w: node.w, h: node.h)
            @framebuffer.even_width!(w, :dma_fill_rect)
            # Held to the area sideways before a single row is emitted: every row of a rectangle
            # spans the same columns, so where it starts and how far it reaches is one answer.
            left = [x, @framebuffer.clip_left].max
            right = [x + w, @framebuffer.clip_right].min
            return if right <= left

            scratch = @framebuffer.hold_fill_word(node.color)
            control = @framebuffer.fill_control_for_column(left, right - left)

            h.times do |dy|
              row = y + dy
              next unless (@framebuffer.clip_top...@framebuffer.clip_bottom).cover?(row)

              row_addr = VRAM_START + ((row * SCREEN_WIDTH) + left) * 2
              @framebuffer.fire_dma_fill(scratch, row_addr, control)
            end
          end

          # A rectangle whose position and size are all computed at run time. Same
          # per-row DMA fill as dma_fill_rect, but each row's destination address is
          # built from the live x/y instead of known up front. r2/r3 hold x/y across the
          # loop, r6 the rows left, r7 the fill's control word; r4/r5 are address
          # scratch. (No run-time bounds clip yet — the caller is expected to keep it
          # on-screen, as pong does by clamping.)
          #
          # A size settled while building is unrolled with an immediate control word,
          # exactly as it always was, so a paddle or a ball costs what it did before.
          # Only a size the game works out pays for a counter and a computed word.
          # One column of a picture, stretched to a height worked out as the game runs. The
          # whole of a first-person view is this, once per strip across the screen.
          #
          # It walks DOWN THE SCREEN, asking which row of the picture belongs at each screen
          # row. The other way round — walking the picture and working out where each of its
          # rows lands — leaves gaps when stretching and writes some rows twice when squashing.
          # The interpreter walks the same way, which is what makes the two agree pixel for
          # pixel.
          # ONE WALK FILLS THE WHOLE STRIP. Every pixel across a strip shows the same picture
          # column at the same height, so working the walk out once and writing its answer
          # across is not an optimisation — calling this once per pixel instead asks for the
          # same answer that many times over.
          def emit_draw_column_at(node)
            return @buffered.emit_draw_column_at_buffered(node) if @lowering.mode == :buffered

            bmp = @layout.bitmaps.fetch(node.name) do
              raise LoweringError, "draw_column_at of undefined image #{node.name.inspect}"
            end
            width = node.width || 1

            done = gensym
            @framebuffer.emit_column_setup(node, bmp, done)
            @framebuffer.emit_column_runs(node.name, bmp, done) do |leave|
              @framebuffer.emit_clip_column_rows(leave)

              # The left and right edges are settled ONCE here, because a strip has one x for
              # its whole height. A strip wholly inside them then writes with nothing to test;
              # one hanging over an edge takes a second copy of the rows that tests each pixel,
              # which is the rare case and pays for itself only there. A strip one pixel wide
              # has no second case: it is inside or it draws nothing.
              clipped = gensym
              emit(ASM.cmp_imm(COLUMN_X, @framebuffer.clip_left))
              emit_branch(:bcond, clipped, cond: :lt)
              emit(ASM.load_immediate(TMP, @framebuffer.clip_right - width))
              emit(ASM.cmp_reg(COLUMN_X, TMP))
              emit_branch(:bcond, clipped, cond: :gt)

              emit_column_rows { emit_draw_column_row(bmp, width, clipped: false) }
              emit_branch(:b, leave) if width > 1
              place_label(clipped)
              emit_column_rows { emit_draw_column_row(bmp, width, clipped: true) } if width > 1
            end
            place_label(done)
          end

          # The walk down the screen, one pass per row of the column that shows.
          def emit_column_rows
            emit_row_loop(COLUMN_ROWS) do
              yield
              emit(ASM.add_reg(COLUMN_POS, COLUMN_POS, COLUMN_STEP))
              emit(ASM.add_imm(COLUMN_Y, COLUMN_Y, 1))
            end
          end

          # One row of the strip: work out which picture row we are on, read its colour, and
          # write it across. Every row this reaches is on the screen — that was settled before
          # the walk started.
          def emit_draw_column_row(bmp, width, clipped:)
            skip = gensym

            emit_read_column_pixel(bmp, skip)

            # ...to the screen at (x, y), and to the pixels beside it. Their addresses are a
            # fixed distance along from the first, so the row's address is built once.
            emit(ASM.load_immediate(TMP, SCREEN_WIDTH))
            emit(ASM.mul(TMP, COLUMN_Y, TMP))
            emit(ASM.add_reg(TMP, TMP, COLUMN_X))
            emit(ASM.lsl_imm(TMP, TMP, 1))
            emit(ASM.load_immediate(SPARE, VRAM_START))
            emit(ASM.add_reg(TMP, TMP, SPARE))
            width.times { |dx| emit_column_store(dx, clipped: clipped) }

            place_label(skip)
          end

          # colour = picture[(pos >> 16) * width + slice], the slice already folded into
          # COLUMN_SRC. Leaves it in ACC, or jumps to +skip+ when the pixel is see-through.
          #
          # THE ROW CANNOT RUN PAST THE PICTURE, so nothing holds it back. The step is the
          # picture's height shifted up over the row count, rounded down, and the last row
          # reaches at most one less than that count times it — which is strictly less than
          # the picture's height however the rounding falls.
          def emit_read_column_pixel(bmp, skip)
            emit(ASM.lsr_imm(ACC, COLUMN_POS, COLUMN_FIXED))
            emit(ASM.load_immediate(TMP, bmp.width * 2))
            emit(ASM.mul(ACC, ACC, TMP))
            emit(ASM.add_reg(ACC, COLUMN_SRC, ACC))
            emit(ASM.load_halfword(ACC, ACC))

            # A see-through pixel carries a value no real color has, so it means "leave this
            # one alone" and nothing is written — which is what lets a scaled sprite in a
            # first-person view keep its shape instead of standing in a black box.
            return unless bmp.transparent

            emit(ASM.load_immediate(TMP, bmp.transparent))
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, skip, cond: :eq)
          end

          # One pixel of the strip. In the clipped copy of the rows its own column is tested,
          # since only part of the strip is on the screen.
          def emit_column_store(offset, clipped:)
            return emit(ASM.store_halfword_offset(ACC, TMP, offset * 2)) unless clipped

            past = gensym
            emit(ASM.add_imm(SPARE, COLUMN_X, offset))
            emit(ASM.cmp_imm(SPARE, @framebuffer.clip_left))
            emit_branch(:bcond, past, cond: :lt)
            emit(ASM.cmp_imm(SPARE, @framebuffer.clip_right))
            emit_branch(:bcond, past, cond: :ge)
            emit(ASM.store_halfword_offset(ACC, TMP, offset * 2))
            place_label(past)
          end

          def emit_draw_rect_at(node)
            return @buffered.emit_draw_rect_at_buffered(node) if @lowering.mode == :buffered

            x_const = const_int(node.x)
            y_const = const_int(node.y)
            width = const_int(node.w)
            height = const_int(node.h)
            return if width && width < 1   # a rect with no width draws nothing
            return if height && height < 1 # ...or no height

            # Every edge settled while building: clip it here, in Ruby, once, and fire
            # the fill straight at plain addresses — nothing for the console to check.
            # A bar or column at a fixed place and size costs exactly what it always did.
            return emit_draw_rect_at_fixed(x_const, y_const, width, height, node.color) if x_const && y_const && width && height

            emit_draw_rect_at_computed(node, width, height)
          end

          # A rect whose x, y, width and height are ALL known while building.
          def emit_draw_rect_at_fixed(x, y, width, height, color)
            left = [x, @framebuffer.clip_left].max
            right = [x + width, @framebuffer.clip_right].min
            return if right <= left

            top = [y, @framebuffer.clip_top].max
            bottom = [y + height, @framebuffer.clip_bottom].min
            return if bottom <= top

            scratch = @framebuffer.hold_fill_word(color)
            control = @framebuffer.fill_control_for_column(nil, right - left)
            (top...bottom).each do |row|
              row_addr = VRAM_START + ((row * SCREEN_WIDTH) + left) * 2
              @framebuffer.fire_dma_fill(scratch, row_addr, control)
            end
          end

          # A rect with at least one edge the game works out as it runs, so the clip has
          # to happen at run time.
          #
          # x and width settle to one on-screen span before any row fires — a rect has
          # one x for its whole height, the same reason draw_column_at settles its
          # column once instead of testing it every row. Every row THEN checks its own
          # y against the area, because a run-time y or height means a run-time set of
          # rows survives: an unclipped row is what wrapped a rect onto its neighbor.
          def emit_draw_rect_at_computed(node, width, height)
            scratch = @framebuffer.hold_fill_word(node.color)

            x_reg = 2
            y_reg = 3
            rows_left = 6
            @framebuffer.eval_rect_position(node, x_reg: x_reg, y_reg: y_reg, rows_reg: rows_left,
                                                   width_reg: CONTROL_REG)

            skip = gensym

            # right = x + width, unclipped, worked out before x itself is touched.
            if width
              emit_add_const(ACC, x_reg, width, TMP)
            else
              emit(ASM.add_reg(ACC, x_reg, CONTROL_REG)) # CONTROL_REG still holds the raw width here
            end

            # right := min(right, clip_right)
            keep_right = gensym
            emit(ASM.cmp_imm(ACC, @framebuffer.clip_right))
            emit_branch(:bcond, keep_right, cond: :le)
            emit(ASM.load_immediate(ACC, @framebuffer.clip_right))
            place_label(keep_right)

            # x_reg := max(x_reg, clip_left)
            keep_left = gensym
            emit(ASM.cmp_imm(x_reg, @framebuffer.clip_left))
            emit_branch(:bcond, keep_left, cond: :ge)
            emit(ASM.load_immediate(x_reg, @framebuffer.clip_left))
            place_label(keep_left)

            # width := right - x_reg. Nothing left of the row to draw at all bails the
            # whole rect, the same way a width of zero already did — a rect the game
            # shrank to nothing, or slid entirely off the area, draws nothing either way.
            emit(ASM.sub_reg(TMP, ACC, x_reg))
            emit(ASM.cmp_imm(TMP, 0))
            emit_branch(:bcond, skip, cond: :le)
            emit(ASM.mov_reg(CONTROL_REG, TMP))
            emit(ASM.load_immediate(ACC, @framebuffer.dma_fill_control_halfwords(0)))
            emit(ASM.orr_reg(CONTROL_REG, CONTROL_REG, ACC)) # ...now it is a control word

            if height
              height.times { |dy| emit_mode3_rect_row(dy, x_reg, y_reg, scratch) }
            else
              emit_row_loop(rows_left) do
                emit_mode3_rect_row(0, x_reg, y_reg, scratch)
                emit(ASM.add_imm(y_reg, y_reg, 1)) # ...and on to the next row down
              end
            end
            place_label(skip)
          end

          # The register a computed width, and then the fill's control word built from
          # it, lives in for the whole rect.
          CONTROL_REG = 7

          # One row of a run-time-positioned rect: skip it outright if its y falls
          # outside the area (a row above or below it draws NOTHING, not a row wrapped
          # onto its neighbor), else work out where it lands in video memory and fire
          # the fill. +dy+ is how far below the rect's y this row is; the fill's control
          # word always lives in CONTROL_REG by the time this runs.
          def emit_mode3_rect_row(dy, x_reg, y_reg, scratch)
            row_skip = gensym

            # r4 = y + dy, checked against the area before it becomes an address.
            if dy.zero?
              emit(ASM.mov_reg(4, y_reg))
            else
              emit(ASM.add_imm(4, y_reg, dy))
            end
            emit(ASM.cmp_imm(4, @framebuffer.clip_top))
            emit_branch(:bcond, row_skip, cond: :lt)
            emit(ASM.cmp_imm(4, @framebuffer.clip_bottom))
            emit_branch(:bcond, row_skip, cond: :ge)

            emit(ASM.load_immediate(5, SCREEN_WIDTH))
            emit(ASM.mul(4, 5, 4))           # r4 = width * (y + dy)
            emit(ASM.add_reg(4, 4, x_reg))   # + x
            emit(ASM.lsl_imm(4, 4, 1))       # * 2 bytes per pixel
            emit(ASM.load_immediate(5, VRAM_START))
            emit(ASM.add_reg(4, 4, 5))       # + VRAM base

            store_word_immediate(scratch, REG_DMA3SAD)
            emit(ASM.load_immediate(TMP, REG_DMA3DAD))
            emit(ASM.str(4, TMP))            # destination is the computed address
            emit(ASM.load_immediate(TMP, REG_DMA3CNT))
            emit(ASM.str(CONTROL_REG, TMP))

            place_label(row_skip)
          end

          # Draw a defined bitmap at a runtime (x, y). An opaque bitmap streams from
          # ROM by DMA; one with transparency is drawn pixel-by-pixel so its
          # transparent pixels can be skipped. Either way the draw is clipped to the
          # screen at run time — a bitmap pushed partway off an edge draws only its
          # visible part, with nothing written past the framebuffer.
          def emit_blit(node)
            bmp = @layout.bitmaps.fetch(node.name) do
              raise LoweringError, "blit of undefined image #{node.name.inspect}"
            end
            return @buffered.emit_blit_buffered(node, bmp) if @lowering.mode == :buffered

            bmp.transparent ? emit_blit_transparent(node, bmp) : emit_blit_opaque(node, bmp)
          end

          # Opaque bitmap: stream each row straight from the cartridge into VRAM by
          # DMA — a run-time-positioned rectangle copy from a ROM buffer onto the
          # screen. The shared row engine below does the clipping.
          def emit_blit_opaque(node, bmp)
            emit_rect_row_dma(node.x, node.y, bmp.width, bmp.height, node.name, vram: :dest)
          end

          # Draw a tiled background. In tile mode the console draws the whole layer
          # from data in video memory, so it's uploaded once (emit_background_hardware).
          # In bitmap mode there's no tile hardware, so each cell is stamped with the
          # blit path instead — correct, just a copy per cell.
          def emit_background(node)
            @layout.tiled ? emit_background_hardware(node) : emit_background_blits(node)
          end

          # The per-layer control and scroll registers, indexed by BG number (0..3), so a
          # layer configures and scrolls its own hardware layer.
          BG_CNT_REGS  = [REG_BG0CNT, REG_BG1CNT, REG_BG2CNT, REG_BG3CNT].freeze
          BG_HOFS_REGS = [REG_BG0HOFS, REG_BG1HOFS, REG_BG2HOFS, REG_BG3HOFS].freeze
          BG_VOFS_REGS = [REG_BG0VOFS, REG_BG1VOFS, REG_BG2VOFS, REG_BG3VOFS].freeze

          # Upload the one palette and the one run of tile pictures every layer draws from,
          # once at boot — the pictures to the start of video memory, the colors to
          # background palette memory. It is one run however many layers there are; where
          # in it each layer starts counting its tile numbers is a per-layer setting, and
          # goes in with the rest of them below. Each layer's map and control register are
          # set later, when its background node is reached (emit_background_hardware).
          def emit_boot_backgrounds
            emit_dma_blob(BG_SHARED_PAL, BG_PALETTE, @layout.bg_shared[:pal_units])   # colors -> palette memory
            emit_dma_blob(BG_SHARED_CHAR, VRAM_START, @layout.bg_shared[:char_units]) # tile pictures -> video memory
            @palette_tint.emit_tint_state_reset # the table now holds the originals again
          end

          # Point one layer's hardware at its data: DMA its map into its own screen block,
          # then set its control register (how its pixels are stored, where it counts its
          # tile numbers from, that screen block, and its paint-order priority) and reset
          # its scroll to the top-left. Drawn once — after that the hardware repaints the
          # whole layer every frame for free, and composites the layers by priority so
          # nearer ones sit in front.
          def emit_background_hardware(node)
            bg = @layout.backgrounds.fetch(node.name)
            return emit_affine_background_hardware(bg) if bg.affine

            emit_dma_blob(bg.map, VRAM_START + (bg.screen_block * SCREENBLOCK_BYTES), bg.map_units)
            depth = bg.small ? 0 : BG_256_COLOR # a small layer's tiles each name their own bank
            write_reg16(BG_CNT_REGS[bg.bg], bg.priority | depth | (bg.char_base << CHAR_BASE_SHIFT) |
                                            (bg.screen_block << 8) | bg.size)
            write_reg16(BG_HOFS_REGS[bg.bg], 0) # start unscrolled
            write_reg16(BG_VOFS_REGS[bg.bg], 0)
          end

          # PUT A DIFFERENT TILE IN ONE CELL, while the game runs.
          #
          # A background's map is a grid of half-word cells in video memory, each naming
          # the tile to draw there, so changing one is one half-word written to a place
          # worked out from the cell's column and row.
          #
          # WHEN THE WRITE HAPPENS, which is the question this raises and which is worth
          # writing down because the obvious worry turns out not to hold. The display
          # reads the map WHILE it draws, so a write can land between two scanlines of the
          # very cell being drawn — and then that cell shows the old tile on its top rows
          # and the new one on its bottom rows, for one frame.
          #
          # It is not a torn or corrupt picture: a cell is a half-word, and a half-word
          # store is one write. Nothing can be read half-written. The whole effect is that
          # one 8-pixel cell is split across a single frame, and only when a write lands
          # inside that cell's own six-thousandths of a frame.
          #
          # So this writes straight away rather than holding the frame's changes and
          # applying them between frames. Holding them costs a buffer in the console's
          # scarcest memory, a policy for when it fills, and about four times the
          # instructions — to remove an artifact of one frame of one cell, on the things
          # this exists for: a door opening, a pot breaking, a bombable wall. What that
          # bargain does NOT cover is a BULK change — a whole room swapped in one frame —
          # where half the old room and half the new really would show at once. That wants
          # a verb of its own, handing over a map in one go between frames.
          def emit_set_tile(node)
            bg = @layout.backgrounds[node.name]
            return if bg.nil? # a background with no tiled layer (a bitmap-mode program)

            cell = @layout.map_cells.fetch(node.name)
            entry = @layout.map_entries.fetch(node.name).fetch(node.tile)
            fixed = [const_int(node.col), const_int(node.row)]
            return emit_fixed_tile_write(bg, cell, entry, *fixed) if fixed.all?

            emit_computed_tile_write(node, bg, cell, entry)
          end

          # A cell settled while the program was written: the address is worked out here,
          # in Ruby, and the console does one store.
          def emit_fixed_tile_write(bg, cell, entry, col, row)
            return unless col >= 0 && col < cell[:cols] && row >= 0 && row < cell[:rows]

            write_reg16(map_cell_address(bg, cell, col, row), entry)
          end

          # THE ADDRESS OF ONE CELL, and why it is not simply row times width.
          #
          # A map wider or taller than 32 cells is stored as several 32x32 SQUARES — left
          # then right, top pair before bottom pair — so a cell's place depends on which
          # quarter of the map it is in. 32 is a power of two, so that is shifts and masks
          # rather than division.
          def map_cell_address(bg, cell, col, row)
            quarter = ((row / MAP_CELLS) * (cell[:cols] / MAP_CELLS)) + (col / MAP_CELLS)
            index = (quarter * MAP_CELLS * MAP_CELLS) + ((row % MAP_CELLS) * MAP_CELLS) + (col % MAP_CELLS)
            VRAM_START + (bg.screen_block * SCREENBLOCK_BYTES) + (index * 2)
          end

          # A cell the game works out. The two coordinates are held in scratch registers
          # while the address is assembled, and a cell outside the map is skipped rather
          # than written somewhere else — so a coordinate that ran off the edge costs a
          # test and changes nothing.
          TILE_COL = 4
          TILE_ROW = 5
          TILE_ADDR = 6

          def emit_computed_tile_write(node, bg, cell, entry)
            @lowering.value(node.col)
            emit(ASM.mov_reg(TILE_COL, ACC))
            @lowering.value(node.row)
            emit(ASM.mov_reg(TILE_ROW, ACC))

            done = gensym
            # One unsigned compare catches both ends: a negative coordinate reads as a
            # very large number, so anything outside 0...size fails the same test.
            emit(ASM.cmp_imm(TILE_COL, cell[:cols]))
            emit_branch(:b, done, cond: ASM::COND_HS)
            emit(ASM.cmp_imm(TILE_ROW, cell[:rows]))
            emit_branch(:b, done, cond: ASM::COND_HS)

            emit_cell_index(cell)
            emit(ASM.load_immediate(TMP, VRAM_START + (bg.screen_block * SCREENBLOCK_BYTES)))
            emit(ASM.lsl_imm(TILE_ADDR, TILE_ADDR, 1)) # two bytes a cell
            emit(ASM.add_reg(TILE_ADDR, TMP, TILE_ADDR))
            emit(ASM.load_immediate(ACC, entry))
            emit(ASM.store_halfword(ACC, TILE_ADDR))
            place_label(done)
          end

          # The cell's index within the whole map, built from the column and row into
          # TILE_ADDR. Which quarter of the map it is in rides in bits 10 and up; a map
          # that fits one square has no quarters and needs neither shift.
          def emit_cell_index(cell)
            emit(ASM.and_imm(TILE_ADDR, TILE_ROW, MAP_CELLS - 1))
            emit(ASM.lsl_imm(TILE_ADDR, TILE_ADDR, 5))
            emit(ASM.and_imm(TMP, TILE_COL, MAP_CELLS - 1))
            emit(ASM.orr_reg(TILE_ADDR, TILE_ADDR, TMP))
            return if cell[:cols] == MAP_CELLS && cell[:rows] == MAP_CELLS

            unless cell[:rows] == MAP_CELLS
              # The bottom half of a tall map is a whole square further on — two of them
              # when the map is also wide, since a row of squares comes first.
              emit(ASM.lsr_imm(TMP, TILE_ROW, 5))
              emit(ASM.lsl_imm(TMP, TMP, cell[:cols] == MAP_CELLS ? 10 : 11))
              emit(ASM.orr_reg(TILE_ADDR, TILE_ADDR, TMP))
            end
            return if cell[:cols] == MAP_CELLS

            emit(ASM.lsr_imm(TMP, TILE_COL, 5))
            emit(ASM.lsl_imm(TMP, TMP, 10))
            emit(ASM.orr_reg(TILE_ADDR, TILE_ADDR, TMP))
          end

          # Bit 13: the map WRAPS at its edge instead of showing the backdrop past it — the
          # same torus every `screen :tiled` background already is.
          AFFINE_WRAP = 0x2000

          # Put BG2's rotate/scale registers back to "no transform" — matrix identity,
          # zero reference point — the same state #emit_affine_background_hardware boots
          # an affine background to. Only a program with an affine background at all
          # needs this: those registers are also what Modes 3/4/5 render their bitmap
          # framebuffer through (see #emit_affine_background's comment), so switching
          # INTO any other mode has to leave BG2 neutral, or a bitmap/tiled scene
          # entered right after an affine one keeps showing whatever turn or zoom the
          # affine scene last left sitting in hardware.
          def reset_bg2_affine_if_needed
            return unless @layout.backgrounds.values.any?(&:affine)

            reset_bg2_affine_matrix
          end

          # The actual identity-matrix write, factored out so it can be called from
          # three places that each need it exactly ONCE: leaving affine mode (above),
          # genuinely entering it (#enter_affine_mode), and the plain single-mode boot
          # path (#emit_screen) — never from #emit_affine_background_hardware, which
          # runs every frame a scene-owned background's own node re-executes and would
          # otherwise stomp a growing rotate/scale right back to "no transform" before
          # the console ever shows it.
          def reset_bg2_affine_matrix
            write_reg16(REG_BG2PA, FIXED_ONE)
            write_reg16(REG_BG2PB, 0)
            write_reg16(REG_BG2PC, 0)
            write_reg16(REG_BG2PD, FIXED_ONE)
            store_word_immediate(0, REG_BG2X)
            store_word_immediate(0, REG_BG2Y)
          end

          # Point the console's rotate/scale layer (BG2) at an affine background's map
          # and tiles — its OWN node in the scene body, so it may run every frame the
          # owning scene is active (harmless: same map, same control bits, every time).
          # The matrix itself is NOT reset here — a scene-owned background is turned or
          # resized by a per-frame write inserted at the frame boundary (see
          # Builder#finalize_background_affine), which runs BEFORE this node in program
          # order each frame; resetting the matrix here would throw that away before
          # the console ever displayed it. The one-time "upright, undistorted" starting
          # matrix is set at genuine mode entry instead (#enter_affine_mode, or here at
          # boot for a single-mode program — see #emit_screen).
          def emit_affine_background_hardware(bg)
            emit_dma_blob(bg.map, VRAM_START + (bg.screen_block * SCREENBLOCK_BYTES), bg.map_units)
            write_reg16(REG_BG2CNT,
                        bg.priority | BG_256_COLOR | (bg.char_base << CHAR_BASE_SHIFT) |
                        (bg.screen_block << 8) | AFFINE_WRAP | bg.size)
          end

          # Scratch memory the affine background's matrix numbers pass through on their
          # way to the hardware registers — a background keeps only one matrix (unlike a
          # sprite's per-slot OAM group), so there's nowhere else to park PA-PD while the
          # reference point below is worked out from them.
          BG_AFFINE_PA = :_bg_affine_pa
          BG_AFFINE_PB = :_bg_affine_pb
          BG_AFFINE_PC = :_bg_affine_pc
          BG_AFFINE_PD = :_bg_affine_pd
          BG_AFFINE_SCALE_RECIP = :_bg_affine_scale_recip

          # The screen's own middle, in pixels — half of 240x160. The pivot a `rotate` or
          # `scale` turns the background about.
          AFFINE_BG_CENTER_X = 120
          AFFINE_BG_CENTER_Y = 80

          # Turn/resize the affine background: work out this frame's rotate/scale matrix
          # and write it to BG2's registers, then move the reference point so the turn
          # pivots on the middle of the screen (see #emit_bg_affine_reference_point for
          # why that needs its own step).
          def emit_affine_background(node)
            # Outside `screen :rotozoom` there's no rotate/scale layer prepared for this
            # background to write into — and unlike a plain scroll's fallback registers
            # (harmlessly inert when that layer isn't on), BG2's affine registers are
            # never inert: a bitmap screen reads them too (Modes 3/4's framebuffer is
            # itself rendered through this same BG2 matrix). So rather than fall back
            # onto them, this does nothing at all, the same choice #emit_scroll_background
            # makes for a background outside tile mode.
            return unless @layout.backgrounds[node.name]&.affine

            # A background turned only inside one scene (see Builder#affine_each_frame)
            # carries an `active` condition the same shape a sprite's does — skip the
            # write entirely on a frame where its scene isn't the live one, so a
            # zoomed title screen can never keep distorting a bitmap gameplay scene
            # that's since taken over BG2 for its own framebuffer.
            @lowering.value(node.active)
            emit(ASM.cmp_imm(ACC, 0))
            skip = gensym
            emit_branch(:bcond, skip, cond: :eq)
            emit_bg_affine_matrix(node)
            emit_bg_affine_reference_point
            place_label(skip)
          end

          # The same numbers a turning hardware sprite reads (see
          # #emit_object_affine_matrix, whose steps this mirrors) — one sine-table lookup
          # for sin and cos, scaled by one over the size — except there is no OAM group to
          # drop them into, so each one goes to hardware AND to a scratch variable, which
          # the reference point step below reads back.
          def emit_bg_affine_matrix(node)
            emit_bg_affine_scale_reciprocal(node.scale)
            @lowering.value(node.angle)                       # r0 = angle in degrees (0..359)
            emit_load_data_address(TMP, OBJ_SINE_BLOB)   # r1 = sine table base
            emit(ASM.lsl_imm(2, ACC, 1))                 # r2 = angle * 2 (halfword offset)
            emit(ASM.add_reg(ADDR, TMP, 2))
            emit(ASM.ldrsh(2, ADDR))                     # r2 = sin(angle)
            emit(ASM.add_imm(3, ACC, 90))                # r3 = angle + 90
            emit(ASM.lsl_imm(3, 3, 1))
            emit(ASM.add_reg(ADDR, TMP, 3))
            emit(ASM.ldrsh(3, ADDR))                     # r3 = sin(angle + 90) = cos(angle)
            emit_bg_scale_sine_and_cosine
            emit(ASM.rsb_imm(ACC, 2, 0))                 # r0 = -sin(angle)
            store_halfword_reg(3, REG_BG2PA)
            store_var(3, BG_AFFINE_PA)
            store_halfword_reg(2, REG_BG2PB)
            store_var(2, BG_AFFINE_PB)
            store_halfword_reg(ACC, REG_BG2PC)
            store_var(ACC, BG_AFFINE_PC)
            store_halfword_reg(3, REG_BG2PD)
            store_var(3, BG_AFFINE_PD)
          end

          # One over this frame's size, the same divide a resizing sprite does (see
          # #emit_object_scale_reciprocal) — a background always carries a size variable
          # once it's ever turned or resized (rotate and scale share the same pair of
          # variables), so this runs every frame rather than only when scale is in play.
          def emit_bg_affine_scale_reciprocal(scale)
            @lowering.value(scale)                                    # r0 = size, in SCALE_ONE-ths
            emit(ASM.cmp_imm(ACC, Affine::MIN_SCALE))
            emit(ASM.mov_imm_cond(:lt, ACC, Affine::MIN_SCALE))
            emit(ASM.load_immediate(Divide::DIV_NUM, Build::SCALE_ONE * Affine::ONE_TH))
            emit_call_divide_routine
            emit(ASM.load_immediate(TMP, Affine::MAX))
            emit(ASM.cmp_reg(ACC, TMP))
            emit(ASM.mov_reg_cond(:gt, ACC, TMP))
            store_var(ACC, BG_AFFINE_SCALE_RECIP)
          end

          # Scale the sine and cosine in r2/r3 by the reciprocal above, back down into
          # 256ths — the background's own copy of #emit_scale_sine_and_cosine.
          def emit_bg_scale_sine_and_cosine
            load_var(4, BG_AFFINE_SCALE_RECIP)
            emit(ASM.mul(5, 2, 4))
            emit(ASM.asr_imm(2, 5, 8))
            emit(ASM.mul(5, 3, 4))
            emit(ASM.asr_imm(3, 5, 8))
          end

          # The matrix pivots on the layer's own top-left corner by itself — turn or
          # resize without this and the whole picture swings away from under the middle of
          # the screen instead of turning in place. Moving the pivot to the screen's own
          # center (120, 80) means telling the console the texture point that SHOULD land
          # there, worked backwards through the very matrix just written: for a screen
          # point this far from (0, 0), the matrix says how far that is from the
          # reference point in texture space, so read backwards, the reference point is
          # the screen center's texture position minus that offset. One multiply-and-
          # subtract per axis, the same shape a turned sprite gets for free by centering
          # its drawing box (see #emit_draw_object_transformed) — a background has no box
          # of its own to offset, so this stands in for it.
          def emit_bg_affine_reference_point
            load_var(2, BG_AFFINE_PA)
            emit(ASM.load_immediate(3, AFFINE_BG_CENTER_X))
            emit(ASM.mul(4, 2, 3))                       # r4 = PA * center_x
            load_var(2, BG_AFFINE_PB)
            emit(ASM.load_immediate(3, AFFINE_BG_CENTER_Y))
            emit(ASM.mul(5, 2, 3))                       # r5 = PB * center_y
            emit(ASM.add_reg(4, 4, 5))                   # r4 = PA*center_x + PB*center_y
            emit(ASM.load_immediate(ACC, AFFINE_BG_CENTER_X * Affine::ONE_TH))
            emit(ASM.sub_reg(ACC, ACC, 4))
            store_word_acc(REG_BG2X)

            load_var(2, BG_AFFINE_PC)
            emit(ASM.load_immediate(3, AFFINE_BG_CENTER_X))
            emit(ASM.mul(4, 2, 3))                       # r4 = PC * center_x
            load_var(2, BG_AFFINE_PD)
            emit(ASM.load_immediate(3, AFFINE_BG_CENTER_Y))
            emit(ASM.mul(5, 2, 3))                       # r5 = PD * center_y
            emit(ASM.add_reg(4, 4, 5))                   # r4 = PC*center_x + PD*center_y
            emit(ASM.load_immediate(ACC, AFFINE_BG_CENTER_Y * Affine::ONE_TH))
            emit(ASM.sub_reg(ACC, ACC, 4))
            store_word_acc(REG_BG2Y)
          end

          # Scroll one layer: write the window's top-left offset into that layer's scroll
          # registers. The tile hardware does the rest — it draws the layer starting at
          # that offset and wraps the map around, so a moving offset scrolls the whole
          # layer for free (no redrawing). Two layers scrolled at different speeds give
          # parallax. The offset is evaluated at run time from the game's scroll variables.
          # The scale/rotate matrix that means "no scaling, no rotation" — 1.0 in the
          # console's 8-fraction-bit fixed point.
          FIXED_ONE = 0x0100

          # Move the visible window over the whole picture.
          #
          # The bitmap screen is drawn by the console's one scalable layer, and that
          # layer fetches its pixels starting from a reference point. Write a new
          # reference point and the whole picture slides, with no redrawing at all —
          # which is what makes a screen shake nearly free. The game keeps drawing
          # exactly what it drew before; only the window onto it moves.
          #
          # Two details the hardware needs. The reference point counts in a fixed-point
          # number with 8 fraction bits, so a whole number of pixels is that number
          # shifted up by 8. And the same layer carries a scale/rotate matrix that the
          # console powers on holding zeroes, which would shrink the picture away to
          # nothing; setting it to no-scale-no-rotate here keeps the pan a plain slide.
          # It is set beside the offset rather than at boot so a program that never
          # moves the camera emits not one extra byte.
          def emit_camera(node)
            raise LoweringError, CAMERA_NEEDS_BITMAP if @layout.default_mode == :tiled

            write_reg16(REG_BG2PA, FIXED_ONE)
            write_reg16(REG_BG2PB, 0)
            write_reg16(REG_BG2PC, 0)
            write_reg16(REG_BG2PD, FIXED_ONE)
            emit_camera_axis(node.x, REG_BG2X)
            emit_camera_axis(node.y, REG_BG2Y)
          end

          CAMERA_NEEDS_BITMAP =
            "the camera cannot move a tiled screen yet. It moves the bitmap screen, so " \
            "`shake_screen` needs `screen :bitmap`. To move a tiled background, use " \
            "`scroll_by` or `scroll_to` on the background."

          def emit_camera_axis(value, reg)
            @lowering.value(value)                   # r0 = the offset in whole pixels
            emit(ASM.lsl_imm(ACC, ACC, 8))      # ...into the 8-fraction-bit format
            store_word_acc(reg)
          end

          # Blend the whole picture toward black or white.
          #
          # The console can do this as it draws: one register says which layers to
          # blend and which way, another says how far. Nothing is redrawn and no pixel
          # in memory changes, so a fade costs the same whatever is on screen and the
          # picture is still all there when it lifts. Every layer and the backdrop are
          # blended, so this works the same on a bitmap screen and a tiled one.
          #
          # "How far" counts in sixteenths, while the DSL talks in percent, so the
          # amount is scaled. A fixed amount is worked out here and written as a plain
          # number; an amount the game computes is scaled at run time, which is a
          # multiply and a divide once per call — nothing next to a frame.
          def emit_fade(node)
            # On a screen drawn through a color table the two effects are separate pieces
            # of hardware, so nothing puts a tint away by itself. The display still holds
            # one whole-picture effect at a time — that is the rule the DSL states and the
            # interpreter models — so a fade puts the colors back. Only a program that
            # tints such a screen emits this, and the check inside is one compare.
            @palette_tint.emit_lift_palette_tint(@layout.modes.mode_at(node)) if @palette_tint.palette_tint? &&
                                                                                  @palette_tint.palette_screen?(node)
            return emit_fade_sharing_the_blend(node) if @layer_blend.see_through?

            emit_fade_registers(node)
          end

          # Which layers the fade reaches and which way, then how far.
          def emit_fade_registers(node)
            emit_fade_control(node)

            if (amount = const_int(node.amount))
              write_reg16(REG_BLDY, fade_steps(amount))
            else
              @lowering.value(fade_steps_value(node.amount))
              store_halfword_acc(REG_BLDY)
            end
          end

          def emit_fade_control(node)
            mode = node.toward == :white ? BLD_BRIGHTEN : BLD_DARKEN
            write_reg16(REG_BLDCNT, mode | fade_targets(node.under))
            # Where this fade sits in the stack, for the window twins to read. Only a
            # program that has twins writes it (see GBA#prepare_effect_layers).
            store_word_immediate(effect_line(node.under), var_addr(EFFECT_LINE)) unless @layout.window_twins.empty?
          end

          # How far the fade has come, in the sixteenths the hardware counts in, for an
          # amount the game works out as it runs.
          #
          # A class method because the estimate prices this conversion, and the conversion
          # is not in the tree to be found — the lowering builds it. Handed a number, it
          # answers the shape, which is what the estimate wants to price.
          def self.fade_steps_value(amount)
            Build.binop(:/, Build.binop(:*, amount, Build.int(Constants::BLD_MAX)), Build.int(100))
          end

          def fade_steps_value(amount) = Drawing.fade_steps_value(amount)

          # Where the amount waits while the registers around it are written. Free within
          # a statement, like the other scratch registers.
          FADE_HELD = 2

          # A FADE AND A SEE-THROUGH LAYER ARE THE SAME PIECE OF DISPLAY, so only one of
          # them can be in force. The blend unit is told which effect it is running in one
          # field of one register: mixing two layers together, or moving the whole picture
          # toward black. A fade writes that field, and the layer's blend is gone while it
          # holds it — the layer draws solid, and darkens with everything else, which is
          # what a fade out is supposed to look like.
          #
          # What must not happen is that it stays gone. A fade ends AT ZERO — invisible,
          # but still a fade as far as the register is concerned — so without this a single
          # hit flash would leave the water solid for the rest of the game, with nothing on
          # screen or in the build to say why.
          #
          # So a fade of nothing hands the register back rather than writing a dead fade.
          # A zero the author wrote is settled here and costs not one instruction; an amount
          # the game works out is a compare and a branch, which is what a fade walked over
          # frames arrives as.
          def emit_fade_sharing_the_blend(node)
            if (amount = const_int(node.amount))
              return @layer_blend.emit_layer_blend_again if fade_steps(amount).zero?

              return emit_fade_registers(node)
            end

            emit_fade_or_hand_back(node)
          end

          def emit_fade_or_hand_back(node)
            hand_back = gensym
            done = gensym
            @lowering.value(fade_steps_value(node.amount))
            emit(ASM.mov_reg(FADE_HELD, ACC))
            emit(ASM.cmp_imm(FADE_HELD, 0))
            emit_branch(:bcond, hand_back, cond: :eq)
            emit_fade_control(node)
            emit(ASM.mov_reg(ACC, FADE_HELD))
            store_halfword_acc(REG_BLDY)
            emit_branch(:b, done)
            place_label(hand_back)
            @layer_blend.emit_layer_blend_again
            place_label(done)
          end

          # A percentage of the way there, in the sixteenths the hardware counts in.
          def fade_steps(percent)
            ((percent * BLD_MAX) / 100).clamp(0, BLD_MAX)
          end

          # Mix a color INTO the whole picture, which is a different piece of the display
          # from the fade above and not a fade with a color argument.
          #
          # Two mechanisms, chosen by the screen — see PaletteTint for the other one, and
          # for why a screen that draws through a color table cannot use this one.
          #
          # The display can blend two layers together as it draws, weighing each one. So
          # the picture is blended against the BACKDROP — the color shown where nothing
          # was drawn — with the backdrop set to the tint. Turn the weights toward the
          # backdrop and the whole picture moves toward that color. Nothing is redrawn
          # and no pixel in memory changes, so this costs the same whatever is on screen
          # and the picture is all still there when the amount returns to 0.
          #
          # This works because on the direct-color screen the picture is one layer of
          # its own colors, so the backdrop is free to be anything and nothing else in
          # the picture reads it. The screens that draw through a shared color table
          # cannot do it this way, and the DSL refuses them where the author writes it
          # (Builder::Drawing#check_tint_screen!).
          #
          # The weights are a pair that adds to sixteen: what is left of the picture,
          # and how much of the color has come in.
          def emit_tint(node)
            return @palette_tint.emit_palette_tint(node) if @palette_tint.palette_screen?(node)

            write_reg16(PALETTE_START, Color.resolve(node.color)) # the backdrop IS the tint
            write_reg16(REG_BLDCNT, BLD_ALPHA | BLD_BG2 | (BLD_BACKDROP << BLD_SECOND_SHIFT))

            if (amount = const_int(node.amount))
              write_reg16(REG_BLDALPHA, tint_weights(fade_steps(amount)))
            else
              @lowering.value(Build.binop(:/, Build.binop(:*, node.amount, Build.int(BLD_MAX)),
                                     Build.int(100)))
              emit_blend_weights_from_acc
            end
          end

          # The weight pair as one halfword: how much of the picture survives in the low
          # byte, how much of the color comes in above it.
          def tint_weights(steps)
            (BLD_MAX - steps) | (steps << 8)
          end

          # The same pair, for an amount the game works out. r0 holds the steps.
          #
          # Shared by the two things that blend two layers together: a tint on the
          # direct-color screen, and a see-through layer. They mean different things by
          # the two sides — a color coming in, or what is behind showing through — and the
          # register does not care, so neither does this.
          def emit_blend_weights_from_acc
            emit(ASM.load_immediate(TMP, BLD_MAX))
            emit(ASM.sub_reg(TMP, TMP, ACC))              # r1 = what is left of the near side
            emit(ASM.orr_reg_lsl(ACC, TMP, ACC, 8))       # ...with the far side's share above it
            store_halfword_acc(REG_BLDALPHA)
          end

          # An amount past either end settles at that end rather than running off it, the
          # same as the interpreter does. Where the weights go into a register the display
          # itself clamps this is free, but a share worked out here can be more than all of
          # it — and that takes a picture somewhere no color goes.
          def emit_clamp_blend_steps
            emit(ASM.cmp_imm(ACC, 0))
            emit(ASM.mov_imm_cond(:lt, ACC, 0))
            emit(ASM.cmp_imm(ACC, BLD_MAX))
            emit(ASM.mov_imm_cond(:gt, ACC, BLD_MAX))
          end

          def emit_scroll_background(node)
            # In tile mode this names a real layer; outside it (a bitmap-mode program that
            # still declares a background) there's no tiled layer, so fall back to BG0 —
            # the scroll registers do nothing when that layer isn't on, matching the
            # interpreter's harmless handling.
            bg_num = @layout.backgrounds[node.name]&.bg || 0
            # A bending layer's sideways position is settled row by row instead, and every
            # one of those rows already has this scroll in it (see Raster). Writing it here
            # too would only undo the top row's bend until the display asked for the next.
            unless @raster.row_bends.key?(node.name)
              @lowering.value(node.x)        # r0 = scroll x (pixels)
              store_halfword_acc(BG_HOFS_REGS[bg_num])
            end
            @lowering.value(node.y)          # r0 = scroll y
            store_halfword_acc(BG_VOFS_REGS[bg_num])
          end

          # Fill a fixed video-memory slot from an embedded blob at startup. This is the
          # one seam every tile upload goes through, so it is also where packing pays
          # off: try to pack the blob first, and if that shrank the cart, expand it into
          # the slot with the BIOS instead of copying it. Either way the slot ends up
          # holding the same bytes; only the size of the cart changes.
          def emit_dma_blob(blob_name, dest, units)
            case pack_blob(blob_name)
            when :lz77 then emit_bios_decompress(blob_name, dest, SWI_LZ77_VRAM)
            when :rle  then emit_bios_decompress(blob_name, dest, SWI_RLE_VRAM)
            else emit_plain_dma_blob(blob_name, dest, units)
            end
          end

          # One DMA of +units+ 16-bit words from an embedded blob to a fixed address,
          # both ends advancing — the same shape as the palette upload. Fills palette
          # and video memory at startup.
          def emit_plain_dma_blob(blob_name, dest, units)
            emit_load_data_address(ACC, blob_name)
            emit(ASM.load_immediate(TMP, REG_DMA3SAD))
            emit(ASM.str(ACC, TMP)) # DMA source = the blob in the cartridge
            store_word_immediate(dest, REG_DMA3DAD)
            store_word_immediate(units | DMA_ENABLE, REG_DMA3CNT) # go: 16-bit, both increment
          end

          # BIOS decompression routines that expand two bytes at a time. Every slot we
          # fill this way — video memory, the palettes, the tile maps — rejects a single
          # byte write, so we always use the 16-bit variants. The routine number rides
          # in bits 16-23 of the SWI instruction (the ARM software-interrupt encoding).
          SWI_LZ77_VRAM = 0x12
          SWI_RLE_VRAM  = 0x15

          # Ask the BIOS to expand a packed blob straight into +dest+. r0 points at the
          # packed source (its 4-byte header first), r1 at the destination; the routine
          # reads the expanded size from the header, so there is no length to pass.
          def emit_bios_decompress(blob_name, dest, swi_number)
            emit_load_data_address(0, blob_name)   # r0 = packed source in the cartridge
            emit(ASM.load_immediate(1, dest))      # r1 = destination slot
            emit(ASM.swi(swi_number << 16))
          end

          # Pack a blob the first time we are about to upload it, and remember the
          # result so a later upload of the same blob (a scene re-entered) reuses it
          # instead of packing again. Returns the codec (:lz77/:rle/:none). When a
          # scheme shrinks the blob, the packed bytes replace the raw ones in place, so
          # the data region lays down the smaller version.
          def pack_blob(blob_name)
            return @layout.blob_codecs[blob_name] if @layout.blob_codecs.key?(blob_name)

            raw = @emitter.data_blobs[blob_name]
            codec, blob = BiosCompress.best(raw)
            unless codec == :none
              @layout.blob_raw_bytes[blob_name] = raw.bytesize # remember the before size for the savings line
              @emitter.data_blobs[blob_name] = blob
            end
            @layout.blob_codecs[blob_name] = codec
          end

          # --- sprites (hardware-composited moving objects) ---

          # Where a sprite's tiles live: the object tile area of video memory, and the
          # sprite table itself. In tile mode the console draws sprites from tiles kept
          # in this region, separate from the background's, so the two never collide.
          OBJ_TILE_BASE = VRAM_START + 0x10000 # object tiles start 64KB into video memory
          OBJ_HIDDEN_ATTR0 = 0x0200            # attr0 marking a sprite-table slot unused
          OBJ_HIDDEN_WORD  = 0x02000200        # two hidden attr0s, for a fast table clear

          # A turning sprite sets two more attr0 bits. Rotate/scale (bit 8) tells the
          # console to draw this sprite through an affine parameter group instead of
          # straight. Double-size (bit 9) draws it in a box twice as wide and tall so a
          # rotated corner has room and never clips — we place the box so the sprite
          # stays centered where an upright one would sit. (With rotate/scale off, this
          # same bit 9 is the "hidden" marker above, which is why hiding still works.)
          OBJ_ROTSCALE     = 0x0100
          OBJ_DOUBLE_SIZE  = 0x0200

          # Where one over a resizing sprite's size is parked between the divide that
          # works it out and the multiplies that use it (see #emit_object_scale_reciprocal).
          # One variable serves every sprite, because each is done with before the next
          # one starts.
          OBJ_SCALE_RECIP = :_obj_scale_recip

          # One-time sprite setup at boot: blank the whole sprite table (its memory is
          # garbage at power-on, so an untouched slot would show a stray sprite), upload
          # the one shared color table every sprite indexes into, then each sprite's
          # tiles into video memory. After this the per-frame draw just points slots at
          # these tiles.
          def emit_boot_objects
            clear_object_table
            # Nothing is loaded yet, and the console's memory is garbage at power-on — so
            # the first scene to take over has to find a number that is not its own.
            @primitives.store_word_immediate(0, @primitives.var_addr(SCENE_ART_STATE)) if @layout.scene_art.any?
            emit_dma_blob(@layout.obj_palette_blob, OBJ_PALETTE, @layout.obj_palette_units) # the shared sprite palette, once
            @layout.objects.each_value do |obj|
              # A sprite showing the same pictures as one already uploaded points at
              # those, so there is nothing of its own to send. A sprite that belongs to a
              # scene is sent when that scene takes over, not here (see
              # #emit_scene_art_upload), since scenes share the room above this.
              next if obj[:tiles].nil? || obj[:scene]

              emit_dma_blob(obj[:tiles], OBJ_TILE_BASE + (obj[:tile_index] * 32), obj[:tile_units] * 16) # tiles -> sprite memory
            end
            emit_boot_object_windows
            @palette_tint.emit_tint_state_reset # the table now holds the originals again
          end

          # Set up the object window, once, for a program that keeps sprites out of a
          # fade. Outside it every layer shows and the color effect applies; inside it
          # every layer still shows and the effect does not. The region itself is the
          # shape of whatever the twin sprites paint, so nothing here mentions a place on
          # screen. EFFECT_LINE starts past the front of the stack: until a fade is
          # placed, no twin shows.
          def emit_boot_object_windows
            return if @layout.window_twins.empty?

            write_reg16(REG_WINOUT, WIN_ALL_LAYERS | WIN_EFFECT | (WIN_ALL_LAYERS << WINOUT_OBJ_SHIFT))
            store_word_immediate(@layout.picture.stack.length, var_addr(EFFECT_LINE))
          end

          # Fill the sprite table with the "unused slot" marker so no leftover memory
          # shows as a sprite. One source-fixed DMA of a word that is two hidden slots.
          def clear_object_table
            scratch = var_addr(:_oam_clear)
            store_word_immediate(OBJ_HIDDEN_WORD, scratch)
            store_word_immediate(scratch, REG_DMA3SAD)
            store_word_immediate(OAM_START, REG_DMA3DAD)
            store_word_immediate(@framebuffer.dma_fill_control(OAM_SIZE / 4), REG_DMA3CNT)
          end

          # Draw this frame's sprites: write each named object's current position and
          # visibility into its slot in the sprite table. Runs right after the vblank
          # (when changing the table is safe), so a moving sprite lands at its new spot
          # with no tearing. The console composites the sprites over the background for
          # free — there's nothing to erase, unlike a software sprite.
          def emit_present_objects(node)
            node.names.each { |name| emit_present_object(@layout.objects.fetch(name), twin: @layout.window_twins[name]) }
          end

          # Write one sprite's table entries from its live x/y/active variables. A hidden
          # sprite (active == 0) gets the "unused slot" marker instead, so it vanishes; a
          # shown one gets its position, size, and tiles — drawn upright, or turned to its
          # current angle when the sprite rotates.
          #
          # +twin+ is the window that keeps this sprite out of a placed fade, when it has
          # one. It stands exactly where the sprite stands and holds exactly the pose the
          # sprite holds, so it is filled in from the SAME numbers on the way past rather
          # than worked out again — a copy of each attribute as it is written, and one test
          # of where the fade is sitting. See GBA#prepare_object_windows.
          def emit_present_object(obj, twin: nil)
            base = OAM_START + (obj[:slot] * 8)
            mirror = twin && OAM_START + (twin[:slot] * 8)

            @lowering.value(obj[:active])
            emit(ASM.cmp_imm(ACC, 0))
            draw = gensym
            done = gensym
            emit_branch(:bcond, draw, cond: :ne)
            write_reg16(base, OBJ_HIDDEN_ATTR0) # active == 0: mark the slot unused
            write_reg16(mirror, OBJ_HIDDEN_ATTR0) if mirror # ...and the window over it
            emit_branch(:b, done)

            place_label(draw)
            if obj[:transformed]
              emit_draw_object_transformed(obj, base, mirror)
            else
              emit_draw_object_upright(obj, base, mirror)
            end
            emit_window_gate(twin, mirror) if mirror
            place_label(done)
          end

          # An upright sprite: position and size straight into its slot.
          def emit_draw_object_upright(obj, base, mirror = nil)
            # attr0 = (y & 0xFF) | shape + 256-color flag
            @lowering.value(obj[:y])
            mask_into_acc(0xFF)
            orr_acc(obj[:attr0_base])
            store_halfword_acc(base)
            mirror_attr0(mirror)
            # attr1 = (x & 0x1FF) | size
            @lowering.value(obj[:x])
            mask_into_acc(0x1FF)
            orr_acc(obj[:attr1_base])
            store_halfword_acc(base + 2)
            store_halfword_acc(mirror + 2) if mirror
            # attr2 = which tiles to draw = this sprite's base tile + pose * stride
            # (palette bank/priority left at 0). A fixed pose folds to a constant.
            emit_object_tile_number(obj, base + 4)
            store_halfword_acc(mirror + 4) if mirror
          end

          # Drop the attr0 just written into the window twin's slot as well, with the bit
          # that makes it a window rather than a picture. The value is still in hand, so
          # this is two instructions and not a second sprite worked out from scratch.
          def mirror_attr0(mirror)
            return unless mirror

            orr_acc(OBJ_WINDOW_MODE)
            store_halfword_acc(mirror)
          end

          # Put the window away when the fade in force is not behind this sprite — a fade
          # over the whole screen, or one placed further forward. The sprite itself has
          # already been written, so this only has to hide the twin.
          def emit_window_gate(twin, mirror)
            @lowering.value(twin[:gate])
            emit(ASM.cmp_imm(ACC, 0))
            keeps = gensym
            emit_branch(:bcond, keeps, cond: :ne)
            write_reg16(mirror, OBJ_HIDDEN_ATTR0)
            place_label(keeps)
          end

          # A turning or resizing sprite: the console draws it through its affine group in
          # a double-size box. We offset the box top-left by half the sprite so the
          # picture stays centered where an upright one would sit and pivots on its own
          # center, turn on the rotate/scale and double-size bits, point attr1 at the
          # affine group, then fill that group with this frame's matrix.
          def emit_draw_object_transformed(obj, base, mirror = nil)
            half_w = obj[:width] / 2
            half_h = obj[:height] / 2
            # attr0 = ((y - half_h) & 0xFF) | rotate/scale + double-size + shape/color
            @lowering.value(obj[:y])
            emit(ASM.sub_imm(ACC, ACC, half_h)) unless half_h.zero?
            mask_into_acc(0xFF)
            orr_acc(obj[:attr0_base] | OBJ_ROTSCALE | OBJ_DOUBLE_SIZE)
            store_halfword_acc(base)
            mirror_attr0(mirror)
            # attr1 = ((x - half_w) & 0x1FF) | size | affine-group index (bits 9..13)
            @lowering.value(obj[:x])
            emit(ASM.sub_imm(ACC, ACC, half_w)) unless half_w.zero?
            mask_into_acc(0x1FF)
            orr_acc(obj[:attr1_base] | (obj[:affine_slot] << 9))
            store_halfword_acc(base + 2)
            # The twin points at the same affine group, so it turns and resizes with the
            # sprite and the hole stays the shape of the picture.
            store_halfword_acc(mirror + 2) if mirror
            emit_object_tile_number(obj, base + 4)
            store_halfword_acc(mirror + 4) if mirror
            emit_object_affine_matrix(obj)
          end

          # Fill this sprite's affine group with the matrix for its current angle and
          # size. The group's four parameters (PA, PB, PC, PD) live in the fourth
          # halfword of four sprite slots, 8 bytes apart, starting 6 bytes into the
          # group. For a clockwise turn of the drawn picture the matrix is
          # [PA PB; PC PD] = [cos sin; -sin cos], each scaled by one over the size — the
          # console reads it as screen -> picture, so it is the same matrix the reference
          # interpreter samples through, built by the same {IR::Affine} rules. The two
          # agree by design.
          def emit_object_affine_matrix(obj)
            group = OAM_START + (obj[:affine_slot] * 32)
            emit_object_scale_reciprocal(obj) if obj[:scales] # do the divide first: it clobbers everything
            @lowering.value(obj[:angle])                      # r0 = angle in degrees (0..359)
            emit_load_data_address(TMP, OBJ_SINE_BLOB)   # r1 = sine table base
            emit(ASM.lsl_imm(2, ACC, 1))                 # r2 = angle * 2 (halfword offset)
            emit(ASM.add_reg(ADDR, TMP, 2))
            emit(ASM.ldrsh(2, ADDR))                     # r2 = sin(angle)
            emit(ASM.add_imm(3, ACC, 90))                # r3 = angle + 90
            emit(ASM.lsl_imm(3, 3, 1))
            emit(ASM.add_reg(ADDR, TMP, 3))
            emit(ASM.ldrsh(3, ADDR))                     # r3 = sin(angle + 90) = cos(angle)
            emit_scale_sine_and_cosine if obj[:scales]   # r2, r3 *= one over the size
            emit(ASM.rsb_imm(ACC, 2, 0))                 # r0 = -sin(angle)
            store_halfword_reg(3, group + 6)             # PA =  cos
            store_halfword_reg(2, group + 14)            # PB =  sin
            store_halfword_reg(ACC, group + 22)          # PC = -sin
            store_halfword_reg(3, group + 30)            # PD =  cos
          end

          # Work out one over this sprite's size and park it in a scratch variable.
          #
          # The matrix says which picture pixel lands on a given screen pixel, so drawing
          # bigger means stepping through the picture SLOWER — the matrix carries one
          # over the size, not the size. There is nothing to precompute (the size is a
          # number the game works out), so this is a real division, once per resizing
          # sprite per frame, and it is why resizing costs more than turning.
          #
          # It goes to memory rather than staying in a register because the divide
          # routine uses every scratch register there is.
          def emit_object_scale_reciprocal(obj)
            @lowering.value(obj[:scale])                             # r0 = size, in SCALE_ONE-ths
            emit(ASM.cmp_imm(ACC, Affine::MIN_SCALE))
            emit(ASM.mov_imm_cond(:lt, ACC, Affine::MIN_SCALE)) # a size of 0 has no reciprocal
            emit(ASM.load_immediate(Divide::DIV_NUM, Build::SCALE_ONE * Affine::ONE_TH))
            emit_call_divide_routine                            # r0 = SCALE_ONE * 256 / size
            emit(ASM.load_immediate(TMP, Affine::MAX))
            emit(ASM.cmp_reg(ACC, TMP))
            emit(ASM.mov_reg_cond(:gt, ACC, TMP))               # too tiny to say: hold at the largest
            store_var(ACC, OBJ_SCALE_RECIP)
          end

          # Scale the sine and cosine in r2/r3 by the reciprocal worked out above, back
          # down into 256ths. A shift, not a divide, so the rounding matches
          # Affine.matrix — which rounds down for the same reason.
          def emit_scale_sine_and_cosine
            load_var(4, OBJ_SCALE_RECIP)
            emit(ASM.mul(5, 2, 4)) # rd must differ from rm, so the product lands elsewhere
            emit(ASM.asr_imm(2, 5, 8))
            emit(ASM.mul(5, 3, 4))
            emit(ASM.asr_imm(3, 5, 8))
          end

          # Store the low halfword of +reg+ to a fixed address (a sibling of
          # store_halfword_acc for when the value isn't in the accumulator).
          def store_halfword_reg(reg, address)
            emit(ASM.load_immediate(TMP, address))
            emit(ASM.store_halfword(reg, TMP))
          end

          # Write a sprite's tile number (attr2) for this frame. The sprite's poses sit
          # back to back in tile memory, so the pose it's showing is base + pose*stride.
          # A constant pose (the common single-pose sprite) folds to a plain write; a
          # variable pose (facing / animation) is computed at run time.
          def emit_object_tile_number(obj, attr2_addr)
            fixed = const_int(obj[:pose])
            if fixed
              write_reg16(attr2_addr, obj[:tile_index] + (fixed * obj[:per_pose]) | obj[:attr2_base])
            else
              @lowering.value(obj[:pose])                          # r0 = pose index
              emit(ASM.load_immediate(TMP, obj[:per_pose]))   # r1 = stride between poses
              emit(ASM.mul(2, ACC, TMP))                      # r2 = pose * stride (rd must differ from rm)
              emit_add_const(ACC, 2, obj[:tile_index], TMP)   # r0 = r2 + base tile
              orr_acc(obj[:attr2_base]) unless obj[:attr2_base].zero?
              store_halfword_acc(attr2_addr)
            end
          end

          # r0 &= mask, using a scratch register so any mask width is fine.
          def mask_into_acc(mask)
            emit(ASM.load_immediate(TMP, mask))
            emit(ASM.and_reg(ACC, ACC, TMP))
          end

          # r0 |= value, via a scratch register (values here have bits too high for an
          # inline immediate).
          def orr_acc(value)
            emit(ASM.load_immediate(TMP, value))
            emit(ASM.orr_reg(ACC, ACC, TMP))
          end

          # Bitmap-mode background: no tile hardware, so stamp each non-empty cell with
          # the shared blit path — a positioned copy of the tile image onto the screen.
          def emit_background_blits(node)
            tiles = node.tiles
            tile_w = node.tile_w
            tile_h = node.tile_h
            node.map.each_with_index do |row, r|
              row.each_with_index do |index, c|
                next if index.nil?

                emit_blit(Build.blit(tiles[index], c * tile_w, r * tile_h))
              end
            end
          end

          # Draw whichever pose a run-time index selects. The image can't be chosen at
          # build time, so this expands to one guarded blit per pose — exactly one of
          # which draws — the same shape as a run-time digit. Each guard reuses the
          # shared blit path, so a pose honors clipping and transparency like any image.
          def emit_blit_pose(node)
            node.poses.each_with_index do |name, k|
              @lowering.statement(Build.if_(Build.binop(:==, node.index, Build.int(k)),
                                       Build.blit(name, node.x, node.y)))
            end
          end

          def backing_region_unsupported_in_buffered!
            raise LoweringError,
                  "A sprite's save and restore cannot run on the tear-free screen (`tear_free: true`). Its " \
                  "backing store holds direct colors, and that screen stores colors as color-table indices. " \
                  "To use sprites, use the direct-color screen: drop `tear_free:`."
          end

          # Save the screen patch under a moving object into its RAM backing store:
          # read the screen (VRAM) INTO the buffer. Same row engine as a blit, run in
          # the other direction.
          def emit_save_region(node)
            backing_region_unsupported_in_buffered! if @lowering.mode == :buffered
            info = backing_info(node.buffer)
            emit_rect_row_dma(node.x, node.y, info[:width], info[:height], info[:base], vram: :src)
          end

          # Put a saved patch back on the screen: stream the RAM buffer INTO VRAM, just
          # like a blit but sourced from the backing store instead of a ROM image.
          def emit_restore_region(node)
            backing_region_unsupported_in_buffered! if @lowering.mode == :buffered
            info = backing_info(node.buffer)
            emit_rect_row_dma(node.x, node.y, info[:width], info[:height], info[:base], vram: :dest)
          end

          # Copy the rows of a run-time-positioned width×height rectangle between the
          # screen (VRAM) and a row-major linear buffer, one 16-bit DMA per row,
          # clipping each row to the screen. This is the shared engine under blitting
          # an image and under a sprite's save/restore of what it covers.
          #
          # +vram:+ picks the direction. `:dest` streams the buffer ONTO the screen —
          # a blit, or a sprite putting back the pixels it had covered. `:src` reads
          # the screen INTO the buffer — a sprite capturing what it is about to cover.
          # Everything else about a row is identical either way, which is the whole
          # reason this is one method.
          #
          # +base+ says where the linear buffer lives: a Symbol names a ROM blob (its
          # address is patched in once the data region is placed); an Integer is a
          # fixed address in RAM (a sprite's reserved backing store). The buffer is
          # addressed row-major (row*width + column), so a clipped row drops the same
          # columns on both ends — which is exactly what lets a capture and a later
          # restore at the same spot round-trip a sprite hanging off an edge.
          #
          # Clipping is at run time because x/y are runtime values. A row off the top
          # or bottom is skipped whole; a row crossing a side edge is trimmed to its
          # on-screen span (the buffer end skips the clipped columns, the screen end
          # starts at the first visible column, the count is just the visible width) —
          # without the trim a row past the right edge would wrap onto the next line.
          #
          # r6 holds the buffer base and r7/r8 hold x/y across the whole copy; the
          # rest (r2–r5, r9–r11) are per-row scratch.
          def emit_rect_row_dma(x_node, y_node, width, height, base, vram:)
            buf_reg = 6
            x_reg = 7
            y_reg = 8
            @lowering.value(x_node)
            emit(ASM.mov_reg(x_reg, ACC))
            @lowering.value(y_node)
            emit(ASM.mov_reg(y_reg, ACC))
            case base
            when Symbol  then emit_load_data_address(buf_reg, base)    # r6 = ROM blob address
            when Integer then emit(ASM.load_immediate(buf_reg, base))  # r6 = RAM buffer address
            else raise LoweringError, "rect DMA base must be a blob name or a RAM address, got #{base.inspect}"
            end

            height.times do |row|
              skip = gensym

              # screen_y = y + row; drop the whole row if it's above or below screen.
              emit_add_const(9, y_reg, row, 2)          # r9 = screen_y
              emit(ASM.cmp_imm(9, 0))
              emit_branch(:bcond, skip, cond: :lt)
              emit(ASM.cmp_imm(9, SCREEN_HEIGHT))
              emit_branch(:bcond, skip, cond: :ge)

              # visible_left = max(x, 0)  -> r10
              emit(ASM.mov_reg(10, x_reg))
              emit(ASM.cmp_imm(x_reg, 0))
              keep_left = gensym
              emit_branch(:bcond, keep_left, cond: :ge)
              emit(ASM.load_immediate(10, 0))
              place_label(keep_left)

              # visible_right = min(x + width, SCREEN_WIDTH)  -> r11
              emit_add_const(11, x_reg, width, 2)
              emit(ASM.cmp_imm(11, SCREEN_WIDTH))
              keep_right = gensym
              emit_branch(:bcond, keep_right, cond: :le)
              emit(ASM.load_immediate(11, SCREEN_WIDTH))
              place_label(keep_right)

              # visible_width = visible_right - visible_left  -> r4; if <= 0 the row
              # is entirely off to one side, so skip it.
              emit(ASM.sub_reg(4, 11, 10))
              emit(ASM.cmp_imm(4, 0))
              emit_branch(:bcond, skip, cond: :le)

              # buffer span address = base + (row*width + left_skip) * 2  -> r5
              emit(ASM.sub_reg(5, 10, x_reg))           # left_skip = visible_left - x
              emit_add_const(5, 5, row * width, 2)      # + this row's start in the buffer
              emit(ASM.lsl_imm(5, 5, 1))                # * 2 bytes/pixel
              emit(ASM.add_reg(5, buf_reg, 5))

              # screen span address = VRAM + (screen_y*SCREEN_WIDTH + visible_left) * 2 -> r3
              emit(ASM.load_immediate(2, SCREEN_WIDTH))
              emit(ASM.mul(3, 9, 2))                    # r3 = screen_y * width
              emit(ASM.add_reg(3, 3, 10))               # + visible_left
              emit(ASM.lsl_imm(3, 3, 1))
              emit(ASM.load_immediate(2, VRAM_START))
              emit(ASM.add_reg(3, 3, 2))

              # control = visible_width | DMA_ENABLE (16-bit, source+dest increment).
              emit(ASM.orr_imm(4, 4, DMA_ENABLE))

              # Direction decides which span is the source: :dest sends the buffer
              # (r5) to the screen (r3); :src reads the screen (r3) into the buffer (r5).
              sad, dad = vram == :dest ? [5, 3] : [3, 5]
              emit(ASM.load_immediate(TMP, REG_DMA3SAD))
              emit(ASM.str(sad, TMP))                   # source span
              emit(ASM.load_immediate(TMP, REG_DMA3DAD))
              emit(ASM.str(dad, TMP))                   # destination span
              emit(ASM.load_immediate(TMP, REG_DMA3CNT))
              emit(ASM.str(4, TMP))                     # kick off the row copy

              place_label(skip)
            end
          end

          # Transparent bitmap: the art is known at build time, so unroll it. Emit a
          # store only for each NON-transparent pixel — with its color baked in, at
          # the run-time-computed destination — and simply skip transparent ones, so
          # the background shows through.
          #
          # Each store is guarded by a run-time screen-bounds check (x/y are runtime
          # values), so a lit pixel pushed off an edge is dropped rather than written
          # off the framebuffer — the same per-pixel clipping the interpreter does.
          # The row's off-top/off-bottom test is hoisted out of the pixel loop.
          #
          # r2/r3 hold x/y across the blit; r4/r6 are the per-row screen_y and row
          # base; r7/r8 are per-pixel scratch.
          def emit_blit_transparent(node, bmp)
            width = bmp.width
            colors = bmp.pixels.unpack("v*")

            x_reg = 2
            y_reg = 3
            @lowering.value(node.x)
            emit(ASM.mov_reg(x_reg, ACC))
            @lowering.value(node.y)
            emit(ASM.mov_reg(y_reg, ACC))

            bmp.height.times do |row|
              lit = width.times.reject { |col| colors[(row * width) + col] == bmp.transparent }
              next if lit.empty? # a fully transparent row draws nothing

              skip_row = gensym
              emit_add_const(4, y_reg, row, 5)          # r4 = screen_y
              emit(ASM.cmp_imm(4, 0))
              emit_branch(:bcond, skip_row, cond: :lt)
              emit(ASM.cmp_imm(4, SCREEN_HEIGHT))
              emit_branch(:bcond, skip_row, cond: :ge)
              emit(ASM.load_immediate(5, SCREEN_WIDTH))
              emit(ASM.mul(6, 4, 5))                    # r6 = screen_y * width (row base)

              lit.each do |col|
                color = colors[(row * width) + col]
                skip_px = gensym

                emit_add_const(7, x_reg, col, 8)        # r7 = screen_x
                emit(ASM.cmp_imm(7, 0))
                emit_branch(:bcond, skip_px, cond: :lt)
                emit(ASM.cmp_imm(7, SCREEN_WIDTH))
                emit_branch(:bcond, skip_px, cond: :ge)

                emit(ASM.add_reg(7, 6, 7))              # r7 = row_base + screen_x
                emit(ASM.lsl_imm(7, 7, 1))              # * 2 bytes/pixel
                emit(ASM.load_immediate(8, VRAM_START))
                emit(ASM.add_reg(7, 7, 8))              # VRAM address
                emit(ASM.load_immediate(8, color))
                emit(ASM.store_halfword(8, 7))

                place_label(skip_px)
              end
              place_label(skip_row)
            end
          end

          # Draw a line of text with the built-in bitmap font. The color loads once,
          # then every set pixel of every glyph is a single halfword store at its
          # fixed VRAM address; off-screen pixels are dropped. Positions are constant.
          def emit_draw_text(node)
            return @buffered.emit_draw_text_buffered(node) if @lowering.mode == :buffered

            x, y = constant_ints!(node, x: node.x, y: node.y)
            emit(ASM.load_immediate(ACC, Color.resolve(node.color)))

            Fonts.get(node.font).each_pixel(node.text) do |dx, dy|
              px = x + dx
              py = y + dy
              next unless @framebuffer.in_bounds?(px, py)

              emit(ASM.load_immediate(TMP, VRAM_START + ((py * SCREEN_WIDTH) + px) * 2))
              emit(ASM.store_halfword(ACC, TMP))
            end
          end

          # Draw the run-time digit held in +value+ (0..9). A font can't be indexed by a
          # run-time value the way an array is, so there are two ways to render it, and
          # the cheaper one is picked here.
          #
          # Data-driven (used for a column that sits fully on-screen with a font no wider
          # than a byte): the ten digit glyphs are embedded once as ROM data, and at run
          # time a small loop looks up the chosen glyph and stamps its set pixels — the
          # same idea as blitting an image. It costs one shared loop plus a few dozen
          # bytes of glyph data, instead of baking every pixel of all ten digits into the
          # code. Each screen mode plots a pixel differently — direct color writes a
          # color, the tear-free screen splices a palette index — but the glyph-walking
          # loop is the same one (emit_digit_glyph_loop).
          #
          # Fan-out (the fallback — a column crossing a screen edge, or a font with wide,
          # ragged, or missing digits): expand to ten mutually exclusive guards, one per
          # digit, exactly one of which draws. Each is a draw_text that clips per pixel
          # and honors the screen mode.
          def emit_draw_digit(node)
            font = Fonts.get(node.font)
            x = const_int(node.x)
            y = const_int(node.y)
            digit_w = @framebuffer.uniform_digit_width(font)
            if x && y && digit_w && @framebuffer.digit_cell_on_screen?(x, y, digit_w, font.height)
              if @lowering.mode == :buffered
                @buffered.emit_draw_digit_data_buffered(node, font, digit_w, x, y)
              else
                emit_draw_digit_data(node, font, digit_w, x, y)
              end
            else
              emit_draw_digit_unrolled(node)
            end
          end

          # The fan-out fallback: ten guarded draw_texts, exactly one of which matches
          # the value and draws. Built as a sub-tree and emitted through the shared
          # statement paths, so it honors the current screen mode via draw_text.
          def emit_draw_digit_unrolled(node)
            10.times do |k|
              @lowering.statement(Build.if_(Build.binop(:==, node.value, Build.int(k)),
                                       Build.draw_text(k.to_s, node.x, node.y, node.color, font: node.font)))
            end
          end

          # Render one run-time digit from an embedded glyph table (direct color): call
          # the shared glyph-walking routine for this font (see #emit_digit_routines)
          # rather than laying its loop out again at every digit place. The digit is
          # already in r0 from evaluating node.value; x, y and color follow as plain
          # arguments in r1-r3, the same way a func's own arguments would (except a
          # func takes none — this is the one internal routine that does).
          def emit_draw_digit_data(node, font, width, x, y)
            color = Color.resolve(node.color)
            @lowering.value(node.value)             # r0 = the digit (0..9)
            emit(ASM.load_immediate(1, x))
            emit(ASM.load_immediate(2, y))
            emit(ASM.load_immediate(3, color))
            emit_call_cold_routine(digit_routine_label(node.font, font, width))
          end

          # The shared routine's label for a font, reserved the first time a digit in
          # that font is drawn and emitted once, later, by #emit_digit_routines. Every
          # other draw_number/draw_digit in the same font reuses the same label — this
          # is the memoization that turns "one copy of the loop per call site" into
          # "one copy of the loop per font actually used this way".
          def digit_routine_label(font_name, font, width)
            @digit_routines ||= {}
            @digit_routines[font_name] ||= begin
              @pending_digit_routines ||= []
              @pending_digit_routines << [font_name, font, width]
              :"__digit_routine_#{font_name}"
            end
          end

          # Emit every shared digit routine this program actually used, once each, after
          # the program's own code (see GBA#lower) — a fall-through guard, a label, a
          # body, a return, the same shape Functions#emit_one_function gives a func,
          # because like a func this is only ever reached by a call.
          #
          # x, y and the fill color arrive as arguments (r1, r2, r3) rather than being
          # baked into the routine, which is what lets one routine serve every call
          # site. They move into r10-r12 first, because the glyph table lookup that
          # follows needs r1-r3 back as scratch.
          def emit_digit_routines
            return unless @pending_digit_routines

            @pending_digit_routines.each do |font_name, font, width|
              emit(ASM.loop_forever) # fall-through guard: only ever entered by the call above
              place_label(:"__digit_routine_#{font_name}")
              emit(ASM.push(14))
              emit(ASM.mov_reg(10, 1)) # r10 = x, held across the routine
              emit(ASM.mov_reg(11, 2)) # r11 = y
              emit(ASM.mov_reg(12, 3)) # r12 = the fill color
              @framebuffer.emit_digit_glyph_loop(font_name, font, width) do |phase|
                case phase
                when :hold then emit(ASM.mov_reg(8, 12)) # r8 = the fill color, held
                when :plot then emit_plot_digit_pixel(10, 11)
                end
              end
              emit(ASM.pop(15))
              # Where it ends, so a profile of the finished game can say how much of a frame
              # went into drawing digits. A routine the LOWERING makes has no other record of
              # its span — func_ranges only knows routines somebody wrote.
              place_label(:"__digit_routine_#{font_name}_end")
            end
          end

          # Stamp the current glyph pixel: screen = VRAM + ((y+row)*W + (x+col))*2, in
          # the held color (r8). x_reg/y_reg hold the cell's origin — arguments to the
          # shared routine, not constants baked in here — and r5/r4 are the live
          # row/col. Uses r0–r3 as scratch and leaves the loop registers alone.
          def emit_plot_digit_pixel(x_reg, y_reg)
            emit(ASM.add_reg(0, y_reg, 5))        # r0 = screen_y = y + row
            emit(ASM.load_immediate(1, SCREEN_WIDTH))
            emit(ASM.mul(2, 0, 1))                # r2 = screen_y * width
            emit(ASM.add_reg(0, x_reg, 4))        # r0 = screen_x = x + col
            emit(ASM.add_reg(2, 2, 0))            # r2 = screen_y*width + screen_x
            emit(ASM.lsl_imm(2, 2, 1))            # * 2 bytes per pixel
            emit(ASM.load_immediate(1, VRAM_START))
            emit(ASM.add_reg(2, 2, 1))            # r2 = the pixel's VRAM address
            emit(ASM.store_halfword(8, 2))        # write the color
          end

        end
      end
    end
  end
end
