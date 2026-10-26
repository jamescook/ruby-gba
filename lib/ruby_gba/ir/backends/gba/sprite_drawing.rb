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

          def initialize(emitter:, primitives:, lowering:, divide:, framebuffer:, palette_tint:, uploads:,
                         call_cold_routine:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @divide = divide
            @framebuffer = framebuffer
            @palette_tint = palette_tint
            @uploads = uploads
            @call_cold_routine = call_cold_routine
            @layout = nil
            @picture_group_copying = nil
          end

          attr_writer :layout, :picture_group_copying

          def placed_fade = @layout.screen.placed_fade

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

          # HOW FAR OFF THE SCREEN A SPRITE CAN STAND AND STILL BE WHERE THE GAME PUT IT.
          #
          # A row of the table keeps a sprite's row as one of 256 and its column as one of
          # 512, and a place outside those is kept as a place inside them: row 300 is kept as
          # row 44, so a sprite a game parked below the screen is drawn across the middle of
          # it. The screen is 160 of the 256 rows, which leaves 96 for a sprite standing above
          # it, and 240 of the 512 columns, which leaves 272 for one to its left. So a box is
          # drawn where the game put it while its top is no more than 96 rows above the
          # screen and its bottom is short of the last row counted, and the same across
          # with 272 columns and the last column. Anywhere else the table would draw it
          # somewhere the game never meant, so it is moved to the first row below the screen
          # or the first column right of it, where none of it shows (see
          # #emit_move_far_place_off_screen).
          ROWS_KEPT = 256
          COLUMNS_KEPT = 512
          ROWS_KEPT_ABOVE = ROWS_KEPT - SCREEN_HEIGHT
          COLUMNS_KEPT_LEFT = COLUMNS_KEPT - SCREEN_WIDTH

          # The largest box the console draws a sprite in, each way: any sprite that stands
          # upright, and each piece of a picture drawn as several. One that turns or resizes
          # is drawn in a box twice its own size, so the largest of those is twice this.
          LARGEST_BOX = 64

          # The rows a box as tall as the largest is drawn at as the game put them, and the
          # columns: for the box of a sprite that stands upright, and for the wider one of a
          # sprite that turns.
          ROWS_DRAWN_AS_PUT = (-ROWS_KEPT_ABOVE...(ROWS_KEPT - LARGEST_BOX))
          COLUMNS_DRAWN_AS_PUT = (-COLUMNS_KEPT_LEFT...(COLUMNS_KEPT - LARGEST_BOX))
          TURNED_COLUMNS_DRAWN_AS_PUT = (-COLUMNS_KEPT_LEFT...(COLUMNS_KEPT - (LARGEST_BOX * 2)))

          # The tallest box that stands unseen at the first row below the screen: as many
          # rows as are counted past the bottom edge. The one box taller is a turning
          # sprite's, 64 pixels tall and so drawn in 128 rows (see #emit_tall_box_attr0).
          TALLEST_BOX_UNSEEN_BELOW = ROWS_KEPT_ABOVE

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
            # The table has just been wiped, so the sprites nobody moves are gone from it too
            # and have to be written again. This runs on a change of screen as well as at
            # boot, which is the case that would otherwise leave a title screen blank.
            emit_mark_still_sprites_unwritten
            @uploads.emit_dma_blob(@layout.screen.obj_palette_blob, OBJ_PALETTE, @layout.screen.obj_palette_units) # the shared sprite palette, once
            @palette_tint.emit_record_obj_palette_source(@layout.screen.obj_palette_blob) # ...which is the one a tint walks until a scene sends its own
            @layout.screen.objects.each_value do |obj|
              # A sprite showing the same pictures as one already uploaded points at
              # those, so there is nothing of its own to send. A sprite that belongs to a
              # scene is sent when that scene takes over, not here (see
              # Drawing#emit_scene_art_upload), since scenes share the room above this.
              next if obj.tiles.nil? || obj.scene

              @uploads.emit_dma_blob(obj.tiles, OBJ_TILE_BASE + (obj.tile_index * 32), obj.tile_units * 16) # tiles -> sprite memory
            end
            emit_reset_resident_frames(@layout.screen.objects.each_value)
            # ...and no group's pictures are in sprite memory, so the groups the game says are up
            # are copied in again before the sprites are next written.
            @picture_group_copying.emit_forget_every_set_up
            emit_boot_object_windows
            @palette_tint.emit_tint_reset_if_tinting # the table now holds the originals again
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
            store_word_immediate(placed_fade.fade_stack_index, var_addr(EFFECT_LINE))
          end

          # Fill the sprite table with the "unused slot" marker so no leftover memory
          # shows as a sprite. One source-fixed DMA of a word that is two hidden slots.
          def clear_object_table
            scratch = var_addr(:_oam_clear)
            store_word_immediate(OBJ_HIDDEN_WORD, scratch)
            emit_start_copy_engine(from: scratch, to: OAM_START, control: @framebuffer.dma_fill_control(OAM_SIZE / 4))
            emit_clear_draw_run_copies
            emit_clear_held_table
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

          # A LIST OF SPRITE COLOURS HOLDS ANOTHER SET: put that set into the group of sixteen
          # the sprites drawn with the list read.
          #
          # Not a sprite is touched. A sprite's row says which group its pixels pick their
          # colours from, and every sprite drawn with this list names the same one — so
          # changing the sixteen entries there changes all of them at once, and costs the same
          # however many there are. That is what lets one group dress a goblin in one room and
          # a bat in the next: the group is a slot, and this fills it.
          #
          # WHY THE GROUP IS THE LIST'S OWN: the write lands in the table, where anything else
          # reading those sixteen would change colour too (see
          # ScreenLayout#changing_list_pictures).
          #
          # WHEN it happens is decided above this: the framework puts the copy in the gap
          # between frames, which is where the sprites' rows are written too, on the frame the
          # answer changed and no other (see Builder::ColorLists).
          #
          # A number naming none of the sets hands over the colours the list was declared
          # with, which sit last in the blob — so that case is a conditional move rather than a
          # branch. Where the set starts is remembered as well as written, because a tint, a
          # scene taking over and a change of screen all put the declared colours back in this
          # group, and each then reads this to put the set in force back (see
          # PaletteTint#emit_recolored_obj_banks).
          def emit_color_list_holds(node)
            list = @layout.screen.color_lists[node.name]
            return if list.nil? # no sprite on a tiled screen draws with it

            @lowering.value(node.which)
            # One unsigned compare catches both ends: a negative number reads as a very large
            # one, so anything outside 0...count fails the same test.
            emit_number(TMP, list.count)
            emit(ASM.cmp_reg(ACC, TMP))
            emit(ASM.mov_reg_cond(:hs, ACC, TMP))
            emit(ASM.lsl_imm(TMP, ACC, COLOR_SET_SHIFT))
            emit_load_data_address(ACC, list.blob)
            emit(ASM.add_reg(ACC, ACC, TMP))
            store_var(ACC, list.source_var)
            @palette_tint.emit_changed_list_colors(list)
          end

          # A set is sixteen colours of two bytes each, so the set numbered N starts 32 * N
          # along the blob.
          COLOR_SET_SHIFT = 5

          # Draw this frame's sprites: write each named object's current position and
          # visibility into its slot in the sprite table. Runs right after the vblank
          # (when changing the table is safe), so a moving sprite lands at its new spot
          # with no tearing. A game playing recorded sound keeps that: its mixing waits for
          # the display to start the next picture, so it never takes the gap from this. The console composites the sprites over the background for
          # free — there's nothing to erase, unlike a software sprite.
          #
          # The groups the game says are up are brought in first, so a sprite showing one of their
          # pictures draws it on the frame it first shows it (see PictureGroupCopying).
          def emit_present_objects(node)
            by_scene = @layout.scene_sprites
            emit_switch_sprite_layer
            @picture_group_copying.emit_calls_to_routines
            emit_count_lending_frame
            emit_hide_scene_rows_on_change
            emit_write_sprite_rows(node.names - @layout.movement.still - by_scene.flat_map(&:names))
            by_scene.each { |group| emit_scene_sprites(group) }
            emit_refresh_still_sprites
            @layout.draw_runs.each { |run| emit_copy_draw_run(run) }
            emit_copy_held_table
          end

          # EVERY SPRITE OFF FOR A FRAME (see Builder::Sprites#hide_sprites).
          #
          # The console draws its sprites as a layer of their own over the backgrounds, and one
          # bit of its display-control register says whether that layer is drawn at all. With it
          # off nothing of any sprite shows, and the table of rows and the pictures stay exactly
          # as they are, so turning it on again a frame later shows every sprite where it would
          # have been.
          #
          # `hide_sprites` only notes that it was asked. The bit is changed here, between frames,
          # where nothing is being drawn: changed while the pass runs, it would take the sprites
          # off the lower part of the frame being drawn then. The note is one of three:
          SPRITES_HIDDEN = :_sprites_hidden
          SPRITES_SHOWN = 0 # the layer is on, and nothing asked
          SPRITES_ASKED = 1 # the pass just run asked for a frame without them
          SPRITES_OFF = 2   # the layer is off for this frame, and comes on again at the next gap

          # Whether the game ever asks, so that a game that never does emits nothing for it.
          attr_writer :hides_sprites

          def hides_sprites? = @hides_sprites && @layout.has_objects

          # `hide_sprites`: note it, for the gap after this pass.
          def emit_hide_sprites(_node)
            store_word_immediate(SPRITES_ASKED, var_addr(SPRITES_HIDDEN)) if hides_sprites?
          end

          # At power-on the layer is on, whatever the memory held.
          def emit_sprites_shown_at_power_on
            store_word_immediate(SPRITES_SHOWN, var_addr(SPRITES_HIDDEN)) if hides_sprites?
          end

          # Between frames: the layer off for a frame that was asked for, and on again the gap
          # after. Turning it on is only for a screen drawn from tiles. A bitmap screen paints
          # its sprites into the picture and keeps that bit clear, and a game can go to one on
          # the pass after asking. The low three bits of the register say which kind is up, and
          # tiled screens are the kinds below 3. A frame asked for while the layer is already
          # off keeps it off. On a frame nobody asked, this costs a load, two compares and two
          # branches.
          def emit_switch_sprite_layer
            return unless hides_sprites?

            done = gensym
            turn_on = gensym
            load_var(ACC, SPRITES_HIDDEN)
            emit(ASM.cmp_imm(ACC, SPRITES_ASKED))
            emit_branch(:bcond, turn_on, cond: :ne)
            store_word_immediate(SPRITES_OFF, var_addr(SPRITES_HIDDEN))
            emit_number(TMP, REG_DISPCNT)
            emit(ASM.load_halfword(ACC, TMP))
            emit(ASM.bic_imm(ACC, ACC, OBJ_ENABLE))
            emit(ASM.store_halfword(ACC, TMP))
            emit_branch(:b, done)
            place_label(turn_on)
            emit(ASM.cmp_imm(ACC, SPRITES_OFF))
            emit_branch(:bcond, done, cond: :ne)
            store_word_immediate(SPRITES_SHOWN, var_addr(SPRITES_HIDDEN))
            emit_number(TMP, REG_DISPCNT)
            emit(ASM.load_halfword(ACC, TMP))
            emit(ASM.and_imm(2, ACC, 7))
            emit(ASM.cmp_imm(2, 3))
            emit_branch(:bcond, done, cond: :hs) # a bitmap screen
            emit(ASM.orr_imm(ACC, ACC, OBJ_ENABLE))
            emit(ASM.store_halfword(ACC, TMP))
            place_label(done)
          end

          # A SCREEN'S WHOLE SET OF LAYERS, written to the display. Where a game's screens use
          # layers of their own, the screen in play writes all of them every pass, the sprite
          # layer among them — and that write lands after the gap that switched the sprite layer
          # off for a frame, so on its own it would put the sprites straight back. So in a game
          # that says `hide_sprites`, the sprite layer is left out of the write on the frame it is
          # off for. A game that never says it writes the value as it is.
          def emit_screen_layers(value)
            return write_reg16(REG_DISPCNT, value) unless hides_sprites? && value.anybits?(OBJ_ENABLE)

            write = gensym
            emit_number(ACC, value)
            load_var(TMP, SPRITES_HIDDEN)
            emit(ASM.cmp_imm(TMP, SPRITES_OFF))
            emit_branch(:bcond, write, cond: :ne)
            emit(ASM.bic_imm(ACC, ACC, OBJ_ENABLE))
            place_label(write)
            emit_number(TMP, REG_DISPCNT)
            emit(ASM.store_halfword(ACC, TMP))
          end

          # A RUN OF THE TABLE DRAWN IN AN ORDER THE GAME WORKS OUT (see Builder#draw_in_order).
          #
          # The console decides which of two sprites is in front by where their rows sit in its
          # table — the lower row in front — and a row's place was fixed when the cartridge was
          # built. So the sprites of such a run do not write their rows into the table at all.
          # They write them into a copy of the run kept in work memory, laid out exactly as the
          # table would have it, every way they always did; and before each frame is drawn the
          # run is copied into the table in the order the program sorted it into.
          #
          # WHY A COPY RATHER THAN WRITING EACH SPRITE STRAIGHT TO ITS NEW ROW: a sprite's row is
          # not always written. One that never moves is written once, one whose scene is not up
          # is not written at all — and they are right because a row stays as it was last
          # written. The copy keeps that true: every row stays where its own sprite put it, and
          # only the copy into the table moves.
          #
          # Only the first three of a row's four halves are copied. The fourth belongs to the
          # table's groups for turning sprites, which are counted by place, not by sprite.
          #
          # +first_slot+ and +slots+ are the run's rows in the table; +staging+ is where the copy
          # of them is kept; +order+ is where the program keeps its list of the run's sprites in
          # the order to draw them, back to front, a byte each counting from 0; and +table+ is a
          # cartridge table of two bytes a sprite — its first row, counted from the run's
          # first, and how many rows it takes.
          #
          # A run's rows are its own, never taken in turns with another scene's sprites (see
          # IR::SpriteRows): a sprite of another scene in one of them would be written into the
          # copy, and the copy is the run's.
          DrawRun = Data.define(:first_slot, :slots, :staging, :order, :members, :table) do
            def holds?(slot) = slot >= first_slot && slot < first_slot + slots
            def staged(slot) = staging + ((slot - first_slot) * 8)
          end

          # Each ordered run of +program+'s frame, with its copy given a place in +memory+ and
          # its table put in +blobs+; +lists+ says where the program keeps each list.
          def self.plan_draw_runs(program, objects:, memory:, blobs:, lists:)
            present = program.walk.find { |node| node.kind == :present_objects } or return []
            (present.orders || []).each_with_index.map do |run, k|
              sprites = run.objects.map { |name| objects.fetch(name) }
              first = sprites.map(&:slot).min
              slots = sprites.sum(&:pieces)
              unless sprites.flat_map { |sprite| (sprite.slot...(sprite.slot + sprite.pieces)).to_a }.sort == (first...(first + slots)).to_a
                raise LoweringError, "the sprites of a draw_in_order are not side by side in the sprite table"
              end

              table = :"__draw_run_#{k}"
              blobs[table] = sprites.flat_map { |sprite| [sprite.slot - first, sprite.pieces] }.pack("C*")
              DrawRun.new(first_slot: first, slots: slots, staging: memory.alloc(slots * 8),
                          order: lists.list_info(run.order)[:base], members: sprites.length, table: table)
            end
          end

          # Where a sprite's row +piece+ is written: its place in the table, or in the copy of
          # its run when it is in one.
          def row_address(first, piece)
            slot = first + piece
            run = @layout.draw_runs.find { |each_run| each_run.holds?(slot) }
            run ? run.staged(slot) : oam_slot(first, piece)
          end

          # COPY ONE RUN INTO THE TABLE IN ITS ORDER. The program's list says the sprites back
          # to front, and the table's front is its first row, so the list is read from its end
          # while the table is written from the run's first row onward.
          #
          #   r1  the list, from its last entry back
          #   r12 one before the list's first entry, where the walk stops
          #   r2  the table row being written
          #   r3  the copy being read
          #   r4  rows left of this sprite
          def emit_copy_draw_run(run)
            list = run.order
            next_sprite = gensym
            next_row = gensym
            emit_number(TMP, list + run.members - 1)
            emit_number(ADDR, list - 1)
            emit_number(SPARE, oam_slot(run.first_slot, 0))
            place_label(next_sprite)
            emit(ASM.ldrb_offset(ACC, TMP, 0))            # which sprite goes next
            emit(ASM.sub_imm(TMP, TMP, 1))
            emit_load_data_address(POSE_WORD, run.table)
            emit(ASM.add_reg(POSE_WORD, POSE_WORD, ACC))
            emit(ASM.add_reg(POSE_WORD, POSE_WORD, ACC))  # ...its two bytes in the table
            emit(ASM.ldrb_offset(HIGH, POSE_WORD, 0))     # its first row in the copy
            emit(ASM.ldrb_offset(POSE_WORD, POSE_WORD, 1)) # how many rows it takes
            emit(ASM.lsl_imm(HIGH, HIGH, 3))
            emit_number(ACC, run.staging)
            emit(ASM.add_reg(HIGH, HIGH, ACC))
            place_label(next_row)
            [0, 2, 4].each do |half|
              emit(ASM.load_halfword_offset(ACC, HIGH, half))
              emit(ASM.store_halfword_offset(ACC, SPARE, half))
            end
            emit(ASM.add_imm(HIGH, HIGH, 8))
            emit(ASM.add_imm(SPARE, SPARE, 8))
            emit(ASM.subs_imm(POSE_WORD, POSE_WORD, 1))
            emit_branch(:bcond, next_row, cond: :ne)
            emit(ASM.cmp_reg(TMP, ADDR))
            emit_branch(:bcond, next_sprite, cond: :ne)
          end

          # Fill the copy of every ordered run with the "unused slot" marker, for the same
          # reason the table itself is cleared: a row nothing has written yet would show.
          # The marker is already in the scratch word the table's own clear left it in.
          def emit_clear_draw_run_copies
            @layout.draw_runs.each do |run|
              emit_start_copy_engine(from: var_addr(:_oam_clear), to: run.staging,
                                     control: @framebuffer.dma_fill_control(run.slots * 2))
            end
          end

          # MORE ROWS THAN THE CONSOLE'S TABLE HOLDS.
          #
          # The console draws its sprites from 128 rows, and every sprite is given a row while the
          # cartridge is built — a pool one for every thing it can hold, so three pools of sixty
          # need 180 although a room shows a handful. A game with more than 128 keeps all of them
          # in a bigger copy of the table, in the roomy memory, and every sprite writes its row
          # there exactly as it would have written the console's. Before each frame the rows that
          # show something are copied into the console's table one after another, front to back
          # (see #emit_held_table_routine): so what has to fit in 128 is one frame's sprites, as
          # in the console's own games, which build their table each frame from what they draw.
          #
          # THE ORDER HOLDS. The console puts a lower row in front, and the copy keeps every row
          # in the order the build gave it, only closing up the gaps the hidden ones leave.
          #
          # MORE SHOWING THAN 128: the frontmost 128 are drawn, and the rest are left out for that
          # frame and counted (LEFT_OUT, which a profile reports). Every other backend draws them
          # all — it has no table to run out of.
          #
          # +rows+ is how many rows the build handed out, +copy+ where the bigger table is, and
          # +came_from+ a half a console row saying which row of the copy is in it this frame, so
          # a reader of the running cartridge can say whose sprite each one is.
          HeldTable = Data.define(:rows, :copy, :came_from) do
            def row_address(slot) = copy + (slot * 8)
          end

          HELD_TABLE_ROUTINE = Messages::MadeNames.make(:held_sprite_table)
          # How far into the console's table the last frame's copy reached, so the rows past this
          # frame's are hidden only as far as there was anything to hide.
          HELD_SHOWN_TO = :__held_sprites_shown_to
          # How many rows were left out because the console's table was full, since power-on.
          LEFT_OUT = :__sprites_left_out

          # The bigger table for +rows+ rows, or nil when they fit in the console's own. +alloc+
          # claims roomy memory, given how much and what for.
          def self.plan_held_table(rows, alloc:)
            return nil if rows <= MAX_SPRITES

            HeldTable.new(rows: rows, copy: alloc.call(rows * 8, "where more sprites than the console draws are kept"),
                          came_from: alloc.call(MAX_SPRITES * 2, "which sprite each row of the console's table is"))
          end

          # Every row of the copy hidden, at power-on, as the console's own table is.
          def emit_clear_held_table
            held = @layout.held_sprites or return

            emit_start_copy_engine(from: var_addr(:_oam_clear), to: held.copy,
                                   control: @framebuffer.dma_fill_control(held.rows * 2))
            store_word_immediate(OAM_START + OAM_SIZE, var_addr(HELD_SHOWN_TO))
            store_word_immediate(0, var_addr(LEFT_OUT))
          end

          def emit_copy_held_table
            @call_cold_routine.call(HELD_TABLE_ROUTINE) if @layout.held_sprites
          end

          # THE COPY INTO THE CONSOLE'S TABLE. Each row of the copy is looked at in turn, and one
          # that is not hidden has its first three halves copied to the next row of the console's,
          # and its own number noted beside it; past the console's last row, it is counted
          # instead. The fourth half of each row is left alone: it belongs to the table's groups
          # for turning sprites, which are counted by place, not by sprite. Then the console's
          # rows past the last one copied are hidden, as far as last frame's copy reached.
          #
          # A hidden row is one with its first half's two "how it is drawn" bits saying hidden and
          # not turning (OBJ_HIDDEN_ATTR0 with the rotate/scale bit clear).
          #
          #   r1  the row of the copy being looked at     r5  its number
          #   r2  where the copy ends                      r6  rows left out this frame
          #   r3  the console's row being written         r7  scratch
          #   r4  where its number is noted                r8  where the console's table ends
          def emit_held_table_routine
            held = @layout.held_sprites or return

            look = gensym
            full = gensym
            passed = gensym
            hide = gensym
            hidden = gensym
            emit(ASM.loop_forever) # fall-through guard: only ever entered by the call
            place_label(HELD_TABLE_ROUTINE)
            emit(ASM.push(4, 5, 6, 7, 8, 14))
            emit_number(TMP, held.copy)
            emit_number(SPARE, held.copy + (held.rows * 8))
            emit_number(HIGH, OAM_START)
            emit_number(4, held.came_from)
            emit(ASM.load_immediate(5, 0))
            emit(ASM.load_immediate(6, 0))
            emit_number(8, OAM_START + OAM_SIZE)
            place_label(look)
            emit(ASM.load_halfword(ACC, TMP))
            emit(ASM.and_imm(7, ACC, OBJ_ROTSCALE | OBJ_HIDDEN_ATTR0))
            emit(ASM.cmp_imm(7, OBJ_HIDDEN_ATTR0))
            emit_branch(:bcond, passed, cond: :eq)
            emit(ASM.cmp_reg(HIGH, 8))
            emit_branch(:bcond, full, cond: :hs)
            emit(ASM.store_halfword(ACC, HIGH))
            [2, 4].each do |half|
              emit(ASM.load_halfword_offset(ACC, TMP, half))
              emit(ASM.store_halfword_offset(ACC, HIGH, half))
            end
            emit(ASM.store_halfword(5, 4))
            emit(ASM.add_imm(HIGH, HIGH, 8))
            emit(ASM.add_imm(4, 4, 2))
            emit_branch(:b, passed)
            place_label(full)
            emit(ASM.add_imm(6, 6, 1))
            place_label(passed)
            emit(ASM.add_imm(TMP, TMP, 8))
            emit(ASM.add_imm(5, 5, 1))
            emit(ASM.cmp_reg(TMP, SPARE))
            emit_branch(:bcond, look, cond: :ne)
            load_var(ACC, LEFT_OUT)
            emit(ASM.add_reg(ACC, ACC, 6))
            store_var(ACC, LEFT_OUT)
            load_var(7, HELD_SHOWN_TO)
            store_var(HIGH, HELD_SHOWN_TO)
            emit_number(ACC, OBJ_HIDDEN_ATTR0)
            place_label(hide)
            emit(ASM.cmp_reg(HIGH, 7))
            emit_branch(:bcond, hidden, cond: :hs)
            emit(ASM.store_halfword(ACC, HIGH))
            emit(ASM.add_imm(HIGH, HIGH, 8))
            emit_branch(:b, hide)
            place_label(hidden)
            emit(ASM.pop(4, 5, 6, 7, 8, 15))
            place_label(:"#{HELD_TABLE_ROUTINE}_end")
          end

          # The routine that writes one scene's moving sprites (see GBA#prepare_scene_sprites).
          # Named for the scene, so a report and a measured profile can say whose it is.
          def self.sprites_routine(scene) = Messages::MadeNames.make(:scene_sprites, scene: Modes.strip_scene_prefix(scene))

          # What the variable that picks the scenes held when its scenes' rows were last hidden.
          def self.scene_rows_hidden_for(state) = Messages::MadeNames.make(:scene_rows_hidden_for, state: state)

          # The routine that hides every row the scenes that variable picks can use (see
          # #emit_hide_scene_rows_on_change).
          def self.hide_rows_routine(state) = Messages::MadeNames.make(:scene_rows_hide, state: state)

          # WRITE ONE SCENE'S MOVING SPRITES, on its frames and no others. A scene that has gone
          # has had its rows hidden already (see #emit_hide_scene_rows_on_change), and another
          # scene's sprites may be using those rows now, so its own must not touch them.
          def emit_scene_sprites(group)
            emit_while_scene_up(group.state, group.value) do
              @lowering.statement(Build.call(self.class.sprites_routine(group.scene)))
            end
          end

          # Emit the block's code to run only while +state+ holds +value+: while that scene is up.
          def emit_while_scene_up(state, value)
            skip = gensym
            @lowering.value(Build.binop(:==, Build.var_ref(state), Build.int(value)))
            emit(ASM.cmp_imm(ACC, 0))
            emit_branch(:bcond, skip, cond: :eq)
            yield
            place_label(skip)
          end

          # HIDE EVERY ROW A SCENE'S SPRITES CAN BE IN, ON THE FRAME THE SCENE CHANGES, before
          # any sprite is written.
          #
          # Scenes never up together take turns at the same rows of the table (see
          # IR::SpriteRows), so the scene that went cannot hide its own sprites the way a sprite
          # hides itself: by the time it wrote "hidden" into a row, the scene that came might
          # have written a sprite there already. So nothing of a scene that is not up writes
          # anything, and this hides them all first: every row of every sprite a scene puts up,
          # its window twin's if it has one, and its place in the copy of a run drawn in an order
          # the game works out. The sprites of the scene that came are written after this, on the
          # same frame — a moving one by its scene's routine, a still one because the still ones
          # are written again whenever this variable changes (see #emit_refresh_still_sprites).
          #
          # One compare a frame for each variable that picks scenes; on a change, a call to a
          # routine of one store a row. The stores are a routine of their own so the frame's own
          # code stays the same size however many sprites the scenes have. What was remembered
          # can hold anything at power-on, and the worst a stray match does is leave rows as they
          # are, which the boot has just cleared.
          def emit_hide_scene_rows_on_change
            @layout.gated_sprites.map(&:state).uniq.each do |state|
              remembered = self.class.scene_rows_hidden_for(state)
              same = gensym
              load_var(ACC, state)
              load_var(TMP, remembered)
              emit(ASM.cmp_reg(ACC, TMP))
              emit_branch(:bcond, same, cond: :eq)
              store_var(ACC, remembered)
              @lowering.statement(Build.call(self.class.hide_rows_routine(state)))
              place_label(same)
            end
          end

          # The body of that routine: hide every row the sprites +names+ are written at.
          def emit_hide_sprite_rows(names)
            emit_hide_rows_at(names.flat_map { |name| row_addresses_of(name) }.uniq.sort)
          end

          # Every address a row of sprite +name+ is written at: its rows in the table, the copy
          # of them in a run's work memory when it is one of a run, and its window twin's rows.
          def row_addresses_of(name)
            obj = @layout.screen.objects.fetch(name)
            twin = placed_fade.fade_window_for(name)
            Array.new(obj.pieces) do |piece|
              [oam_slot(obj.slot, piece), row_address(obj.slot, piece), (oam_slot(twin.slot, piece) if twin)]
            end.flatten.compact
          end

          # Mark each row at +addresses+ unused. A store reaches 255 bytes on from the address in
          # its register, so the address is loaded again only when the next row is past that.
          def emit_hide_rows_at(addresses)
            emit_number(ACC, OBJ_HIDDEN_ATTR0)
            base = nil
            addresses.each do |address|
              unless base && address - base < 256
                base = address
                emit_number(TMP, base)
              end
              emit(ASM.store_halfword_offset(ACC, TMP, address - base))
            end
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
          #
          # SPRITES THAT ARE ONE WRITE ARE WRITTEN BY GOING ROUND IT (see SpriteRepeats): a
          # pool's, which differ only in which entry of the pool's lists each reads.
          def emit_write_sprite_rows(names)
            sprites = @layout.screen.objects
            repeats = SpriteRepeats.new(sprites: sprites, row_of: ->(name) { row_address(sprites.fetch(name).slot, 0) },
                                        alone: ->(name) { must_be_written_alone?(sprites.fetch(name), name) })
            repeats.among(names).each do |part|
              next emit_sprite_repeat(part) if part.is_a?(SpriteRepeat)

              emit_present_object(sprites.fetch(part), twin: placed_fade.fade_window_for(part), name: part)
            end
          end

          # THE SPRITES ONE WRITE CANNOT SERVE, whatever they look like. Each has something of
          # its own at a place worked out from where it sits in the table, which going round
          # one write cannot reach: a window that keeps it out of a placed fade, or a room in
          # sprite memory its frames are copied into. (A sprite that turns has a group of the
          # table of its own as well, but that is a field of its record, so no two of those
          # are ever found to be one write in the first place.)
          #
          # And one drawn as more objects than a store can reach across from the first: a
          # store of a half names its address as a register and a distance under 256 bytes.
          def must_be_written_alone?(sprite, name)
            !placed_fade.fade_window_for(name).nil? || !sprite.frames.nil? || sprite.pieces > MAX_PIECES_OF_REPEATED_SPRITE
          end

          # Rows are 8 bytes, so the last half of the 32nd is 252 bytes on from the first.
          MAX_PIECES_OF_REPEATED_SPRITE = 32

          # Where the row being written is kept while a repeat is gone round.
          REPEAT_ROW = :__sprite_repeat_row

          # A ROW OF THE CONSOLE'S TABLE TO WRITE: at an address settled while building, for a
          # sprite written on its own...
          FixedRow = Data.define(:address)

          # ...or +offset+ bytes on from wherever a repeat has got to, which only the running
          # game knows.
          MovingRow = Data.define(:offset)

          # WRITE EVERY SPRITE OF A REPEAT BY GOING ROUND ONE WRITE. Two variables carry the
          # round: the entry of the pool's lists this sprite reads, which the write's own sums
          # name (see SpriteRepeats::INDEX), and the address of the row it writes. They are
          # kept in memory and not in registers because working out where a sprite stands is
          # free to use every register there is.
          #
          # What it costs against a copy apiece is a load of the row's address before each
          # store, and stepping the two variables — a handful of instructions a sprite. A pool's
          # sprites with nothing to show are passed over first, a store a row
          # (#emit_hide_places_left_over), and the walk starts at the first that shows something.
          def emit_sprite_repeat(repeat)
            again = gensym
            done = gensym
            emit_number(ACC, repeat.first_index)
            store_var(ACC, SpriteRepeats::INDEX)
            emit_number(ACC, repeat.first_row)
            store_var(ACC, REPEAT_ROW)
            live = live_count_var(repeat)
            emit_hide_places_left_over(repeat, live, done) if live
            place_label(again)
            emit_present_object(repeat.sprite, rows: Array.new(repeat.sprite.pieces) { |piece| MovingRow.new(offset: piece * 8) })
            load_var(ACC, REPEAT_ROW)
            emit_add_const(ACC, ACC, repeat.row_step, TMP)
            store_var(ACC, REPEAT_ROW)
            load_var(ACC, SpriteRepeats::INDEX)
            emit_add_const(ACC, ACC, repeat.index_step, TMP)
            store_var(ACC, SpriteRepeats::INDEX)
            emit_number(TMP, repeat.index_after)
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, again, cond: :ne)
            place_label(done)
          end

          # A POOL'S SPRITES, AND HOW MANY OF THEM SHOW. Each of a pool's sprites shows a place
          # in the order its things were spawned (DSL::Pool#stacked_list), and is shown while the
          # pool holds more things than that place's rank (DSL::Pool#rank_taken) — so the places
          # with something in them are the lowest ranks, all together. The sprites are declared
          # back to front, so a walk of the table meets the ranks going down: every sprite with
          # nothing to show first, then every one that shows something. Answers the variable
          # holding how many things are in place, read off the sprites' own test, or nil for a
          # repeat that is not a pool's that way, which is written in full as before.
          #
          # ONLY WHERE THAT RANK TEST HAS THE LAST WORD: the whole test, or one of several each of
          # which has to hold — joined by `&`, or by `*` of two tests that are each 0 or 1, which is
          # how a scene's own pool is shown only while the scene is up (Builder#gated_by_scene). A
          # sprite past the count is then hidden whatever the rest says. Found inside anything else
          # (an `|`, a test turned round) it settles nothing, and the sprites are written in full.
          #
          # Not for sprites given rooms of their own in sprite memory, whose hiding gives the room
          # back (#emit_let_go_of_shared_room), which a plain hidden mark does not.
          def live_count_var(repeat)
            return nil unless repeat.index_step == -1 && repeat.sprite.rooms.nil?

            rank_test_held(repeat.sprite.active)&.lhs&.name
          end

          # The rank test (count > INDEX) in +test+ that has to hold for +test+ to, or nil.
          def rank_test_held(test)
            return nil unless test.is_a?(IR::Node) && test.kind == :binop
            return test if test.op == :> && test.lhs.kind == :var_ref && test.rhs.kind == :var_ref &&
                           test.rhs.name == SpriteRepeats::INDEX
            return nil unless %i[& *].include?(test.op)

            rank_test_held(test.lhs) || rank_test_held(test.rhs)
          end

          # MARK THE PLACES WITH NOTHING IN THEM HIDDEN, a store for each of a place's rows,
          # before the walk writes the places that show something. Written in full, such a place
          # cost its whole test and write and the walk's bookkeeping in memory, and a game sized
          # for its biggest room keeps pools mostly empty in every other room, so the frame paid
          # that for every slot a room did not use. Here an empty place is its rows' stores and a
          # few instructions on. The walk then carries on from the first place that shows
          # something, or is over.
          #
          # In registers that are a statement's own scratch — the place in SPARE, its row in HIGH,
          # where to stop in TMP, the hidden mark in ACC, and ADDR for a row step too big to add
          # at once — since this runs between statements of the sprites routine and nothing is
          # held across it.
          def emit_hide_places_left_over(repeat, live, done)
            place, row, stop = SPARE, HIGH, TMP
            walk = gensym
            next_place = gensym
            past_empty = gensym
            load_var(stop, live)
            emit_number(ACC, repeat.index_after + 1)
            emit(ASM.cmp_reg(stop, ACC))
            emit_branch(:bcond, walk, cond: :ge)
            # Fewer things than this repeat's first place: nothing in it shows, so the walk stops
            # at its last place. (A pool's sprites can be several repeats.)
            emit(ASM.mov_reg(stop, ACC))
            place_label(walk)
            emit_number(place, repeat.first_index)
            emit_number(row, repeat.first_row)
            emit_number(ACC, OBJ_HIDDEN_ATTR0)
            place_label(next_place)
            emit(ASM.cmp_reg(place, stop))
            emit_branch(:bcond, past_empty, cond: :lt)
            repeat.sprite.pieces.times { |piece| emit(ASM.store_halfword_offset(ACC, row, piece * 8)) }
            emit_add_const(row, row, repeat.row_step, ADDR)
            emit(ASM.sub_imm(place, place, 1))
            emit_branch(:b, next_place)
            place_label(past_empty)
            store_var(place, SpriteRepeats::INDEX)
            store_var(row, REPEAT_ROW)
            emit_number(ACC, repeat.index_after)
            emit(ASM.cmp_reg(place, ACC))
            emit_branch(:bcond, done, cond: :eq)
          end

          # Store the low half of r0 in the half of +row+ that starts +half+ bytes into it.
          def emit_store_acc_in_row(row, half)
            return store_halfword_acc(row.address + half) if row.is_a?(FixedRow)

            load_var(TMP, REPEAT_ROW)
            emit(ASM.store_halfword_offset(ACC, TMP, row.offset + half))
          end

          # Store +number+, settled while building, in that half of +row+.
          def emit_store_number_in_row(row, half, number)
            return write_reg16(row.address + half, number) if row.is_a?(FixedRow)

            emit_number(ACC, number)
            emit_store_acc_in_row(row, half)
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
          def emit_refresh_still_sprites
            return if @layout.movement.still.empty?

            watching = @layout.movement.watching
            watching ? load_var(ACC, watching) : emit_number(ACC, NOTHING_TO_WATCH)
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
            emit_number(TMP, 1)
            store_var(TMP, STILL_UP)
            @lowering.statement(Build.call(STILL_ROUTINE))
            place_label(settled)
          end

          # The routine that writes the still sprites: the ones every scene shows, and then each
          # scene's own while that scene is up. A scene that is not up writes nothing, not even
          # "hidden", because its rows are hidden already and another scene's sprites may be in
          # them now (see #emit_hide_scene_rows_on_change).
          def emit_write_still_sprite_rows(still)
            by_scene = @layout.gated_sprites.filter_map do |group|
              mine = group.names & still
              group.with(names: mine) if mine.any?
            end
            emit_write_sprite_rows(still - by_scene.flat_map(&:names))
            by_scene.each do |group|
              emit_while_scene_up(group.state, group.value) { emit_write_sprite_rows(group.names) }
            end
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
          #
          # +rows+ is where each piece's row is written: the sprite's own places in the table,
          # unless it is one of a run and the run says where it has got to.
          #
          # A sprite standing further off the screen than the table can say is kept off it
          # (see ROWS_KEPT): a piece at a time, since the far piece of a big picture can be
          # out of the table's reach while the near one is on the screen.
          def emit_present_object(obj, twin: nil, name: nil, rows: nil)
            rows ||= Array.new(obj.pieces) { |piece| FixedRow.new(address: row_address(obj.slot, piece)) }
            @lowering.value(obj.active)
            emit(ASM.cmp_imm(ACC, 0))
            draw = gensym
            done = gensym
            emit_branch(:bcond, draw, cond: :ne)
            obj.pieces.times do |piece|
              emit_store_number_in_row(rows[piece], 0, OBJ_HIDDEN_ATTR0) # active == 0: mark it unused
              write_reg16(oam_slot(twin.slot, piece), OBJ_HIDDEN_ATTR0) if twin # ...and its window
            end
            emit_let_go_of_shared_room(obj) if obj.rooms
            emit_branch(:b, done)

            place_label(draw)
            emit_store_object_picked_attr2(obj) if obj.picks_attr2?
            if obj.rooms
              emit_take_shared_room(obj)
            elsif obj.frames
              emit_send_object_frame(obj, name)
            end
            emit_send_pose_first_shown(obj.pose_sends, obj.pose) if obj.pose_sends
            # Worked out once for the whole sprite when it is drawn as several objects:
            # every piece stands at the same place and reads it back from there.
            emit_stash_object_position(obj) if obj.pieces > 1
            obj.pieces.times do |piece|
              row = rows[piece]
              mirror = twin && oam_slot(twin.slot, piece)
              if obj.transformed
                emit_draw_object_transformed(obj, row, mirror)
              else
                emit_draw_object_upright(obj, row, mirror, piece)
              end
            end
            emit_hide_twin_unless_faded(twin, obj.pieces) if twin
            place_label(done)
          end

          def oam_slot(first, piece)
            held = @layout.held_sprites
            held ? held.row_address(first + piece) : OAM_START + ((first + piece) * 8)
          end

          # Where the part of a sprite's third word a frame decides is held while its pieces are
          # written. One variable serves every sprite, since each is done before the next.
          OBJ_PICKED_ATTR2 = :__obj_picked_attr2

          # THE PART OF A SPRITE'S THIRD WORD THIS FRAME DECIDES, worked out once, before the
          # pieces, and ORed into each of their third words. Since that word is written with
          # the position and the pose, what it decides changes on the same frame they do.
          #
          # Two things can be decided there. WHICH COLOURS: a pixel of a small-storage sprite
          # is a place in a bank of sixteen, and the bank is named in this word — so naming
          # another bank is all it takes, and the picture itself is never touched. And HOW
          # DEEP: the console compares a sprite's two-bit depth here with each background's
          # own, and draws the sprite in front of every background whose number is the same
          # or bigger. Putting the sprite in another layer is changing those two bits.
          def emit_store_object_picked_attr2(obj)
            if obj.recolor_banks
              emit_pick_from_table(obj.recolor, obj.recolor_banks)
              emit_borrow_group_if_lent if obj.recolor_banks.lends
            end
            if obj.layer_depths
              store_var(ACC, OBJ_PICKED_ATTR2) if obj.recolor_banks
              emit_pick_layer_depth(obj.layer_pick, obj.layer_depths)
              if obj.recolor_banks
                load_var(TMP, OBJ_PICKED_ATTR2)
                emit(ASM.orr_reg(ACC, ACC, TMP))
              end
            end
            store_var(ACC, OBJ_PICKED_ATTR2)
          end

          # r0 = the word +choice+ picks out of +table+. A number past the last entry, or
          # below 0 (which compared unsigned is past it too), picks the table's last entry,
          # which is what the sprite was declared with.
          def emit_pick_from_table(choice, table)
            @lowering.value(choice)
            emit(ASM.cmp_imm(ACC, table.own))
            emit(ASM.mov_imm_cond(:hs, ACC, table.own))
            emit_load_data_address(TMP, table.table)
            emit(ASM.ldr_reg_lsl(ACC, TMP, ACC, 2))
          end

          # r0 = the depth the sprite's picked layer puts it at, on the screen that is up. Where
          # the depths differ from screen to screen the table is a row per screen, and the
          # variable that picks the screen says which row — held to the last row, the deepest,
          # for a value that picks no screen of the sprite's own.
          def emit_pick_layer_depth(choice, depths)
            return emit_pick_from_table(choice, depths) unless depths.scene_var

            @lowering.value(choice)
            emit(ASM.cmp_imm(ACC, depths.own))
            emit(ASM.mov_imm_cond(:hs, ACC, depths.own))
            load_var(TMP, depths.scene_var)
            emit(ASM.cmp_imm(TMP, depths.scene_count))
            emit(ASM.mov_imm_cond(:hs, TMP, depths.scene_count))
            emit_number(2, depths.own + 1)  # r2 = one row: each layer, then its own
            emit(ASM.mul(3, TMP, 2))                       # r3 = the screen's row (rd must differ from rm)
            emit(ASM.add_reg(ACC, ACC, 3))
            emit_load_data_address(TMP, depths.table)
            emit(ASM.ldr_reg_lsl(ACC, TMP, ACC, 2))
          end

          # OR this frame's picked part into the third word being worked out in r0, for a
          # sprite whose +attr2_base+ leaves that part out.
          def orr_picked_attr2(obj)
            return unless obj.picks_attr2?

            load_var(TMP, OBJ_PICKED_ATTR2)
            emit(ASM.orr_reg(ACC, ACC, TMP))
          end

          # Which pose's pictures are sitting in a sprite's room right now, for a sprite that
          # keeps one frame at a time (see ScreenLayout#pick_set_for_one_frame). The sprite names its
          # own variable, so that anything reading a finished cartridge back looks in the same
          # place this writes (see Sprite#resident_frame_var, and GBA#streamed_sprite_pose_vars).
          def resident_frame_var(obj) = obj.resident_frame_var

          # Nothing is in any room: set at boot, and again whenever sprite memory is written
          # over — a screen change sends every picture again, and a scene taking over sends
          # its own over the room its sprites use — so the next draw copies its frame in.
          NO_FRAME = 0xFFFF_FFFF

          def emit_mark_still_sprites_unwritten
            return if @layout.movement.still.empty?

            @primitives.store_word_immediate(0, @primitives.var_addr(STILL_UP))
          end

          def emit_reset_resident_frames(objects)
            objects.each { |obj| store_word_immediate(NO_FRAME, var_addr(resident_frame_var(obj))) if obj.frames }
            objects.filter_map(&:rooms).uniq.each { |rooms| emit_empty_shared_rooms(rooms) }
          end

          # SPRITES SHARING ROOMS (see SpriteLayout::SharedRooms, which says how the record of a set
          # of rooms is laid out). The record is kept in the roomy memory. A sprite holding no room
          # holds the room past the last, which is one compare to tell.
          ROOMS = SpriteLayout::SharedRooms
          def room_table(rooms) = @layout.room_tables.fetch(rooms)
          def room_pose_at(rooms, room) = room_table(rooms) + rooms.room_at(room)
          def room_users_at(rooms, room) = room_pose_at(rooms, room) + ROOMS::USERS_AT
          def room_held_at(rooms, member) = room_table(rooms) + rooms.held_at(member)

          # Where the tiles of the room a sprite holds start, counted from its first room, while the
          # sprite is drawn. One variable serves every sprite, since each is done before the next.
          OBJ_ROOM_TILES = :__obj_room_tiles

          # Nothing is in any room and nobody holds one: at boot, and as their scene takes over,
          # since another scene's pictures went into the same memory.
          def emit_empty_shared_rooms(rooms)
            rooms.count.times do |room|
              store_word_immediate(NO_FRAME, room_pose_at(rooms, room))
              store_word_immediate(0, room_users_at(rooms, room))
              store_word_immediate(rooms.count, room_held_at(rooms, room)) # a sprite each, as many as rooms
            end
          end

          # A SPRITE SHOWING A POSE TAKES A ROOM HOLDING IT, when the pose is not the one in its room
          # already, and is then drawn from that room. Taking one is a routine of its own the sprites
          # of a set share, since it is the rare part: a sprite holding still, or showing what it
          # showed last frame, does a compare and the sum below.
          def emit_take_shared_room(obj)
            rooms = obj.rooms
            held = gensym
            @lowering.value(obj.pose)
            load_var(TMP, resident_frame_var(obj))
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, held, cond: :eq)
            store_var(ACC, resident_frame_var(obj))
            emit_number(TMP, obj.room_member)
            emit_call_cold_routine(shared_room_label(rooms, :take))
            place_label(held)
            emit_number(TMP, room_held_at(rooms, obj.room_member))
            emit(ASM.ldr(ACC, TMP))
            emit_number(TMP, rooms.units)
            emit(ASM.mul(2, ACC, TMP))
            store_var(2, OBJ_ROOM_TILES)
          end

          # A SPRITE THAT IS NOT SHOWN LETS GO OF ITS ROOM, so another pose can have it. The room
          # keeps its pose, and the sprite forgets what it was showing, so it takes a room again
          # when it is shown.
          def emit_let_go_of_shared_room(obj)
            rooms = obj.rooms
            none = gensym
            emit_number(TMP, room_held_at(rooms, obj.room_member))
            emit(ASM.ldr(ACC, TMP))
            emit(ASM.cmp_imm(ACC, rooms.count))
            emit_branch(:bcond, none, cond: :hs)
            store_word_immediate(NO_FRAME, var_addr(resident_frame_var(obj)))
            emit_number(TMP, obj.room_member)
            emit_call_cold_routine(shared_room_label(rooms, :let_go))
            place_label(none)
          end

          def shared_room_label(rooms, part)
            Messages::MadeNames.make(:shared_rooms, number: @layout.room_tables.keys.index(rooms), part: part.to_s)
          end

          # THE TWO ROUTINES EACH SET OF SHARED ROOMS HAS, after the program's own code and reached
          # only by the calls above. Both are handed which sprite of the set is asking in the
          # second register, and taking one is handed the pose in the first.
          #
          #   r0  the pose, then where its tiles are in the cartridge
          #   r2  the set's record, then where the tiles go in sprite memory
          #   r3  a room's number
          #   r4  where the asking sprite's word is, saying which room it holds
          #   r5  a room's two words
          #   r12 one word read out of them
          def emit_shared_room_routines
            @layout.room_tables.each_key do |rooms|
              emit_shared_room_routine(rooms, :let_go) do
                emit_number(TMP, rooms.count)
                emit(ASM.str(TMP, 4)) # it holds no room now
              end
              emit_shared_room_routine(rooms, :take) { emit_give_room_holding_pose(rooms) }
            end
          end

          # r0 = the bank the list just picked out of a sprite's table is drawn from, for a word
          # that names a list borrowing its group rather than a bank (see
          # ScreenLayout::LENT_MARK). A bank goes straight through.
          def emit_borrow_group_if_lent
            bank = gensym
            emit(ASM.cmp_imm(ACC, ScreenLayout::LENT_MARK))
            emit_branch(:bcond, bank, cond: :lo)
            emit_call_cold_routine(LEND_COLORS)
            place_label(bank)
          end

          LEND_COLORS = :__lend_sprite_colors

          # The frame number the groups lent out are stamped with, counted once a frame as the
          # sprites are written; and how many times a list found no group to borrow.
          LENT_COLORS_FRAME = :__lent_colors_frame
          LENT_COLORS_MISSED = :__lent_colors_missed

          # Count one more frame of sprites being written, for the groups lent to lists.
          def emit_count_lending_frame
            return unless @layout.screen.lending

            load_var(ACC, LENT_COLORS_FRAME)
            emit(ASM.add_imm(ACC, ACC, 1))
            store_var(ACC, LENT_COLORS_FRAME)
          end

          # AT POWER-ON no group is lent to any list, and nothing has been drawn.
          def emit_lent_colors_at_power_on
            lending = @layout.screen.lending
            return unless lending

            emit_number(ACC, 0)
            [LENT_COLORS_FRAME, LENT_COLORS_MISSED].each { |name| store_var(ACC, name) }
            lending.banks.each_index do |k|
              store_var(ACC, lending.last_drawn_var(k))
              store_var(ACC, lending.source_var(k))
            end
            emit_number(ACC, -1)
            lending.banks.each_index { |k| store_var(ACC, lending.holder_var(k)) }
          end

          # LEND A GROUP OF SPRITE COLOURS TO THE LIST A SPRITE IS WEARING, the way the console's
          # own games hand their groups out. Called as a sprite's row is written, with r0 the
          # word its table holds for the list (LENT_MARK plus the list's number); returns r0 the
          # bank to draw it from, shifted to where the row carries it.
          #
          # A group already holding the list is the answer, and is stamped with this frame. A
          # list holding none takes a group nothing was drawn with on this frame or the one
          # before — so a group still in use, by a sprite written later in this frame, is never
          # taken from under it — and its colours are copied in, through any tint in force.
          # Since the rows are written in the gap between frames, the colours and the row that
          # first reads them reach the screen together. A list that finds every group in use
          # is drawn from the first one, in whatever colours that holds, and counted, which is
          # what the console's own games do when they run out.
          #
          # WHERE IT FALLS SHORT OF THEM. Their groups go back the moment the last thing
          # wearing one is removed. Here a group goes back once a whole frame has passed
          # without anything drawn with it, since the rows are written one sprite at a time
          # and nothing says, part way through, which lists the rest will wear. So with every
          # group lent out, a thing arriving on the very frame another leaves is drawn for that
          # one frame in colours not its own.
          #
          # Each group is a few variables of its own rather than a slot in a table, so the
          # groups are walked by code written once per group: there are at most sixteen. The
          # usual call finds its list holding a group already, and puts back only the three
          # registers that search uses.
          #
          # Registers: everything it touches is put back but r0 and r12.
          #   r1  the list's number
          #   r2  this frame's number
          #   r3  a group's variable being compared; then where the group to fill sits
          #   r11 the answer, kept across the copy (which uses r0 to r10)
          def emit_lend_colors_routine
            lending = @layout.screen.lending
            return unless lending

            groups = lending.banks.each_index.to_a
            held = groups.map { gensym }
            free = groups.map { gensym }
            copy = gensym
            lent = gensym
            done = gensym
            emit(ASM.loop_forever) # fall-through guard: only ever entered by the call
            place_label(LEND_COLORS)
            emit(ASM.push(1, 2, 3))
            emit(ASM.sub_imm(1, ACC, ScreenLayout::LENT_MARK))
            load_var(2, LENT_COLORS_FRAME)
            groups.each do |k|
              load_var(3, lending.holder_var(k))
              emit(ASM.cmp_reg(3, 1))
              emit_branch(:bcond, held[k], cond: :eq)
            end
            emit(ASM.push(4, 5, 6, 7, 8, 9, 10, 11, 14))
            groups.each do |k|
              load_var(3, lending.holder_var(k))
              emit(ASM.cmp_imm(3, 0))
              emit_branch(:bcond, free[k], cond: :lt)
              load_var(3, lending.last_drawn_var(k))
              emit(ASM.add_imm(3, 3, 1))
              emit(ASM.cmp_reg(3, 2))
              emit_branch(:bcond, free[k], cond: :lo)
            end
            load_var(3, LENT_COLORS_MISSED)
            emit(ASM.add_imm(3, 3, 1))
            store_var(3, LENT_COLORS_MISSED)
            emit_number(ACC, lending.banks.first << OBJ_BANK_SHIFT)
            emit_branch(:b, lent)
            groups.each do |k|
              place_label(free[k])
              store_var(1, lending.holder_var(k))
              store_var(2, lending.last_drawn_var(k))
              emit_load_data_address(ACC, lending.blob)
              emit(ASM.lsl_imm(3, 1, COLOR_SET_SHIFT))
              emit(ASM.add_reg(ACC, ACC, 3))
              store_var(ACC, lending.source_var(k))
              emit_number(11, lending.banks[k] << OBJ_BANK_SHIFT)
              emit_number(3, lending.group_at(k))
              emit_branch(:b, copy)
            end
            place_label(copy)
            @palette_tint.emit_colors_into_bank_held(PaletteTint::COLORS_IN_A_BANK)
            emit(ASM.mov_reg(ACC, 11))
            place_label(lent)
            emit(ASM.pop(4, 5, 6, 7, 8, 9, 10, 11, 14))
            emit_branch(:b, done)
            groups.each do |k|
              place_label(held[k])
              store_var(2, lending.last_drawn_var(k))
              emit_number(ACC, lending.banks[k] << OBJ_BANK_SHIFT)
              emit_branch(:b, done) unless k == groups.last
            end
            place_label(done)
            emit(ASM.pop(1, 2, 3))
            emit(ASM.bx(14))
            # Where it ends, so a profile of the finished game can name it (see
            # GBA#lowered_routine_addresses).
            place_label(:"#{LEND_COLORS}_end")
          end

          def emit_shared_room_routine(rooms, part)
            label = shared_room_label(rooms, part)
            emit(ASM.loop_forever) # fall-through guard: only ever entered by the call
            place_label(label)
            emit(ASM.push(4, 5, 14))
            emit(ASM.lsl_imm(4, TMP, ROOMS::HELD_WORD_SHIFT))
            emit_number(5, room_held_at(rooms, 0))
            emit(ASM.add_reg(4, 4, 5))
            emit_number(2, room_table(rooms))
            emit_drop_one_room_user(rooms)
            yield
            emit(ASM.pop(4, 5, 15))
            # Where it ends, so a profile of the finished game can name it (see
            # GBA#lowered_routine_addresses).
            place_label(:"#{label}_end")
          end

          # One fewer sprite draws from the room the asking sprite holds, if it holds one.
          def emit_drop_one_room_user(rooms)
            none = gensym
            emit(ASM.ldr(3, 4))
            emit(ASM.cmp_imm(3, rooms.count))
            emit_branch(:bcond, none, cond: :hs)
            emit(ASM.lsl_imm(5, 3, ROOMS::ROOM_WORDS_SHIFT))
            emit(ASM.add_reg(5, 5, 2))
            emit(ASM.ldr_offset(ADDR, 5, ROOMS::USERS_AT))
            emit(ASM.sub_imm(ADDR, ADDR, 1))
            emit(ASM.str_offset(ADDR, 5, ROOMS::USERS_AT))
            place_label(none)
          end

          # GIVE THE ASKING SPRITE A ROOM HOLDING THE POSE, and count it among the room's users: the
          # room already holding the pose, if one is, used or not, and then nothing is copied. Or
          # else a room nobody draws from, with the pose copied into it. There is always one of
          # those (see SpriteLayout::SharedRooms), so the second walk always stops at one; it is
          # held to the rooms there are all the same, and would take the last of them.
          def emit_give_room_holding_pose(rooms)
            found = gensym
            take = gensym
            emit_walk_rooms(rooms, 0, found) { emit(ASM.cmp_reg(ADDR, ACC)) }
            emit_walk_rooms(rooms, ROOMS::USERS_AT, take) { emit(ASM.cmp_imm(ADDR, 0)) }
            emit(ASM.sub_imm(5, 5, ROOMS::ROOM_WORDS_BYTES))
            emit(ASM.sub_imm(3, 3, 1))
            place_label(take)
            emit(ASM.str(ACC, 5)) # the room holds this pose now
            emit_number(ADDR, rooms.frame_bytes)
            emit(ASM.mul(TMP, ACC, ADDR))
            emit_load_data_address(ACC, rooms.frames)
            emit(ASM.add_reg(ACC, ACC, TMP)) # from the pose's frame in the cartridge
            emit_number(ADDR, rooms.units * 32)
            emit(ASM.mul(2, 3, ADDR))
            emit_number(ADDR, OBJ_TILE_BASE + (rooms.first * 32))
            emit(ASM.add_reg(2, 2, ADDR)) # ...to the room
            sharers = @layout.screen.objects.filter_map { |name, obj| ":#{declared_name(name)}" if obj.rooms == rooms }.uniq
            @emitter.note_video_copy("sending sprite #{sharers.join(', ')} its next frame", rooms.frame_bytes)
            emit_start_copy_engine(from: in_register(ACC), to: in_register(2),
                                   control: (rooms.frame_bytes / 4) | DMA_ENABLE | DMA_32BIT)
            place_label(found)
            emit(ASM.ldr_offset(ADDR, 5, ROOMS::USERS_AT))
            emit(ASM.add_imm(ADDR, ADDR, 1))
            emit(ASM.str_offset(ADDR, 5, ROOMS::USERS_AT))
            emit(ASM.str(3, 4)) # the asking sprite holds it
          end

          # Walk the rooms from the first, r3 counting them and r5 at each one's two words, until
          # the word +offset+ into one passes the test the block makes, and go to +stop+ there.
          # Falls through past the last room.
          def emit_walk_rooms(rooms, offset, stop)
            again = gensym
            emit_number(3, 0)
            emit(ASM.mov_reg(5, 2))
            place_label(again)
            emit(ASM.ldr_offset(ADDR, 5, offset))
            yield
            emit_branch(:bcond, stop, cond: :eq)
            emit(ASM.add_imm(5, 5, ROOMS::ROOM_WORDS_BYTES))
            emit(ASM.add_imm(3, 3, 1))
            emit(ASM.cmp_imm(3, rooms.count))
            emit_branch(:bcond, again, cond: :ne)
          end

          # COPY THE FRAME THIS SPRITE IS SHOWING INTO ITS ROOM, when it is not the one already
          # there. The cartridge holds every frame at one stride, so the frame's start is the
          # pose times the stride, and one transfer moves it: whole words, since a frame is a
          # whole number of tiles and a tile is a whole number of words. Done in the gap after
          # the screen is drawn, with the rest of the sprite table, so the frame and the table
          # entry pointing at it change together.
          def emit_send_object_frame(obj, name)
            already = gensym
            @lowering.value(obj.pose)
            load_var(TMP, resident_frame_var(obj))
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, already, cond: :eq)
            store_var(ACC, resident_frame_var(obj))
            emit_number(TMP, obj.frame_bytes)
            emit(ASM.mul(2, ACC, TMP))                    # r2 = where this frame starts in the blob
            emit_load_data_address(ACC, obj.frames)
            emit(ASM.add_reg(ACC, ACC, 2))                # from the frame in the cartridge
            @emitter.note_video_copy("sending sprite :#{declared_name(name)} its next frame", obj.frame_bytes)
            emit_start_copy_engine(from: in_register(ACC), to: OBJ_TILE_BASE + (obj.tile_index * 32),
                                   control: (obj.frame_bytes / 4) | DMA_ENABLE | DMA_32BIT)
            place_label(already)
          end

          # A sprite named the way the author named it, for the build's list of what is copied when;
          # the build's own name is all a sprite they named nothing for has.
          def declared_name(name) = @layout.screen.picture.objects.find { |node| node.name == name }&.declared || name

          def emit_call_cold_routine(label) = @call_cold_routine.call(label)

          # Add the room a sprite sharing rooms is drawn from to the tile number in r0, which counts
          # from its first room (see #emit_take_shared_room).
          def emit_add_room_tiles(obj)
            return unless obj.rooms

            load_var(TMP, OBJ_ROOM_TILES)
            emit(ASM.add_reg(ACC, ACC, TMP))
          end

          # COPY A POOL'S POSE INTO SPRITE MEMORY THE FIRST TIME ONE OF ITS THINGS SHOWS IT since
          # the scene took over (see PoseSends). Its byte says whether it is there; nought, and
          # the pose's run of tiles is copied out of the cartridge to where the whole set would
          # have gone, so the table entries every pose's draw already writes point at it.
          #
          #   r0  the pose, then where its tiles are in the cartridge
          #   r1  its byte, then its table, then the copy engine's address
          #   r2  its word in the table, then the copy's size and how it is told to run
          #   r3  where its tiles go in sprite memory
          def emit_send_pose_first_shown(pool, pose)
            done = gensym
            @lowering.value(pose)
            emit_number(TMP, pool.count)
            emit(ASM.cmp_reg(ACC, TMP))
            emit_branch(:bcond, done, cond: :hs) # a pose the pool does not have shows nothing new
            emit_number(TMP, @layout.pose_sent_bytes.fetch(pool.blob))
            emit(ASM.add_reg(TMP, TMP, ACC))
            emit(ASM.ldrb_offset(2, TMP, 0))
            emit(ASM.cmp_imm(2, 0))
            emit_branch(:bcond, done, cond: :ne) # sent already
            emit_number(2, 1)
            emit(ASM.strb(2, TMP))
            emit_load_data_address(TMP, pool.table)
            emit(ASM.ldr_reg_lsl(2, TMP, ACC, 2))
            emit(ASM.lsl_imm(3, 2, 16))
            emit(ASM.lsr_imm(3, 3, 11))                  # r3 = how far into the set, in bytes
            emit_load_data_address(ACC, pool.blob)
            emit(ASM.add_reg(ACC, ACC, 3))
            emit_number(TMP, OBJ_TILE_BASE + (pool.tile_index * 32))
            emit(ASM.add_reg(3, 3, TMP))
            emit(ASM.lsr_imm(2, 2, 16))
            emit(ASM.lsl_imm(2, 2, 3))                   # its tiles, eight words each
            emit(ASM.cmp_imm(2, 0))
            emit_branch(:bcond, done, cond: :eq)         # a count of nought would copy the most there is
            emit_number(TMP, DMA_ENABLE | DMA_32BIT)
            emit(ASM.orr_reg(2, 2, TMP))
            emit_start_copy_engine(from: in_register(ACC), to: in_register(3), control: in_register(2))
            place_label(done)
          end

          # NOTHING OF A POOL'S POSES IS IN SPRITE MEMORY YET, as its scene takes over: every
          # pose's byte back to nought, and the blank tile its filler pieces draw cleared (see
          # PoseSends). Nought is loaded once and stored a word at a time, since both are a few words.
          def emit_forget_poses_sent(pool)
            emit_number(ACC, 0)
            at = @layout.pose_sent_bytes.fetch(pool.blob)
            words = (0...pool.count).step(4).map { |offset| at + offset }
            if pool.blank_at
              blank = OBJ_TILE_BASE + ((pool.tile_index + pool.blank_at) * 32)
              words += (0...pool.blank_bytes).step(4).map { |offset| blank + offset }
            end
            words.each do |address|
              emit_number(TMP, address)
              emit(ASM.str(ACC, TMP))
            end
          end

          # An upright sprite: position and size straight into its slot.
          def emit_draw_object_upright(obj, row, mirror = nil, piece = 0)
            return emit_draw_object_sized_poses(obj, row, mirror, piece) unless obj.alike

            # attr0 = (y & 0xFF) | shape + 256-color flag. The offset is where this pose
            # sits inside the canvas it was drawn on — added back so trimming the blank
            # away cannot move the picture (see SpriteCut#pose_box).
            @lowering.value(obj.y)
            emit_add_const(ACC, ACC, obj.offset_y, TMP) unless obj.offset_y.zero?
            emit_move_far_place_off_screen(ROWS_DRAWN_AS_PUT, SCREEN_HEIGHT) unless drawn_as_put?(obj.y, ROWS_DRAWN_AS_PUT, obj.offset_y)
            mask_into_acc(0xFF)
            orr_acc(obj.attr0_base)
            emit_store_acc_in_row(row, 0)
            emit_copy_attr0_to_twin(mirror)
            # attr1 = (x & 0x1FF) | size
            @lowering.value(obj.x)
            emit_add_const(ACC, ACC, obj.offset_x, TMP) unless obj.offset_x.zero?
            emit_move_far_place_off_screen(COLUMNS_DRAWN_AS_PUT, SCREEN_WIDTH) unless drawn_as_put?(obj.x, COLUMNS_DRAWN_AS_PUT, obj.offset_x)
            mask_into_acc(0x1FF)
            orr_acc(obj.attr1_base)
            emit_store_acc_in_row(row, 2)
            store_halfword_acc(mirror + 2) if mirror
            # attr2 = which tiles to draw = this sprite's base tile + pose * stride
            # (palette bank/priority left at 0). A fixed pose folds to a constant.
            emit_object_tile_number(obj, row)
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

          # How far along or down a pose stands from its canvas's corner is eight bits of
          # its word, so this is both the mask that reads one and the furthest one can be.
          POSE_DISTANCE = 0xFF

          def emit_stash_object_position(obj)
            @lowering.value(obj.y)
            store_var(ACC, POSE_DRAW_Y)
            @lowering.value(obj.x)
            store_var(ACC, POSE_DRAW_X)
          end

          def emit_draw_object_sized_poses(obj, row, mirror = nil, piece = 0)
            # A sprite of several pieces had this done once for all of them, by the caller.
            emit_stash_object_position(obj) if obj.pieces == 1
            emit_load_pose_word(obj, piece)
            # attr0 = (y + how far down) & 0xFF, then the shape out of bits 10..11.
            load_var(ACC, POSE_DRAW_Y)
            emit(ASM.lsr_imm(TMP, POSE_WORD, 22))
            # The two bits above the distance say which way round the pose is drawn, and
            # are set only for a sprite with a pose that is. The test of how far off the
            # screen the row is reads the whole sum, so they are taken off before it.
            emit(ASM.and_imm(TMP, TMP, POSE_DISTANCE)) if obj.mirrors&.any?
            emit(ASM.add_reg(ACC, ACC, TMP))
            emit_move_far_place_off_screen(ROWS_DRAWN_AS_PUT, SCREEN_HEIGHT) unless drawn_as_put?(obj.y, ROWS_DRAWN_AS_PUT, 0, POSE_DISTANCE)
            mask_into_acc(0xFF)
            emit(ASM.and_imm(TMP, POSE_WORD, 0x0C00))   # shape, still at bit 10
            emit(ASM.orr_reg_lsl(ACC, ACC, TMP, 4))     # ...into bit 14
            orr_acc(obj.attr0_base) unless obj.attr0_base.zero?
            emit_store_acc_in_row(row, 0)
            emit_copy_attr0_to_twin(mirror)
            # attr1 = (x + how far right) & 0x1FF, then the size out of bits 12..13.
            load_var(ACC, POSE_DRAW_X)
            emit(ASM.lsr_imm(TMP, POSE_WORD, 14))
            emit(ASM.and_imm(TMP, TMP, POSE_DISTANCE))
            emit(ASM.add_reg(ACC, ACC, TMP))
            emit_move_far_place_off_screen(COLUMNS_DRAWN_AS_PUT, SCREEN_WIDTH) unless drawn_as_put?(obj.x, COLUMNS_DRAWN_AS_PUT, 0, POSE_DISTANCE)
            mask_into_acc(0x1FF)
            emit(ASM.and_imm(TMP, POSE_WORD, 0x3000))   # size, still at bit 12
            emit(ASM.orr_reg_lsl(ACC, ACC, TMP, 2))     # ...into bit 14
            emit_pose_flip_bits if obj.mirrors&.any?
            orr_acc(obj.attr1_base) unless obj.attr1_base.zero?
            emit_store_acc_in_row(row, 2)
            store_halfword_acc(mirror + 2) if mirror
            # attr2 = the pose's own first tile, out of bits 0..9. Two shifts rather than a
            # mask: a ten-bit mask is not one of the immediates this chip can carry.
            emit(ASM.lsl_imm(ACC, POSE_WORD, 22))
            emit(ASM.lsr_imm(ACC, ACC, 22))
            emit_add_room_tiles(obj)
            orr_acc(obj.attr2_base) unless obj.attr2_base.zero?
            orr_picked_attr2(obj)
            emit_store_acc_in_row(row, 4)
            store_halfword_acc(mirror + 4) if mirror
          end

          # Carry "draw this one backwards" and "draw it upside down" from the pose word into
          # the sprite's own entry: the two bits sit side by side in both, so one shift carries
          # both. Only emitted for a sprite that actually has a turned pose, so a sprite whose
          # poses merely differ in size pays nothing for it.
          def emit_pose_flip_bits
            emit(ASM.lsr_imm(TMP, POSE_WORD, 18))                  # bits 30 and 31 down to 12 and 13...
            emit(ASM.and_imm(TMP, TMP, OBJ_HFLIP | OBJ_VFLIP))     # ...and nothing else with them
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
              return emit_number(POSE_WORD, words[at])
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
          def emit_copy_attr0_to_twin(mirror)
            return unless mirror

            orr_acc(OBJ_WINDOW_MODE)
            store_halfword_acc(mirror)
          end

          # Put the window away when the fade in force is not behind this sprite — a fade
          # over the whole screen, or one placed further forward. The sprite itself has
          # already been written, so this only has to hide the twin — one window per piece
          # for a sprite drawn as several objects, since the hole has to be the shape of
          # the whole picture. Asked once for all of them, after they are drawn.
          def emit_hide_twin_unless_faded(twin, pieces)
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
          def emit_draw_object_transformed(obj, row, mirror = nil)
            half_w = obj.width / 2
            half_h = obj.height / 2
            # attr0 = ((y - half_h) & 0xFF) | rotate/scale + double-size + shape/color
            @lowering.value(obj.y)
            emit(ASM.sub_imm(ACC, ACC, half_h)) unless half_h.zero?
            if obj.height * 2 > TALLEST_BOX_UNSEEN_BELOW
              emit_tall_box_attr0(obj)
            else
              emit_move_far_place_off_screen(ROWS_DRAWN_AS_PUT, SCREEN_HEIGHT)
              mask_into_acc(0xFF)
              orr_acc(obj.attr0_base | OBJ_ROTSCALE | OBJ_DOUBLE_SIZE)
            end
            emit_store_acc_in_row(row, 0)
            emit_copy_attr0_to_twin(mirror)
            # attr1 = ((x - half_w) & 0x1FF) | size | affine-group index (bits 9..13)
            @lowering.value(obj.x)
            emit(ASM.sub_imm(ACC, ACC, half_w)) unless half_w.zero?
            emit_move_far_place_off_screen(TURNED_COLUMNS_DRAWN_AS_PUT, SCREEN_WIDTH)
            mask_into_acc(0x1FF)
            orr_acc(obj.attr1_base | (obj.affine_slot << 9))
            emit_store_acc_in_row(row, 2)
            # The twin points at the same affine group, so it turns and resizes with the
            # sprite and the hole stays the shape of the picture.
            store_halfword_acc(mirror + 2) if mirror
            emit_object_tile_number(obj, row)
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
            emit_number(Divide::DIV_NUM, Build::SCALE_ONE * Affine::ONE_TH)
            emit_call_divide_routine                            # r0 = SCALE_ONE * 256 / size
            emit_number(TMP, Affine::MAX)
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
          # variable pose (facing / animation) is computed at run time. It is the third half
          # of the sprite's +row+.
          def emit_object_tile_number(obj, row)
            fixed = const_int(obj.pose)
            if fixed && !obj.picks_attr2? && !obj.rooms
              emit_store_number_in_row(row, 4, obj.tile_index + (fixed * obj.per_pose) | obj.attr2_base)
            elsif fixed
              emit_number(ACC, obj.tile_index + (fixed * obj.per_pose) | obj.attr2_base)
              emit_add_room_tiles(obj)
              orr_picked_attr2(obj)
              emit_store_acc_in_row(row, 4)
            else
              @lowering.value(obj.pose)                          # r0 = pose index
              emit_number(TMP, obj.per_pose)   # r1 = stride between poses
              emit(ASM.mul(2, ACC, TMP))                      # r2 = pose * stride (rd must differ from rm)
              emit_add_const(ACC, 2, obj.tile_index, TMP)   # r0 = r2 + base tile
              emit_add_room_tiles(obj)
              orr_acc(obj.attr2_base) unless obj.attr2_base.zero?
              orr_picked_attr2(obj)
              emit_store_acc_in_row(row, 4)
            end
          end

          # r0 holds the row, or the column, a box is to stand at. Outside +places+, the ones
          # it is drawn at as put, make it +edge+: the first row below the screen, where a
          # box no taller than TALLEST_BOX_UNSEEN_BELOW shows nothing, or the first column
          # right of it, where no box is wide enough to reach back round. The sprite is
          # still in the table there, so anything reading the table back finds it, just off
          # the edge.
          #
          # One unsigned compare catches both ends, because a place too far up or left is
          # still below nought once the room above or to the left is added, and reads as a
          # very large number. Three instructions, none of them a branch.
          def emit_move_far_place_off_screen(places, edge)
            emit(ASM.add_imm(TMP, ACC, -places.begin))
            emit(ASM.cmp_imm(TMP, places.size))
            emit(ASM.mov_imm_cond(:hs, ACC, edge))
          end

          # THE FIRST WORD OF A SPRITE WHOSE BOX NO ROW KEEPS OFF THE SCREEN: 128 rows, where
          # only 96 are counted past the bottom edge. Standing at the first row below, its
          # end comes round onto the top.
          #
          # So when none of its picture is on the screen, it is stood at that row as a plain
          # sprite instead: the two bits that say "turned" and "in a box twice the size" are
          # left out of the word, the console draws it in a box of its own 64 rows, and that
          # box is unseen there. It is still a row of the table, which is what tells it from
          # a sprite the game hid.
          #
          # r0 holds the row the box's top stands at, and comes back as the whole word. The
          # picture can reach only some rows of the box (see Affine#rows_reached), and it is
          # drawn turned while any of those is on the screen. The one compare decides both
          # the row and the bits, and nothing between it and them changes the flags.
          #
          # For a sprite that only turns, that is the whole answer: the rows that come round
          # are rows its picture never reaches, so nothing of it is seen at the other edge.
          # For one that resizes, the picture fills the box, and the rows it is drawn over
          # are more than the table counts. So part way off the top or the bottom, the far
          # end of such a sprite shows at the other edge, and nothing here can stop it
          # (see Reference::TurnedBox, which draws the same).
          def emit_tall_box_attr0(obj)
            reached = Affine.rows_reached(obj.width, obj.height, scales: obj.scales)
            emit(ASM.add_imm(TMP, ACC, reached.end - 1))
            emit_number(ADDR, reached.size - 1 + SCREEN_HEIGHT) # can be more bits than a compare carries
            emit(ASM.cmp_reg(TMP, ADDR))
            emit(ASM.mov_imm_cond(:hs, ACC, SCREEN_HEIGHT))
            mask_into_acc(0xFF)
            emit_number(TMP, obj.attr0_base | OBJ_ROTSCALE | OBJ_DOUBLE_SIZE)
            emit_number(ADDR, obj.attr0_base)
            emit(ASM.mov_reg_cond(:hs, TMP, ADDR))
            emit(ASM.orr_reg(ACC, ACC, TMP))
          end

          # Is +place+ a number settled while building, and one a box is drawn at as put
          # (one of +places+) wherever from +nearest+ to +furthest+ along from it the box
          # stands? Then it needs no test: the letters of a line of text, whose places are
          # written in the program.
          def drawn_as_put?(place, places, nearest, furthest = nearest)
            fixed = const_int(place)
            !fixed.nil? && places.cover?(fixed + nearest) && places.cover?(fixed + furthest)
          end

          # r0 &= mask, using a scratch register so any mask width is fine.
          def mask_into_acc(mask)
            emit_number(TMP, mask)
            emit(ASM.and_reg(ACC, ACC, TMP))
          end

          # r0 |= value, via a scratch register (values here have bits too high for an
          # inline immediate).
          def orr_acc(value)
            emit_number(TMP, value)
            emit(ASM.orr_reg(ACC, ACC, TMP))
          end
        end
      end
    end
  end
end
