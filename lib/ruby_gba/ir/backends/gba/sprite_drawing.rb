# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # THE CODE THAT PUTS SPRITES ON A TILED SCREEN. The console draws sprites itself,
        # every frame, out of a table of 128 rows it keeps in its own memory: each row says
        # where a sprite stands, which of the pictures in sprite memory it shows, and how.
        # So drawing a sprite here means writing its row — once for one that never moves,
        # every frame for one that does — and, for a sprite whose pictures do not all fit,
        # copying the frame it is showing into its room first.
        #
        # Where each sprite's pictures and rows ARE was settled before any code existed
        # (see {ScreenLayout}); this reads that plan and writes the code that carries it out.
        class SpriteDrawing
          include Console::Hardware
          include EmitterCalls

          def initialize(emitter:, primitives:, lowering:, divide:, framebuffer:, palette_tint:, uploads:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @divide = divide
            @framebuffer = framebuffer
            @palette_tint = palette_tint
            @uploads = uploads
            @layout = nil
          end

          attr_writer :layout

          def placed_fade = @layout.placed_fade

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
            @primitives.store_word_immediate(0, @primitives.var_addr(Drawing::SCENE_ART_STATE)) if @layout.scene_art.any?
            # The table has just been wiped, so the sprites nobody moves are gone from it too
            # and have to be written again. This runs on a change of screen as well as at
            # boot, which is the case that would otherwise leave a title screen blank.
            forget_still_objects
            @uploads.emit_dma_blob(@layout.obj_palette_blob, OBJ_PALETTE, @layout.obj_palette_units) # the shared sprite palette, once
            @palette_tint.emit_obj_table_is(@layout.obj_palette_blob) # ...which is the one a tint walks until a scene sends its own
            @layout.objects.each_value do |obj|
              # A sprite showing the same pictures as one already uploaded points at
              # those, so there is nothing of its own to send. A sprite that belongs to a
              # scene is sent when that scene takes over, not here (see
              # Drawing#emit_scene_art_upload), since scenes share the room above this.
              next if obj.tiles.nil? || obj.scene

              @uploads.emit_dma_blob(obj.tiles, OBJ_TILE_BASE + (obj.tile_index * 32), obj.tile_units * 16) # tiles -> sprite memory
            end
            forget_frames_in_rooms(@layout.objects.each_value)
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
            return if placed_fade.none?

            write_reg16(REG_WINOUT, WIN_ALL_LAYERS | WIN_EFFECT | (WIN_ALL_LAYERS << WINOUT_OBJ_SHIFT))
            store_word_immediate(placed_fade.line, var_addr(EFFECT_LINE))
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

          # The routine that writes the sprites nothing moves, and the two things remembered
          # about it: WHETHER those sprites are in the console's table at all, and what the
          # variable that decides them held when they were put there.
          #
          # TWO WORDS AND NOT ONE, which looks like one too many and is not. A single word
          # holding "the value we last wrote for" needs some reading of it to mean "nothing
          # written yet", and every value a word can hold is one a program is free to number a
          # scene with — a game whose first state is -1 would then find the table already
          # right at power-on and leave its title screen blank for ever, with nothing in the
          # program to point at. The separate yes-or-no cannot be confused with a scene, and
          # costs one load and one compare on a frame.
          STILL_ROUTINE = Messages::MadeNames.make(:still_sprites)
          STILL_UP = :__still_up
          STILL_STATE = :__still_state

          # What is remembered in a program with no scenes, which has no variable to watch
          # because nothing at all can change once its sprites are up.
          NOTHING_TO_WATCH = 0

          # Draw this frame's sprites: write each named object's current position and
          # visibility into its slot in the sprite table. Runs right after the vblank
          # (when changing the table is safe), so a moving sprite lands at its new spot
          # with no tearing. The console composites the sprites over the background for
          # free — there's nothing to erase, unlike a software sprite.
          def emit_present_objects(node)
            by_scene = @layout.scene_sprites
            write_object_table(node.names - @layout.movement.still - by_scene.flat_map(&:names))
            by_scene.each { |group| emit_scene_sprites(group) }
            emit_settle_still_objects
          end

          # The routine that writes one scene's moving sprites (see GBA#prepare_scene_sprites).
          # Named for the scene, so a report and a measured profile can say whose it is.
          def self.sprites_routine(scene) = Messages::MadeNames.make(:scene_sprites, scene: Modes.friendly_name(scene))

          # Whether that routine last wrote its sprites as SHOWN — its scene up.
          def self.sprites_shown(scene) = Messages::MadeNames.make(:scene_sprites_shown, scene: Modes.friendly_name(scene))

          # WRITE ONE SCENE'S MOVING SPRITES, on its frames and on the one frame after it goes.
          #
          # While the scene is up its sprites are written every frame, as they always were. The
          # frame it goes they are written once more, and each finds its scene no longer up and
          # hides itself, exactly as it did when the frame wrote it. After that nothing writes
          # them, and nothing needs to: a row stays as it was last written, and hidden is what it
          # has to be until the scene comes back. So the frame asks one question per scene —
          # "is it up, or was it up last time?" — and calls the routine only when either holds.
          #
          # Remembering "was it up" can never leave a sprite showing: it is set to no only by the
          # write that hid them. At power-on it can hold anything, and the worst a stray yes does
          # is hide sprites that were already hidden, since the table has just been cleared.
          def emit_scene_sprites(group)
            shown = self.class.sprites_shown(group.scene)
            skip = gensym
            @lowering.value(Build.binop(:==, Build.var_ref(group.state), Build.int(group.value))) # r0 = up now
            load_var(TMP, shown)
            emit(ASM.orr_reg(TMP, TMP, ACC))
            emit(ASM.cmp_imm(TMP, 0))
            emit_branch(:bcond, skip, cond: :eq) # not up, and hidden already
            store_var(ACC, shown)
            @lowering.statement(Build.call(self.class.sprites_routine(group.scene)))
            place_label(skip)
          end

          # Write these sprites' rows of the console's table. Called twice over: by the frame,
          # for the sprites it moves, and by a routine of its own for the sprites nothing
          # moves (see GBA#prepare_still_objects, and Functions#define_generated_func, which is what makes that
          # routine).
          #
          # THE SPLIT IS THERE TO KEEP THE FRAME'S OWN CODE SMALL. The console re-reads this
          # table every frame and a row of it stays exactly as it was last written, so a
          # sprite the program never moves is already right — but the code to write it again
          # is some forty instructions apiece, and it sits in the body the framework keeps in
          # the console's quick memory. A picture too big for one of the console's objects is
          # drawn as several, so a title screen's lettering is a dozen of them and more; the
          # whole of that was code saying that nothing had changed.
          def write_object_table(names)
            names.each { |name| emit_present_object(@layout.objects.fetch(name), twin: placed_fade.twin_for(name)) }
          end

          # WRITE THE STILL SPRITES, ON THE FRAMES WHERE THAT CAN MATTER AND NO OTHERS.
          #
          # Everything about such a sprite is settled except whether it is SHOWN, and that is
          # decided by one variable: the one the program picks its scenes with, since a sprite
          # declared inside a scene is on screen exactly while that scene is. So the whole
          # question "is the sprite table still right?" is "are they in it, and was it that
          # variable's doing?" — a handful of instructions for every still sprite in the game
          # together, against a table write each.
          #
          # A game with no scenes has no such variable, so it remembers a fixed number and the
          # routine runs on the first frame and never again.
          def emit_settle_still_objects
            return if @layout.movement.still.empty?

            watching = @layout.movement.watching
            watching ? load_var(ACC, watching) : emit(ASM.load_immediate(ACC, NOTHING_TO_WATCH))
            settled = gensym
            write = gensym
            load_var(TMP, STILL_STATE)
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, write, cond: :ne) # a different scene: they need writing again
            load_var(TMP, STILL_UP)
            emit(ASM.cmp_imm(TMP, 0))
            emit_branch(:bcond, settled, cond: :ne) # ...and they are in the table already
            place_label(write)
            store_var(ACC, STILL_STATE)
            emit(ASM.load_immediate(TMP, 1))
            store_var(TMP, STILL_UP)
            @lowering.statement(Build.call(STILL_ROUTINE))
            place_label(settled)
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
          # of where the fade is sitting. See PlacedFade.
          #
          # A picture too big for one object is drawn as SEVERAL, standing shoulder to
          # shoulder — so this walks the pieces, and a sprite the console can draw in one
          # go is simply the case where there is one of them. The pieces take a run of
          # slots from the sprite's own, so the whole thing keeps one place in the stack.
          def emit_present_object(obj, twin: nil)
            @lowering.value(obj.active)
            emit(ASM.cmp_imm(ACC, 0))
            draw = gensym
            done = gensym
            emit_branch(:bcond, draw, cond: :ne)
            obj.pieces.times do |piece|
              write_reg16(oam_slot(obj.slot, piece), OBJ_HIDDEN_ATTR0) # active == 0: mark it unused
              write_reg16(oam_slot(twin.slot, piece), OBJ_HIDDEN_ATTR0) if twin # ...and its window
            end
            emit_branch(:b, done)

            place_label(draw)
            emit_hold_object_colors(obj) if obj.recolor_banks
            emit_send_object_frame(obj) if obj.frames
            # Worked out once for the whole sprite when it is drawn as several objects:
            # every piece stands at the same place and reads it back from there.
            emit_hold_object_position(obj) if obj.pieces > 1
            obj.pieces.times do |piece|
              base = oam_slot(obj.slot, piece)
              mirror = twin && oam_slot(twin.slot, piece)
              if obj.transformed
                emit_draw_object_transformed(obj, base, mirror)
              else
                emit_draw_object_upright(obj, base, mirror, piece)
              end
            end
            emit_window_gate(twin, obj.pieces) if twin
            place_label(done)
          end

          def oam_slot(first, piece) = OAM_START + ((first + piece) * 8)

          # Where the bank a sprite is drawn from this frame is held while its pieces are
          # written. One variable serves every sprite, since each is done before the next.
          OBJ_COLORS_BANK = :__obj_colors_bank

          # WHICH COLOURS A SPRITE DRAWS WITH THIS FRAME, for one that can be drawn with other
          # lists. A pixel of a small-storage sprite is a place in a bank of sixteen, and the
          # bank is named in the third word of the sprite's table entry — so naming another
          # bank there is all it takes, and the picture itself is never touched. Worked out
          # once, before the pieces, and ORed into each of their third words; since that word
          # is written with the position and the pose, the colours change on the same frame.
          #
          # A number past the last list, or below 0 (which compared unsigned is past it too),
          # is the sprite's own, kept as the table's last entry.
          def emit_hold_object_colors(obj)
            banks = obj.recolor_banks
            @lowering.value(obj.recolor)
            emit(ASM.cmp_imm(ACC, banks.own))
            emit(ASM.mov_imm_cond(:hs, ACC, banks.own))
            emit_load_data_address(TMP, banks.table)
            emit(ASM.ldr_reg_lsl(ACC, TMP, ACC, 2))
            store_var(ACC, OBJ_COLORS_BANK)
          end

          # OR this frame's bank into the third word being worked out in r0, for a sprite
          # drawn with other lists (whose +attr2_base+ leaves the bank out).
          def orr_object_colors(obj)
            return unless obj.recolor_banks

            load_var(TMP, OBJ_COLORS_BANK)
            emit(ASM.orr_reg(ACC, ACC, TMP))
          end

          # Which pose's pictures are sitting in a sprite's room right now, for a sprite that
          # keeps one frame at a time (see ScreenLayout#set_to_keep_to_one_frame). The sprite names its
          # own variable, so that anything reading a finished cartridge back looks in the same
          # place this writes (see Sprite#frame_in_room_var, and GBA#streamed_sprite_pose_vars).
          def frame_in_room(obj) = obj.frame_in_room_var

          # Nothing is in any room: set at boot, and again whenever sprite memory is written
          # over — a screen change sends every picture again, and a scene taking over sends
          # its own over the room its sprites use — so the next draw copies its frame in.
          NO_FRAME = 0xFFFF_FFFF

          def forget_still_objects
            return if @layout.movement.still.empty?

            @primitives.store_word_immediate(0, @primitives.var_addr(STILL_UP))
          end

          def forget_frames_in_rooms(objects)
            objects.each { |obj| store_word_immediate(NO_FRAME, var_addr(frame_in_room(obj))) if obj.frames }
          end

          # COPY THE FRAME THIS SPRITE IS SHOWING INTO ITS ROOM, when it is not the one already
          # there. The cartridge holds every frame at one stride, so the frame's start is the
          # pose times the stride, and one transfer moves it: whole words, since a frame is a
          # whole number of tiles and a tile is a whole number of words. Done in the gap after
          # the screen is drawn, with the rest of the sprite table, so the frame and the table
          # entry pointing at it change together.
          def emit_send_object_frame(obj)
            already = gensym
            @lowering.value(obj.pose)
            load_var(TMP, frame_in_room(obj))
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, already, cond: :eq)
            store_var(ACC, frame_in_room(obj))
            emit(ASM.load_immediate(TMP, obj.frame_bytes))
            emit(ASM.mul(2, ACC, TMP))                    # r2 = where this frame starts in the blob
            emit_load_data_address(ACC, obj.frames)
            emit(ASM.add_reg(ACC, ACC, 2))
            emit(ASM.load_immediate(TMP, REG_DMA3SAD))
            emit(ASM.str(ACC, TMP))                       # source = the frame in the cartridge
            store_word_immediate(OBJ_TILE_BASE + (obj.tile_index * 32), REG_DMA3DAD)
            store_word_immediate((obj.frame_bytes / 4) | DMA_ENABLE | DMA_32BIT, REG_DMA3CNT)
            place_label(already)
          end

          # An upright sprite: position and size straight into its slot.
          def emit_draw_object_upright(obj, base, mirror = nil, piece = 0)
            return emit_draw_object_sized_poses(obj, base, mirror, piece) unless obj.alike

            # attr0 = (y & 0xFF) | shape + 256-color flag. The offset is where this pose
            # sits inside the canvas it was drawn on — added back so trimming the blank
            # away cannot move the picture (see PoseCutter#pose_box).
            @lowering.value(obj.y)
            emit_add_const(ACC, ACC, obj.offset_y, TMP) unless obj.offset_y.zero?
            mask_into_acc(0xFF)
            orr_acc(obj.attr0_base)
            store_halfword_acc(base)
            mirror_attr0(mirror)
            # attr1 = (x & 0x1FF) | size
            @lowering.value(obj.x)
            emit_add_const(ACC, ACC, obj.offset_x, TMP) unless obj.offset_x.zero?
            mask_into_acc(0x1FF)
            orr_acc(obj.attr1_base)
            store_halfword_acc(base + 2)
            store_halfword_acc(mirror + 2) if mirror
            # attr2 = which tiles to draw = this sprite's base tile + pose * stride
            # (palette bank/priority left at 0). A fixed pose folds to a constant.
            emit_object_tile_number(obj, base + 4)
            store_halfword_acc(mirror + 4) if mirror
          end

          # A sprite whose poses came out DIFFERENT sizes. Four things then move with the
          # pose — which tiles, what shape, what size, and how far along to draw it — so
          # they are read together out of one word (see ScreenLayout#object_pose_table) instead of
          # being worked out from a stride that no longer exists.
          #
          # Registers: r4 holds the word for the whole of this sprite's draw, because
          # every one of the three attributes wants a piece of it.
          POSE_WORD = 4

          # Where this sprite's position is held while the pose word is in a register.
          # WORKING OUT x AND y FIRST is not tidiness: evaluating an operand is free to use
          # any scratch register, so the word could not survive being loaded before them.
          # Held here, nothing between loading the word and the last store evaluates
          # anything, and the register is safe for the whole of it.
          POSE_DRAW_X = :__pose_draw_x
          POSE_DRAW_Y = :__pose_draw_y

          def emit_hold_object_position(obj)
            @lowering.value(obj.y)
            store_var(ACC, POSE_DRAW_Y)
            @lowering.value(obj.x)
            store_var(ACC, POSE_DRAW_X)
          end

          def emit_draw_object_sized_poses(obj, base, mirror = nil, piece = 0)
            # A sprite of several pieces had this done once for all of them, by the caller.
            emit_hold_object_position(obj) if obj.pieces == 1
            emit_load_pose_word(obj, piece)
            # attr0 = (y + how far down) & 0xFF, then the shape out of bits 10..11.
            load_var(ACC, POSE_DRAW_Y)
            emit(ASM.lsr_imm(TMP, POSE_WORD, 22))
            emit(ASM.add_reg(ACC, ACC, TMP))
            mask_into_acc(0xFF)
            emit(ASM.and_imm(TMP, POSE_WORD, 0x0C00))   # shape, still at bit 10
            emit(ASM.orr_reg_lsl(ACC, ACC, TMP, 4))     # ...into bit 14
            orr_acc(obj.attr0_base) unless obj.attr0_base.zero?
            store_halfword_acc(base)
            mirror_attr0(mirror)
            # attr1 = (x + how far right) & 0x1FF, then the size out of bits 12..13.
            load_var(ACC, POSE_DRAW_X)
            emit(ASM.lsr_imm(TMP, POSE_WORD, 14))
            emit(ASM.and_imm(TMP, TMP, 0xFF))
            emit(ASM.add_reg(ACC, ACC, TMP))
            mask_into_acc(0x1FF)
            emit(ASM.and_imm(TMP, POSE_WORD, 0x3000))   # size, still at bit 12
            emit(ASM.orr_reg_lsl(ACC, ACC, TMP, 2))     # ...into bit 14
            emit_pose_mirror_bit if obj.mirrors&.any?
            orr_acc(obj.attr1_base) unless obj.attr1_base.zero?
            store_halfword_acc(base + 2)
            store_halfword_acc(mirror + 2) if mirror
            # attr2 = the pose's own first tile, out of bits 0..9. Two shifts rather than a
            # mask: a ten-bit mask is not one of the immediates this chip can carry.
            emit(ASM.lsl_imm(ACC, POSE_WORD, 22))
            emit(ASM.lsr_imm(ACC, ACC, 22))
            orr_acc(obj.attr2_base) unless obj.attr2_base.zero?
            orr_object_colors(obj)
            store_halfword_acc(base + 4)
            store_halfword_acc(mirror + 4) if mirror
          end

          # Carry "draw this one backwards" from the pose word into the sprite's own
          # entry. Only emitted for a sprite that actually has a mirrored pose, so a
          # sprite whose poses merely differ in size pays nothing for it.
          def emit_pose_mirror_bit
            emit(ASM.lsr_imm(TMP, POSE_WORD, 18))       # bit 30 down to bit 12...
            emit(ASM.and_imm(TMP, TMP, OBJ_HFLIP))      # ...and nothing else with it
            emit(ASM.orr_reg(ACC, ACC, TMP))
          end

          # How far a load can reach from a register on its own (the instruction carries a
          # 12-bit offset). Only a sprite of many pieces with a great many poses runs past
          # it, and then the address is worked out instead.
          LDR_OFFSET_LIMIT = 4096

          # r4 = the word describing the piece of the pose this sprite is showing. A fixed
          # pose is one load of a number settled while building; a pose the game works out
          # is a read from the table at that index. The table is laid out piece first, so
          # this piece's row starts at a place the build already knows and the read is the
          # same one instruction whichever piece it is.
          def emit_load_pose_word(obj, piece = 0)
            words = obj.pose_words
            row = piece * obj.pose_count
            fixed = const_int(obj.pose)
            if fixed
              at = fixed.between?(0, obj.pose_count - 1) ? row + fixed : row
              return emit(ASM.load_immediate(POSE_WORD, words[at]))
            end

            @lowering.value(obj.pose)
            emit(ASM.lsl_imm(ACC, ACC, 2)) # a word each
            emit_load_data_address(TMP, obj.pose_table)
            emit(ASM.add_reg(TMP, TMP, ACC))
            offset = row * 4
            return emit(ASM.ldr(POSE_WORD, TMP)) if offset.zero?
            return emit(ASM.ldr_offset(POSE_WORD, TMP, offset)) if offset < LDR_OFFSET_LIMIT

            emit_add_const(TMP, TMP, offset, ACC) # ACC is spent: the pose is already added in
            emit(ASM.ldr(POSE_WORD, TMP))
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
          # already been written, so this only has to hide the twin — one window per piece
          # for a sprite drawn as several objects, since the hole has to be the shape of
          # the whole picture. Asked once for all of them, after they are drawn.
          def emit_window_gate(twin, pieces)
            @lowering.value(twin.gate)
            emit(ASM.cmp_imm(ACC, 0))
            keeps = gensym
            emit_branch(:bcond, keeps, cond: :ne)
            pieces.times { |piece| write_reg16(oam_slot(twin.slot, piece), OBJ_HIDDEN_ATTR0) }
            place_label(keeps)
          end

          # A turning or resizing sprite: the console draws it through its affine group in
          # a double-size box. We offset the box top-left by half the sprite so the
          # picture stays centered where an upright one would sit and pivots on its own
          # center, turn on the rotate/scale and double-size bits, point attr1 at the
          # affine group, then fill that group with this frame's matrix.
          def emit_draw_object_transformed(obj, base, mirror = nil)
            half_w = obj.width / 2
            half_h = obj.height / 2
            # attr0 = ((y - half_h) & 0xFF) | rotate/scale + double-size + shape/color
            @lowering.value(obj.y)
            emit(ASM.sub_imm(ACC, ACC, half_h)) unless half_h.zero?
            mask_into_acc(0xFF)
            orr_acc(obj.attr0_base | OBJ_ROTSCALE | OBJ_DOUBLE_SIZE)
            store_halfword_acc(base)
            mirror_attr0(mirror)
            # attr1 = ((x - half_w) & 0x1FF) | size | affine-group index (bits 9..13)
            @lowering.value(obj.x)
            emit(ASM.sub_imm(ACC, ACC, half_w)) unless half_w.zero?
            mask_into_acc(0x1FF)
            orr_acc(obj.attr1_base | (obj.affine_slot << 9))
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
            group = OAM_START + (obj.affine_slot * 32)
            emit_object_scale_reciprocal(obj) if obj.scales # do the divide first: it clobbers everything
            @lowering.value(obj.angle)                      # r0 = angle in degrees (0..359)
            emit_load_data_address(TMP, OBJ_SINE_BLOB)   # r1 = sine table base
            emit(ASM.lsl_imm(2, ACC, 1))                 # r2 = angle * 2 (halfword offset)
            emit(ASM.add_reg(ADDR, TMP, 2))
            emit(ASM.ldrsh(2, ADDR))                     # r2 = sin(angle)
            emit(ASM.add_imm(3, ACC, 90))                # r3 = angle + 90
            emit(ASM.lsl_imm(3, 3, 1))
            emit(ASM.add_reg(ADDR, TMP, 3))
            emit(ASM.ldrsh(3, ADDR))                     # r3 = sin(angle + 90) = cos(angle)
            emit_scale_sine_and_cosine if obj.scales   # r2, r3 *= one over the size
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
            @lowering.value(obj.scale)                             # r0 = size, in SCALE_ONE-ths
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

          # Write a sprite's tile number (attr2) for this frame. The sprite's poses sit
          # back to back in tile memory, so the pose it's showing is base + pose*stride.
          # A constant pose (the common single-pose sprite) folds to a plain write; a
          # variable pose (facing / animation) is computed at run time.
          def emit_object_tile_number(obj, attr2_addr)
            fixed = const_int(obj.pose)
            if fixed && obj.recolor_banks.nil?
              write_reg16(attr2_addr, obj.tile_index + (fixed * obj.per_pose) | obj.attr2_base)
            elsif fixed
              emit(ASM.load_immediate(ACC, obj.tile_index + (fixed * obj.per_pose) | obj.attr2_base))
              orr_object_colors(obj)
              store_halfword_acc(attr2_addr)
            else
              @lowering.value(obj.pose)                          # r0 = pose index
              emit(ASM.load_immediate(TMP, obj.per_pose))   # r1 = stride between poses
              emit(ASM.mul(2, ACC, TMP))                      # r2 = pose * stride (rd must differ from rm)
              emit_add_const(ACC, 2, obj.tile_index, TMP)   # r0 = r2 + base tile
              orr_acc(obj.attr2_base) unless obj.attr2_base.zero?
              orr_object_colors(obj)
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
        end
      end
    end
  end
end
