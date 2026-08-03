# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Direct-color (Mode 3) drawing, and the screen-mode/page management around it.
        module Drawing
          include Constants

          # Turn the screen on by writing the chosen mode to the display-control
          # register. Until this runs the screen stays black.
          #
          # In a program that switches the hardware per scene — some scene double-
          # buffered, or crossing the bitmap/tiled boundary — the screen mode is managed
          # for the whole program by the boot setup and each scene's mode-switch
          # preamble, so a `screen` node is only a build-time declaration of a scene's
          # mode and emits nothing here. Otherwise it's the plain one-time register write.
          def emit_screen(node)
            return if @manage_modes

            mode = node[:mode]
            value = if mode == :tiled
                      # Tile mode turns on exactly the background layers the program declared,
                      # so a stack of two or three composites; a single background is just BG0.
                      MODE_0 | tiled_bg_enable_bits
                    elsif mode.is_a?(Integer)
                      mode
                    else
                      SCREEN_MODES.fetch(mode) do
                        raise LoweringError, "the GBA backend cannot lower screen mode #{mode.inspect} yet"
                      end
                    end
            # Turn the sprite layer on alongside the chosen mode when the program has
            # sprites, and pick the simple 1D tile arrangement they're packed for.
            value |= OBJ_ENABLE | OBJ_1D_MAP if @has_objects
            write_reg16(REG_DISPCNT, value)
          end

          # The DISPCNT enable bit per layer, and the OR of them for the layers this
          # program declared — at least BG0, so a tiled screen always has one layer on.
          BG_ENABLES = [BG0_ENABLE, BG1_ENABLE, BG2_ENABLE, BG3_ENABLE].freeze
          def tiled_bg_enable_bits
            layers = [@backgrounds.size, 1].max
            BG_ENABLES.first(layers).reduce(0, :|)
          end

          # One-time boot for a program that switches the hardware per scene: put the
          # display in the default scene's mode. A buffered program also uploads its
          # color table here (palette memory survives mode switches), then starts by
          # showing page 0 and drawing into page 1; a tiled default brings up the tile
          # layers and sprites; a direct default is the plain Mode 3 write.
          def emit_boot_screen
            upload_palette if @any_buffered # the palette exists only for the buffered path
            case @default_mode
            when :tiled then enter_tiled_mode
            when :buffered then enter_buffered_mode
            else enter_direct_mode
            end
          end

          # Switch the hardware into double-buffered (Mode 4): remember the live DISPCNT
          # so a flip is a cheap bit-toggle, draw into page 1 first, show page 0, and
          # record that buffered is now the live mode.
          def enter_buffered_mode
            base = MODE_4 | BG2_ENABLE
            store_word_immediate(base, var_addr(DISPCNT_STATE))
            store_word_immediate(PAGE1, var_addr(BACKBUF))
            write_reg16(REG_DISPCNT, base)
            store_word_immediate(MODE_BUFFERED, var_addr(MODE_STATE))
          end

          # Switch the hardware into direct-color (Mode 3) and record it as live. Writing
          # the whole register also turns the tile and sprite layers off, so nothing a
          # tiled scene left on screen bleeds under the bitmap one — only BG2 (the
          # framebuffer) shows, which the bitmap scene redraws.
          def enter_direct_mode
            write_reg16(REG_DISPCNT, MODE_3 | BG2_ENABLE)
            store_word_immediate(MODE_DIRECT, var_addr(MODE_STATE))
          end

          # Switch the hardware into tiled mode (Mode 0). Because the bitmap framebuffer
          # and the tiles share video memory, a bitmap scene overwrites the tile data, so
          # the tile pictures/colors and sprite tiles are (re)uploaded here on entry —
          # cheap, and only on the actual switch. Then turn on the declared background
          # layers (plus the sprite layer if the game has sprites) and record it live.
          # Each background's map and control register are re-set by its own node in the
          # scene body, which runs right after this preamble.
          def enter_tiled_mode
            emit_boot_backgrounds if @tiled && !@backgrounds.empty? # shared BG palette + tile pictures
            emit_boot_objects if @has_objects                       # sprite palette + tiles, and clear OAM
            value = MODE_0 | tiled_bg_enable_bits
            value |= OBJ_ENABLE | OBJ_1D_MAP if @has_objects
            write_reg16(REG_DISPCNT, value)
            store_word_immediate(MODE_TILED, var_addr(MODE_STATE))
          end

          # Emitted at the top of each scene when a program switches the hardware per
          # scene: switch into this scene's mode, but only if it isn't already there (a
          # transition). Steady frames — the same scene running again — cost just the
          # compare, and a buffered scene's DISPCNT is left to the page flip.
          def emit_scene_preamble(name)
            mode = @func_mode[name]
            load_var(ACC, MODE_STATE)
            emit(ASM.cmp_imm(ACC, mode_state_marker(mode)))
            skip = gensym
            emit_branch(:bcond, skip, cond: :eq) # already in this mode? nothing to do
            enter_mode(mode)
            place_label(skip)
          end

          # A scene's resolved mode -> the marker stored in MODE_STATE, and the routine
          # that switches the hardware into it. Kept as two small methods (not a load-time
          # table) so they resolve the MODE_* constants at call time.
          def mode_state_marker(mode)
            case mode
            when :tiled then MODE_TILED
            when :buffered then MODE_BUFFERED
            else MODE_DIRECT
            end
          end

          def enter_mode(mode)
            case mode
            when :tiled then enter_tiled_mode
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
            store_word_immediate(@palette.size | DMA_ENABLE, REG_DMA3CNT) # go: 16-bit, both increment
          end

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
            return emit_pixel_buffered(node) if @lower_mode == :buffered

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
            return emit_fill_rect_buffered(node) if @lower_mode == :buffered

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
            return emit_clear_screen_buffered(node) if @lower_mode == :buffered

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
            return emit_fill_rect_buffered(node) if @lower_mode == :buffered

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
            return emit_draw_rect_at_buffered(node) if @lower_mode == :buffered

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
          # transparent pixels can be skipped. Either way the draw is clipped to the
          # screen at run time — a bitmap pushed partway off an edge draws only its
          # visible part, with nothing written past the framebuffer.
          def emit_blit(node)
            blit_unsupported_in_buffered! if @lower_mode == :buffered
            bmp = @bitmaps.fetch(node[:name]) do
              raise LoweringError, "blit of undefined image #{node[:name].inspect}"
            end
            bmp[:transparent] ? emit_blit_transparent(node, bmp) : emit_blit_opaque(node, bmp)
          end

          # Opaque bitmap: stream each row straight from the cartridge into VRAM by
          # DMA — a run-time-positioned rectangle copy from a ROM buffer onto the
          # screen. The shared row engine below does the clipping.
          def emit_blit_opaque(node, bmp)
            emit_rect_row_dma(node[:x], node[:y], bmp[:width], bmp[:height], node[:name], vram: :dest)
          end

          # Draw a tiled background. In tile mode the console draws the whole layer
          # from data in video memory, so it's uploaded once (emit_background_hardware).
          # In bitmap mode there's no tile hardware, so each cell is stamped with the
          # blit path instead — correct, just a copy per cell.
          def emit_background(node)
            @tiled ? emit_background_hardware(node) : emit_background_blits(node)
          end

          # The per-layer control and scroll registers, indexed by BG number (0..3), so a
          # layer configures and scrolls its own hardware layer.
          BG_CNT_REGS  = [REG_BG0CNT, REG_BG1CNT, REG_BG2CNT, REG_BG3CNT].freeze
          BG_HOFS_REGS = [REG_BG0HOFS, REG_BG1HOFS, REG_BG2HOFS, REG_BG3HOFS].freeze
          BG_VOFS_REGS = [REG_BG0VOFS, REG_BG1VOFS, REG_BG2VOFS, REG_BG3VOFS].freeze

          # Upload the one palette and one character block every layer shares, once at
          # boot — the tile pictures go to character block 0 (the start of video memory),
          # the colors to background palette memory. Each layer's map and control register
          # are set later, when its background node is reached (emit_background_hardware).
          def emit_boot_backgrounds
            emit_dma_blob(BG_SHARED_PAL, BG_PALETTE, @bg_shared[:pal_units])   # colors -> palette memory
            emit_dma_blob(BG_SHARED_CHAR, VRAM_START, @bg_shared[:char_units]) # tile pictures -> char block 0
          end

          # Point one layer's hardware at its data: DMA its map into its own screen block,
          # then set its control register (256-color, char block 0, that screen block, and
          # its paint-order priority) and reset its scroll to the top-left. Drawn once —
          # after that the hardware repaints the whole layer every frame for free, and
          # composites the layers by priority so nearer ones sit in front.
          def emit_background_hardware(node)
            bg = @backgrounds.fetch(node[:name])
            emit_dma_blob(bg[:map], VRAM_START + (bg[:screen_block] * SCREENBLOCK_BYTES), bg[:map_units])
            write_reg16(BG_CNT_REGS[bg[:bg]], bg[:priority] | BG_256_COLOR | (bg[:screen_block] << 8))
            write_reg16(BG_HOFS_REGS[bg[:bg]], 0) # start unscrolled
            write_reg16(BG_VOFS_REGS[bg[:bg]], 0)
          end

          # Scroll one layer: write the window's top-left offset into that layer's scroll
          # registers. The tile hardware does the rest — it draws the layer starting at
          # that offset and wraps the map around, so a moving offset scrolls the whole
          # layer for free (no redrawing). Two layers scrolled at different speeds give
          # parallax. The offset is evaluated at run time from the game's scroll variables.
          def emit_scroll_background(node)
            # In tile mode this names a real layer; outside it (a bitmap-mode program that
            # still declares a background) there's no tiled layer, so fall back to BG0 —
            # the scroll registers do nothing when that layer isn't on, matching the
            # interpreter's harmless handling.
            bg_num = (@backgrounds[node[:name]] || {})[:bg] || 0
            eval_value(node[:x])          # r0 = scroll x (pixels)
            store_halfword_acc(BG_HOFS_REGS[bg_num])
            eval_value(node[:y])          # r0 = scroll y
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
            return @blob_codecs[blob_name] if @blob_codecs.key?(blob_name)

            raw = @data_blobs[blob_name]
            codec, blob = BiosCompress.best(raw)
            unless codec == :none
              @blob_raw_bytes[blob_name] = raw.bytesize # remember the before size for the savings line
              @data_blobs[blob_name] = blob
            end
            @blob_codecs[blob_name] = codec
          end

          # --- sprites (hardware-composited moving objects) ---

          # Where a sprite's tiles live: the object tile area of video memory, and the
          # sprite table itself. In tile mode the console draws sprites from tiles kept
          # in this region, separate from the background's, so the two never collide.
          OBJ_TILE_BASE = VRAM_START + 0x10000 # object tiles start 64KB into video memory
          OBJ_HIDDEN_ATTR0 = 0x0200            # attr0 marking a sprite-table slot unused
          OBJ_HIDDEN_WORD  = 0x02000200        # two hidden attr0s, for a fast table clear

          # One-time sprite setup at boot: blank the whole sprite table (its memory is
          # garbage at power-on, so an untouched slot would show a stray sprite), upload
          # the one shared color table every sprite indexes into, then each sprite's
          # tiles into video memory. After this the per-frame draw just points slots at
          # these tiles.
          def emit_boot_objects
            clear_object_table
            emit_dma_blob(@obj_palette_blob, OBJ_PALETTE, @obj_palette_units) # the shared sprite palette, once
            @objects.each_value do |obj|
              emit_dma_blob(obj[:tiles], OBJ_TILE_BASE + (obj[:tile_index] * 32), obj[:tile_units] * 16) # tiles -> sprite memory
            end
          end

          # Fill the sprite table with the "unused slot" marker so no leftover memory
          # shows as a sprite. One source-fixed DMA of a word that is two hidden slots.
          def clear_object_table
            scratch = var_addr(:_oam_clear)
            store_word_immediate(OBJ_HIDDEN_WORD, scratch)
            store_word_immediate(scratch, REG_DMA3SAD)
            store_word_immediate(OAM_START, REG_DMA3DAD)
            store_word_immediate(dma_fill_control(OAM_SIZE / 4), REG_DMA3CNT)
          end

          # Draw this frame's sprites: write each named object's current position and
          # visibility into its slot in the sprite table. Runs right after the vblank
          # (when changing the table is safe), so a moving sprite lands at its new spot
          # with no tearing. The console composites the sprites over the background for
          # free — there's nothing to erase, unlike a software sprite.
          def emit_present_objects(node)
            node[:names].each { |name| emit_present_object(@objects.fetch(name)) }
          end

          # Write one sprite's three table entries from its live x/y/active variables.
          # A hidden sprite (active == 0) gets the "unused slot" marker instead, so it
          # vanishes; a shown one gets its position, size, and tiles.
          def emit_present_object(obj)
            base = OAM_START + (obj[:slot] * 8)

            eval_value(obj[:active])
            emit(ASM.cmp_imm(ACC, 0))
            draw = gensym
            done = gensym
            emit_branch(:bcond, draw, cond: :ne)
            write_reg16(base, OBJ_HIDDEN_ATTR0) # active == 0: mark the slot unused
            emit_branch(:b, done)

            place_label(draw)
            # attr0 = (y & 0xFF) | shape + 256-color flag
            eval_value(obj[:y])
            mask_into_acc(0xFF)
            orr_acc(obj[:attr0_base])
            store_halfword_acc(base)
            # attr1 = (x & 0x1FF) | size
            eval_value(obj[:x])
            mask_into_acc(0x1FF)
            orr_acc(obj[:attr1_base])
            store_halfword_acc(base + 2)
            # attr2 = which tiles to draw = this sprite's base tile + pose * stride
            # (palette bank/priority left at 0). A fixed pose folds to a constant.
            emit_object_tile_number(obj, base + 4)
            place_label(done)
          end

          # Write a sprite's tile number (attr2) for this frame. The sprite's poses sit
          # back to back in tile memory, so the pose it's showing is base + pose*stride.
          # A constant pose (the common single-pose sprite) folds to a plain write; a
          # variable pose (facing / animation) is computed at run time.
          def emit_object_tile_number(obj, attr2_addr)
            fixed = const_int(obj[:pose])
            if fixed
              write_reg16(attr2_addr, obj[:tile_index] + (fixed * obj[:per_pose]))
            else
              eval_value(obj[:pose])                          # r0 = pose index
              emit(ASM.load_immediate(TMP, obj[:per_pose]))   # r1 = stride between poses
              emit(ASM.mul(2, ACC, TMP))                      # r2 = pose * stride (rd must differ from rm)
              emit_add_const(ACC, 2, obj[:tile_index], TMP)   # r0 = r2 + base tile
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

          # Store the low halfword of r0 to a fixed address.
          def store_halfword_acc(address)
            emit(ASM.load_immediate(TMP, address))
            emit(ASM.store_halfword(ACC, TMP))
          end

          # Bitmap-mode background: no tile hardware, so stamp each non-empty cell with
          # the shared blit path — a positioned copy of the tile image onto the screen.
          def emit_background_blits(node)
            tiles = node[:tiles]
            tile_w = node[:tile_w]
            tile_h = node[:tile_h]
            node[:map].each_with_index do |row, r|
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
            node[:poses].each_with_index do |name, k|
              emit_statement(Build.if_(Build.binop(:==, node[:index], Build.int(k)),
                                       Build.blit(name, node[:x], node[:y])))
            end
          end

          # Save the screen patch under a moving object into its RAM backing store:
          # read the screen (VRAM) INTO the buffer. Same row engine as a blit, run in
          # the other direction.
          def emit_save_region(node)
            backing_region_unsupported_in_buffered! if @lower_mode == :buffered
            info = backing_info(node[:buffer])
            emit_rect_row_dma(node[:x], node[:y], info[:width], info[:height], info[:base], vram: :src)
          end

          # Put a saved patch back on the screen: stream the RAM buffer INTO VRAM, just
          # like a blit but sourced from the backing store instead of a ROM image.
          def emit_restore_region(node)
            backing_region_unsupported_in_buffered! if @lower_mode == :buffered
            info = backing_info(node[:buffer])
            emit_rect_row_dma(node[:x], node[:y], info[:width], info[:height], info[:base], vram: :dest)
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
            eval_value(x_node)
            emit(ASM.mov_reg(x_reg, ACC))
            eval_value(y_node)
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
            width = bmp[:width]
            colors = bmp[:pixels].unpack("v*")

            x_reg = 2
            y_reg = 3
            eval_value(node[:x])
            emit(ASM.mov_reg(x_reg, ACC))
            eval_value(node[:y])
            emit(ASM.mov_reg(y_reg, ACC))

            bmp[:height].times do |row|
              lit = width.times.reject { |col| colors[(row * width) + col] == bmp[:transparent] }
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

          # rd = rn + imm. A small immediate rides directly in the ADD; a larger one
          # (a wide bitmap's row offset, say) is loaded into +scratch+ first, since
          # ARM can only fold an 8-bit rotated immediate into the instruction.
          def emit_add_const(rd, rn, imm, scratch)
            if imm.zero?
              emit(ASM.mov_reg(rd, rn)) unless rd == rn
            elsif ASM.encode_rotated_immediate(imm)
              emit(ASM.add_imm(rd, rn, imm))
            else
              emit(ASM.load_immediate(scratch, imm))
              emit(ASM.add_reg(rd, rn, scratch))
            end
          end

          # rd = rn & imm — the ring-wrap mask. A mask that fits an 8-bit rotated
          # immediate (capacity up to 256) rides directly in the AND; a wider one is
          # loaded into +scratch+ first, since ARM can't fold it into the instruction.
          def emit_and_const(rd, rn, imm, scratch)
            if ASM.encode_rotated_immediate(imm)
              emit(ASM.and_imm(rd, rn, imm))
            else
              emit(ASM.load_immediate(scratch, imm))
              emit(ASM.and_reg(rd, rn, scratch))
            end
          end

          # Draw a line of text with the built-in bitmap font. The color loads once,
          # then every set pixel of every glyph is a single halfword store at its
          # fixed VRAM address; off-screen pixels are dropped. Positions are constant.
          def emit_draw_text(node)
            return emit_draw_text_buffered(node) if @lower_mode == :buffered

            x, y = constant_ints!(node, :x, :y)
            emit(ASM.load_immediate(ACC, Color.resolve(node[:color])))

            Fonts.get(node[:font]).each_pixel(node[:text]) do |dx, dy|
              px = x + dx
              py = y + dy
              next unless in_bounds?(px, py)

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
            font = Fonts.get(node[:font])
            x = const_int(node[:x])
            y = const_int(node[:y])
            digit_w = uniform_digit_width(font)
            if x && y && digit_w && digit_cell_on_screen?(x, y, digit_w, font.height)
              if @lower_mode == :buffered
                emit_draw_digit_data_buffered(node, font, digit_w, x, y)
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
              emit_statement(Build.if_(Build.binop(:==, node[:value], Build.int(k)),
                                       Build.draw_text(k.to_s, node[:x], node[:y], node[:color], font: node[:font])))
            end
          end

          # Render one run-time digit from an embedded glyph table (direct color). Walk
          # the chosen glyph and write the color straight to VRAM at each lit pixel — the
          # shared glyph loop does the walking; this supplies the direct-color plot.
          def emit_draw_digit_data(node, font, width, x, y)
            color = Color.resolve(node[:color])
            emit_digit_glyph_loop(node, font, width) do |phase|
              case phase
              when :hold then emit(ASM.load_immediate(8, color)) # r8 = the fill color, held
              when :plot then emit_plot_digit_pixel(x, y)
              end
            end
          end

          # Walk the ten-glyph table for the run-time digit, calling +block+ once per set
          # pixel to plot it — the shared skeleton behind the direct and tear-free digit
          # renders. The ten glyphs live in ROM as row bytes (glyph d at d*height, one
          # byte per row, the low +width+ bits being that row, leftmost = the top bit).
          # +width+ is the digits' shared width (the caller checked all ten match) and
          # the cell is on-screen, so the walk needs no clipping.
          #
          # The block is called with :hold once — after the glyph pointer is set up, to
          # load any register the plot keeps for the whole glyph — and with :plot for
          # each lit pixel, when r5 (row) and r4 (column) are live. Registers held across
          # the loop: r4 column, r5 row, r6 the glyph's row pointer, r7 the current row
          # byte; r0–r3 are per-pixel scratch and the plot owns r8 up.
          def emit_digit_glyph_loop(node, font, width)
            table = ensure_digit_table(node[:font], font)
            top_bit = 1 << (width - 1)

            eval_value(node[:value])              # r0 = the digit (0..9)
            emit_load_data_address(1, table)      # r1 = the glyph table's ROM address
            emit(ASM.load_immediate(2, font.height))
            emit(ASM.mul(3, 0, 2))                # r3 = digit * height (its row offset)
            emit(ASM.add_reg(6, 1, 3))            # r6 = &glyph[digit], row 0
            yield :hold                           # the plot loads its per-glyph register(s)
            emit(ASM.load_immediate(5, 0))        # r5 = row = 0

            row_loop = gensym
            place_label(row_loop)
            emit(ASM.ldrb_offset(7, 6, 0))        # r7 = this row's byte
            emit(ASM.load_immediate(4, 0))        # r4 = col = 0

            col_loop = gensym
            place_label(col_loop)
            next_col = gensym
            emit(ASM.tst_imm(7, top_bit))         # is the leftmost remaining column lit?
            emit_branch(:bcond, next_col, cond: :eq)
            yield :plot                           # yes: stamp it
            place_label(next_col)
            emit(ASM.lsl_imm(7, 7, 1))            # shift the next column into the top bit
            emit(ASM.add_imm(4, 4, 1))
            emit(ASM.cmp_imm(4, width))
            emit_branch(:bcond, col_loop, cond: :lt)

            emit(ASM.add_imm(6, 6, 1))            # advance to the next row's byte
            emit(ASM.add_imm(5, 5, 1))
            emit(ASM.cmp_imm(5, font.height))
            emit_branch(:bcond, row_loop, cond: :lt)
          end

          # Stamp the current glyph pixel: screen = VRAM + ((y+row)*W + (x+col))*2, in
          # the held color (r8). x/y are the constant cell origin; r5/r4 are the live
          # row/col. Uses r0–r3 as scratch and leaves the loop registers alone.
          def emit_plot_digit_pixel(x, y)
            emit_add_const(0, 5, y, 1)            # r0 = screen_y = y + row
            emit(ASM.load_immediate(1, SCREEN_WIDTH))
            emit(ASM.mul(2, 0, 1))                # r2 = screen_y * width
            emit_add_const(0, 4, x, 1)            # r0 = screen_x = x + col
            emit(ASM.add_reg(2, 2, 0))            # r2 = screen_y*width + screen_x
            emit(ASM.lsl_imm(2, 2, 1))            # * 2 bytes per pixel
            emit(ASM.load_immediate(1, VRAM_START))
            emit(ASM.add_reg(2, 2, 1))            # r2 = the pixel's VRAM address
            emit(ASM.store_halfword(8, 2))        # write the color
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

          # True when the whole width×height digit cell at (x, y) fits on-screen, so the
          # data-driven loop can skip per-pixel clipping.
          def digit_cell_on_screen?(x, y, width, height)
            x >= 0 && y >= 0 && (x + width) <= SCREEN_WIDTH && (y + height) <= SCREEN_HEIGHT
          end

          # Embed a font's ten digit glyphs as a ROM blob once, returning its blob name.
          # Laid out as glyph 0's +height+ row bytes, then glyph 1's, and so on, so digit
          # d begins at d*height. A digit the font happens to lack contributes blank rows
          # (it simply draws nothing), matching the fan-out's skip.
          def ensure_digit_table(name, font)
            blob = :"__digits_#{name}"
            unless @data_blobs.key?(blob)
              bytes = (0..9).flat_map { |d| font.glyph(d.to_s) || Array.new(font.height, 0) }
              @data_blobs[blob] = bytes.pack("C*")
            end
            blob
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
        end
      end
    end
  end
end
