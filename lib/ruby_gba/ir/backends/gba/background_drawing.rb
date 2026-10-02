# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # THE CODE THAT PUTS BACKGROUNDS UP ON A TILED SCREEN, and changes them while the game
        # runs. The console draws each background layer itself, every frame, from a map in
        # its memory — a grid saying which tile goes in each cell — and a few registers saying
        # where the layer is scrolled to, or, for the layer that turns, how it is turned and
        # sized. So a background here is a map copied into place and those registers set;
        # after that, scrolling it, swapping its map, changing one cell or recolouring it is a
        # write or a copy, and nothing is redrawn.
        #
        # Which layer each background uses and where its tiles and map sit was settled before
        # any code existed (see {ScreenLayout}); this writes the code that carries it out.
        class BackgroundDrawing
          include Console::Hardware
          include EmitterCalls

          def initialize(emitter:, primitives:, lowering:, divide:, raster:, palette_tint:, uploads:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @divide = divide
            @raster = raster
            @palette_tint = palette_tint
            @uploads = uploads
            @layout = nil
          end

          attr_writer :layout

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
            @uploads.emit_dma_blob(BG_SHARED_PAL, BG_PALETTE, @layout.bg_shared.palette_units)  # colors -> palette memory
            @uploads.emit_dma_blob(BG_SHARED_CHAR, VRAM_START, @layout.bg_shared.tile_units)    # pictures -> video memory
            @palette_tint.emit_tint_state_reset # the table now holds the originals again
            # No scene's scenery is up yet. Written rather than assumed: the console makes
            # no promise about its memory at power-on, and a stale value would leave the
            # first scene's layers pointing at nothing. Written again on each entry into a
            # tiled screen too, which is right — the tiles have just been sent afresh, so
            # whatever was up is not any more.
            @primitives.store_word_immediate(0, @primitives.var_addr(Drawing::SCENE_SCENERY_STATE)) if scene_scenery?
          end

          def scene_scenery? = @layout.picture.scenery.any?(&:scene)

          # Point one layer's hardware at its data: DMA its map into its own screen block,
          # then set its control register (how its pixels are stored, where it counts its
          # tile numbers from, that screen block, and its paint-order priority) and reset
          # its scroll to the top-left. Drawn once — after that the hardware repaints the
          # whole layer every frame for free, and composites the layers by priority so
          # nearer ones sit in front.
          def emit_background_hardware(node)
            bg = @layout.backgrounds.fetch(node.name)
            return emit_affine_background_hardware(bg) if bg.affine

            @uploads.emit_dma_blob(bg.map, VRAM_START + (bg.screen_block * SCREENBLOCK_BYTES), bg.map_units)
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

            grid = bg.grid or raise_no_cells_to_change(node.name)
            entry = grid.cell_for(node.tile)
            fixed = [const_int(node.col), const_int(node.row)]
            return emit_fixed_tile_write(bg, grid, entry, *fixed) if fixed.all?

            emit_computed_tile_write(node, bg, grid, entry)
          end

          # A background that turns and resizes holds a tile number in each cell and nothing
          # else, so the framework has no way yet to change one cell of it while the game runs.
          def raise_no_cells_to_change(name)
            raise LoweringError,
                  "The background :#{name} turns and resizes, so one cell of it cannot be changed " \
                  "while the game runs. Its cells hold a tile number and nothing else. To fix this, " \
                  "stop turning this background, or change the whole map with show_map."
          end

          # A cell settled while the program was written: the address is worked out here,
          # in Ruby, and the console does one store.
          def emit_fixed_tile_write(bg, grid, entry, col, row)
            return unless grid.holds?(col, row)

            write_reg16(map_cell_address(bg, grid, col, row), entry)
          end

          # THE ADDRESS OF ONE CELL, and why it is not simply row times width.
          #
          # A map wider or taller than 32 cells is stored as several 32x32 SQUARES — left
          # then right, top pair before bottom pair — so a cell's place depends on which
          # quarter of the map it is in. 32 is a power of two, so that is shifts and masks
          # rather than division.
          def map_cell_address(bg, grid, col, row)
            quarter = ((row / MAP_CELLS) * (grid.cols / MAP_CELLS)) + (col / MAP_CELLS)
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

          def emit_computed_tile_write(node, bg, grid, entry)
            @lowering.value(node.col)
            emit(ASM.mov_reg(TILE_COL, ACC))
            @lowering.value(node.row)
            emit(ASM.mov_reg(TILE_ROW, ACC))

            done = gensym
            # One unsigned compare catches both ends: a negative coordinate reads as a
            # very large number, so anything outside 0...size fails the same test.
            emit(ASM.cmp_imm(TILE_COL, grid.cols))
            emit_branch(:bcond, done, cond: :hs)
            emit(ASM.cmp_imm(TILE_ROW, grid.rows))
            emit_branch(:bcond, done, cond: :hs)

            emit_cell_index(grid)
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
          def emit_cell_index(grid)
            emit(ASM.and_imm(TILE_ADDR, TILE_ROW, MAP_CELLS - 1))
            emit(ASM.lsl_imm(TILE_ADDR, TILE_ADDR, 5))
            emit(ASM.and_imm(TMP, TILE_COL, MAP_CELLS - 1))
            emit(ASM.orr_reg(TILE_ADDR, TILE_ADDR, TMP))
            return if grid.cols == MAP_CELLS && grid.rows == MAP_CELLS

            unless grid.rows == MAP_CELLS
              # The bottom half of a tall map is a whole square further on — two of them
              # when the map is also wide, since a row of squares comes first.
              emit(ASM.lsr_imm(TMP, TILE_ROW, 5))
              emit(ASM.lsl_imm(TMP, TMP, grid.cols == MAP_CELLS ? 10 : 11))
              emit(ASM.orr_reg(TILE_ADDR, TILE_ADDR, TMP))
            end
            return if grid.cols == MAP_CELLS

            emit(ASM.lsr_imm(TMP, TILE_COL, 5))
            emit(ASM.lsl_imm(TMP, TMP, 10))
            emit(ASM.orr_reg(TILE_ADDR, TILE_ADDR, TMP))
          end

          # HAND A BACKGROUND A WHOLE DIFFERENT MAP.
          #
          # A background's maps all live in the cartridge, laid end to end and all the same
          # size, so the map numbered N starts N strides along from the first. Copying one
          # into the layer's cells is then a single DMA — the same copy the boot upload
          # already does, at an address worked out rather than known.
          #
          # WHY THIS CAN BE ARITHMETIC RATHER THAN A TEST PER MAP, which is what makes a
          # game with hundreds of rooms affordable: the stride is settled while the program
          # is built, so a room number becomes an address in two instructions however many
          # rooms there are. A chain of comparisons would grow with the game.
          #
          # The stride is a power of two for a regular layer (a grid is 32 or 64 cells a
          # side, two bytes a cell) so the multiply is a shift; a rotate/scale layer's byte
          # map is a power of two too. Anything else multiplies, which is still one
          # instruction on this chip.
          #
          # WHEN it happens is decided above this: the framework puts the copy in the gap
          # between frames, on the frame the answer changed and no other (see
          # Builder#finalize_background_maps). Thousands of cells cannot go in while the
          # display is reading them, or the screen shows half of each map.
          # A map number naming no map leaves the cells as they are — the same policy
          # set_tile takes for a cell off the edge of the map, and for the same reason: a
          # number the game worked out can be anything, and a game should not need a test
          # around it to stay safe.
          def emit_show_map(node)
            bg = @layout.backgrounds[node.name]
            return if bg.nil? || bg.map_count < 2 # no tiled layer, or nothing else to show

            done = gensym
            emit_map_source(bg, node.which, done)
            emit(ASM.load_immediate(TMP, REG_DMA3SAD))
            emit(ASM.str(ACC, TMP)) # DMA source = that map in the cartridge
            store_word_immediate(map_vram_address(bg), REG_DMA3DAD)
            store_word_immediate(bg.map_units | DMA_ENABLE, REG_DMA3CNT) # go: 16-bit, both increment
            place_label(done)
          end

          # ACC = where the map numbered +which+ starts, or a jump to +done+ if it names no
          # map. A number settled while the program was written is worked out here, in Ruby;
          # one the game works out is checked and multiplied by the stride at run time.
          def emit_map_source(bg, which, done)
            fixed = const_int(which)
            return emit_fixed_map_source(bg, fixed, done) if fixed

            @lowering.value(which)
            # One unsigned compare catches both ends: a negative number reads as a very
            # large one, so anything outside 0...count fails the same test.
            emit(ASM.cmp_imm(ACC, bg.map_count))
            emit_branch(:bcond, done, cond: :hs)
            emit_map_stride(bg)
            emit_load_data_address(ACC, bg.map)
            emit(ASM.add_reg(ACC, ACC, TMP))
          end

          def emit_fixed_map_source(bg, fixed, done)
            return emit_branch(:b, done) unless fixed >= 0 && fixed < bg.map_count

            emit_load_data_address(ACC, bg.map)
            return if fixed.zero?

            emit(ASM.load_immediate(TMP, fixed * bg.map_bytes))
            emit(ASM.add_reg(ACC, ACC, TMP))
          end

          # TMP = how far along the blob this map starts. The stride is a power of two for
          # every grid the console offers, so this is a shift; the multiply is here for a
          # stride that is not, and costs one instruction either way on this chip.
          def emit_map_stride(bg)
            shift = Math.log2(bg.map_bytes).to_i
            if 2**shift == bg.map_bytes
              emit(ASM.lsl_imm(TMP, ACC, shift))
            else
              emit(ASM.load_immediate(TMP, bg.map_bytes))
              emit(ASM.mul(TMP, ACC, TMP))
            end
          end

          # DRAW A WHOLE LAYER FROM ANOTHER LIST OF COLOURS: put that list into the group of
          # sixteen its tiles read.
          #
          # Nothing about the layer itself is touched — not a cell, not a tile, not a pixel.
          # Every pixel on this console is a small NUMBER that picks a colour out of a shared
          # table, so changing the sixteen entries the layer's numbers pick from changes
          # every one of its pixels at once, and costs the same whatever is on screen. That
          # is why shafts of light can shimmer for the price of one copy.
          #
          # WHY THE GROUP IS THE LAYER'S OWN: this write lands in the table, where anything
          # else drawing from those sixteen would pick up the change too. The build gives a
          # layer that can be recoloured a group nobody else reads (see
          # PaletteBanks::Picture#keeps_to), so the write reaches this layer and nothing more.
          #
          # WHEN it happens is decided above this: the framework puts the copy in the gap
          # between frames, on the frame the answer changed and no other (see
          # Builder#finalize_background_colors). The whole screen is drawn through this table,
          # so a write while the display is reading shows the top of the screen in one set of
          # colours and the bottom in another.
          #
          # A number naming none of the lists hands over the layer's own colours, which sit
          # last in the blob — so that case is a conditional move rather than a branch, and
          # a counter that has run off the end looks right rather than wrong.
          def emit_background_colors(node)
            lists = @layout.backgrounds[node.name]&.colors
            return if lists.nil? # no tiled layer here, or nothing else to draw it with

            @lowering.value(node.which)
            # One unsigned compare catches both ends: a negative number reads as a very large
            # one, so anything outside 0...count fails the same test.
            emit(ASM.cmp_imm(ACC, lists.count))
            emit(ASM.mov_imm_cond(:hs, ACC, lists.count))
            emit(ASM.lsl_imm(TMP, ACC, lists.shift))
            emit_load_data_address(ACC, lists.blob)
            emit(ASM.add_reg(ACC, ACC, TMP))
            # Remembered as well as written, because a tint walks the whole table from the
            # cartridge and would otherwise put the colours the tiles were DRAWN in back over
            # these groups. See PaletteTint#emit_recolored_banks, which reads this.
            store_var(ACC, lists.at)
            # One list into each group the layer's tiles read, side by side in the version. The
            # groups themselves need not be side by side, so each is a copy of its own.
            lists.banks.each_with_index do |bank, at|
              unless at.zero?
                load_var(ACC, lists.at)
                emit(ASM.add_imm(ACC, ACC, at * COLOR_LIST_BYTES))
              end
              @palette_tint.emit_colors_into_bank(BG_PALETTE + (bank * COLOR_LIST_BYTES), COLOR_LIST_UNITS)
            end
          end

          # A group is sixteen colours, and a colour is two bytes — so a list is 32 bytes and
          # the list numbered N starts 32 * N along the blob, which is a shift rather than a
          # multiply (the same arithmetic #emit_map_stride does for a map).
          COLOR_LIST_UNITS = 16
          COLOR_LIST_BYTES = COLOR_LIST_UNITS * 2
          COLOR_LIST_SHIFT = 5

          # Where a background's cells live: its own screen block in video memory.
          def map_vram_address(bg) = VRAM_START + (bg.screen_block * SCREENBLOCK_BYTES)

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
          # genuinely entering it (Drawing#enter_affine_mode), and the plain single-mode boot
          # path (Drawing#emit_screen) — never from #emit_affine_background_hardware, which
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
          # matrix is set at genuine mode entry instead (Drawing#enter_affine_mode, or here at
          # boot for a single-mode program — see Drawing#emit_screen).
          def emit_affine_background_hardware(bg)
            @uploads.emit_dma_blob(bg.map, VRAM_START + (bg.screen_block * SCREENBLOCK_BYTES), bg.map_units)
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

          # Where the picture turns around is the program's to name and rides on the
          # statement that turns it (see IR::Nodes::AffineBackground); the middle of the
          # screen is only what it holds when nothing said otherwise.

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

            # WHEN this runs is decided above it, in the tree, rather than here: the
            # statement sits inside a test for the turn having moved since the display was
            # last told, itself inside a test for the owning scene being the live one (see
            # Builder#affine_write_if_changed). So reaching this is already the answer
            # to both questions, and what is left is the write.
            emit_bg_affine_matrix(node)
            emit_bg_affine_reference_point(node.around_x, node.around_y)
          end

          # The same numbers a turning hardware sprite reads (see
          # SpriteDrawing#emit_object_affine_matrix, whose steps this mirrors) — one sine-table lookup
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
          # SpriteDrawing#emit_object_scale_reciprocal) — a background always carries a size variable
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
          # 256ths — the background's own copy of SpriteDrawing#emit_scale_sine_and_cosine.
          def emit_bg_scale_sine_and_cosine
            load_var(4, BG_AFFINE_SCALE_RECIP)
            emit(ASM.mul(5, 2, 4))
            emit(ASM.asr_imm(2, 5, 8))
            emit(ASM.mul(5, 3, 4))
            emit(ASM.asr_imm(3, 5, 8))
          end

          # The matrix pivots on the layer's own top-left corner by itself — turn or
          # resize without this and the whole picture swings away from under the point it
          # is meant to turn around instead of turning in place. Moving the pivot to
          # (+px+, +py+) means telling the console the texture point that SHOULD land
          # there, worked backwards through the very matrix just written: for a screen
          # point this far from (0, 0), the matrix says how far that is from the
          # reference point in texture space, so read backwards, the reference point is
          # the pivot's texture position minus that offset. One multiply-and-subtract per
          # axis whatever the pivot is, so naming one costs nothing; the same shape a
          # turned sprite gets for free by centering its drawing box (see
          # SpriteDrawing#emit_draw_object_transformed) — a background has no box of its own to offset,
          # so this stands in for it.
          #
          # The point of the PICTURE that lands there is the same pair of numbers, which is
          # what makes a pivot free of side effects: at its drawn size, upright, the matrix
          # is the identity and the reference point comes out at nought wherever the pivot
          # is, so a background that is not turning lands in exactly the same place.
          def emit_bg_affine_reference_point(px, py)
            load_var(2, BG_AFFINE_PA)
            emit(ASM.load_immediate(3, px))
            emit(ASM.mul(4, 2, 3))                       # r4 = PA * px
            load_var(2, BG_AFFINE_PB)
            emit(ASM.load_immediate(3, py))
            emit(ASM.mul(5, 2, 3))                       # r5 = PB * py
            emit(ASM.add_reg(4, 4, 5))                   # r4 = PA*px + PB*py
            emit(ASM.load_immediate(ACC, px * Affine::ONE_TH))
            emit(ASM.sub_reg(ACC, ACC, 4))
            store_word_acc(REG_BG2X)

            load_var(2, BG_AFFINE_PC)
            emit(ASM.load_immediate(3, px))
            emit(ASM.mul(4, 2, 3))                       # r4 = PC * px
            load_var(2, BG_AFFINE_PD)
            emit(ASM.load_immediate(3, py))
            emit(ASM.mul(5, 2, 3))                       # r5 = PD * py
            emit(ASM.add_reg(4, 4, 5))                   # r4 = PC*px + PD*py
            emit(ASM.load_immediate(ACC, py * Affine::ONE_TH))
            emit(ASM.sub_reg(ACC, ACC, 4))
            store_word_acc(REG_BG2Y)
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
        end
      end
    end
  end
end
