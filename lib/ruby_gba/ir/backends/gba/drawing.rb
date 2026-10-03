# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Direct-color (Mode 3) drawing, and the screen-mode/page management around it:
        # which kind of screen is up, what a scene does to it as it takes over, the shapes
        # and pictures a game paints itself, and text.
        #
        # What the console draws FOR the game lives beside this, one file each: the sprites
        # ({SpriteDrawing}), the background layers ({BackgroundDrawing}), and what happens to
        # the whole picture — camera, fade, tint ({ScreenEffects}). Copying data into video
        # memory, which all of them do, is {BlobUpload}. A change of screen sets the sprites
        # and backgrounds up again, which is why this holds the first two.
        #
        # What the prepare passes decide about a program — which images it has, where every
        # background and sprite went ({ScreenLayout}), the shared palette, the mode facts —
        # arrives as one record, `layout`, handed over through `layout=` once
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
          include Console::Hardware
          include EmitterCalls

          def initialize(emitter:, primitives:, lowering:, divide:, framebuffer:, raster:, palette_tint:,
                          layer_blend:, buffered:, uploads:, sprite_drawing:, background_drawing:,
                          backing_info:, call_cold_routine:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @divide = divide
            @framebuffer = framebuffer
            @raster = raster
            @palette_tint = palette_tint
            @layer_blend = layer_blend
            @buffered = buffered
            @uploads = uploads # copies data out of the cartridge into video memory (see {BlobUpload})
            # The sprites' and the backgrounds' own code, which a change of screen sets up again
            # (see {SpriteDrawing} and {BackgroundDrawing}).
            @sprite_drawing = sprite_drawing
            @background_drawing = background_drawing
            @backing_info = backing_info
            @call_cold_routine = call_cold_routine
            @layout = nil
          end

          attr_writer :layout

          # The prepare-pass results this file reads, bundled into one record and handed
          # over through #layout= once every pass that decides them has run.
          # Where a background's cells are and what to write into one is on its own placement
          # record (see ScreenLayout::MapGrid), which is what a run-time tile change reads. Which screen
          # mode each scene draws in is on +modes+ (see IR::Modes), which is asked rather than
          # copied out field by field.
          #
          # Where every background and sprite went is the +screen+ ({ScreenLayout}) itself,
          # read through it rather than copied out, so a thing the layout decides has one
          # home.
          Layout = Data.define(:screen, :bitmaps, :palette, :indexed_bitmaps, :blob_codecs, :blob_raw_bytes,
                                :modes, :fading, :tiled, :has_objects, :scene_blend, :movement,
                                :scene_sprites, :waits_for_frames) do
            def objects = screen.objects
            def placed_fade = screen.placed_fade
            def backgrounds = screen.backgrounds
            def bg_shared = screen.bg_shared
            def obj_palette_blob = screen.obj_palette_blob
            def obj_palette_units = screen.obj_palette_units
            def scene_art = screen.scene_art
            def scene_layers = screen.scene_layers
            def scene_screens = screen.scene_screens
            def scene_tiles = screen.scene_tiles
            def painted_vram = screen.painted_vram
            def scene_obj_palettes = screen.scene_obj_palettes
            def picture = screen.picture

            # The backgrounds that turn AND sit on the tiled screen — the ones that decide
            # which way the console arranges that screen's layers. A background that turns
            # on `screen :rotozoom` is on a screen of its own, up at a different moment, so
            # it does not (see Guardrails::Checks::TooManyBackgroundLayers, which asks the
            # same question to work out how many scrolling layers are left).
            def turning_layers = modes.select_on_tiled_screen(picture.scenery.select(&:affine))
          end

          # Fill the area itself, which is what clearing means when only part of the picture may
          # be painted: a row-at-a-time block fill over exactly those edges. It does not go
          # through the rectangle verb because that one holds authors to an even width, and an
          # area's width is whatever the author said.
          def emit_fill_area(color)
            scratch = @framebuffer.emit_color_fill_word(color)
            control = @framebuffer.fill_control_for_column(@framebuffer.clip_left,
                                                            @framebuffer.clip_right - @framebuffer.clip_left)
            (@framebuffer.clip_top...@framebuffer.clip_bottom).each do |row|
              @framebuffer.emit_dma_fill_row(scratch, VRAM_START + ((row * SCREEN_WIDTH) + @framebuffer.clip_left) * 2,
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
            return if @layout.modes.switched_per_scene?

            mode = node.mode
            value = if mode == :tiled
                      # A single-mode program never runs #enter_tiled_mode (that's only for
                      # per-scene mode switching), so a turning layer's one-time "no turn, no
                      # resize yet" starting matrix is set here instead.
                      @background_drawing.reset_bg2_affine_if_needed
                      tiled_dispcnt
                    elsif mode == :rotozoom
                      # The rotate/scale layer: this feature always lands the one affine
                      # background it supports on BG2 (see AFFINE_BG in gba.rb), so that's the
                      # one layer Mode 2 needs on here. A single-mode program never runs
                      # #enter_affine_mode (that's only for per-scene mode switching), so the
                      # one-time "no turn, no resize yet" starting matrix is set here instead.
                      @background_drawing.reset_bg2_affine_matrix
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
            @emitter.write_reg16(REG_DISPCNT, value | initial_forced_blank_bit)
          end

          # KEEP THE PICTURE SWITCHED OFF UNTIL THE FIRST FRAME HAS BEEN SET UP.
          #
          # Everything a game says before its loop — a screen painted, a flash it opens on — is
          # carried onto the screen by work done between frames: the effect a routine writes
          # there, the sprites placed there. Switching the picture on where the screen is
          # declared shows it before any of that has happened, and when setting up runs past the
          # end of a frame, which painting the whole screen does, that frame goes out as the
          # bare picture: a game opening on a white flash shows its first picture at full
          # brightness first.
          #
          # So the screen is declared with the picture held off, and the first wait for the gap
          # between frames switches it on (#emit_end_forced_blank). That gap is the one moment
          # nothing is drawn, and the work between frames runs in it too, so the first line
          # the display draws has all of it in force whichever of them comes first. A game that
          # sets up inside one frame loses nothing: the gap it waits for is the one it would
          # have been shown after anyway. A program that never waits for a frame has no gap to
          # switch it on in, so it is shown as soon as it is declared, as before.
          #
          # What a console shows while its picture is held off is plain white.
          def initial_forced_blank_bit = @layout.waits_for_frames ? FORCED_BLANK : 0

          # Switch the picture on, at the gap between frames. Every frame rather than the
          # first alone, because it is three instructions where remembering whether it was
          # the first would cost the same; on every frame after the first it changes nothing.
          def emit_end_forced_blank
            return unless @layout.waits_for_frames

            emit(ASM.load_immediate(TMP, REG_DISPCNT))
            emit(ASM.load_halfword(ACC, TMP))
            emit(ASM.bic_imm(ACC, ACC, FORCED_BLANK))
            emit(ASM.store_halfword(ACC, TMP))
          end

          # WHICH OF THE CONSOLE'S TILE ARRANGEMENTS THIS PROGRAM NEEDS, and which layers
          # to turn on — the whole display-control value for a tiled screen.
          #
          # The console arranges its tile layers two ways, and the difference is what the
          # layers ARE rather than how many: mode 0 is four layers that scroll and nothing
          # that turns; mode 1 is two that scroll plus one that turns and resizes. A game
          # needs the second exactly when it turns a background — a title where something
          # flies at the player over a backdrop, a map that spins inside a fixed frame, a
          # road that banks under a sky — and nothing in a program says so, because
          # turning a background IS saying so. (The third arrangement, mode 2, is `screen
          # :rotozoom`: two turning layers and nothing else, and it keeps its own path.)
          # +on+ names the layers to switch on and +turning+ which arrangement THIS screen
          # wants. Given neither, this is the value for the screen the console is set up for
          # BEFORE any scene has run — see #first_scene_layers. The sprite layer is added by the
          # callers, which all do it the same way for every screen.
          def tiled_dispcnt(on = nil, turning: nil)
            boot = (on.nil? && turning.nil?) ? first_scene_layers : nil
            on = boot.on if boot
            turning = (boot ? boot.turning : turning_background?) if turning.nil?
            (turning ? MODE_1 : MODE_0) | tiled_bg_enable_bits(*[on].compact)
          end

          # THE SCREEN THE CONSOLE IS SET UP FOR BEFORE ANY SCENE HAS RUN, or nothing at all
          # for a game whose scenes all want the same one — there the whole program IS the
          # screen and every layer in it belongs on.
          #
          # Where the scenes differ, boot names the FIRST scene's layers rather than the
          # union of every background in the game. A layer switched on before its own scene
          # has told it where its map is does not draw blank: nought points at the start of
          # video memory, which is where the tile PICTURES are, so it draws the art as
          # though it were a grid, in front of everything. Naming too FEW layers instead is
          # a black frame, which is the safe way to be wrong for the one frame it lasts.
          def first_scene_layers = @layout.scene_layers.values.first

          def turning_background? = @layout.turning_layers.any?

          # The DISPCNT enable bit per layer, and the OR of them for the layers this
          # program's backgrounds actually landed on — at least BG0, so a tiled screen
          # always has one layer on. Read off the placements rather than counted, because
          # a turning layer is always BG2 (that is where the console keeps the hardware)
          # however few plain layers sit beside it.
          BG_ENABLES = [BG0_ENABLE, BG1_ENABLE, BG2_ENABLE, BG3_ENABLE].freeze
          def tiled_bg_enable_bits(used = program_bg_layers)
            bits = used.reduce(0) { |on, layer| on | BG_ENABLES[layer] }
            # ...and the object window, for a program that keeps sprites out of a fade.
            bits |= OBJ_WINDOW_ENABLE if @layout.placed_fade.any?
            bits
          end

          # The layers a program that says nothing about scenes uses — every one its
          # backgrounds landed on, and the first layer for a program with none, so a tiled
          # screen always has one on.
          #
          # A SCENE that names none of them is a different thing and keeps its empty list:
          # it draws no scenery, so it wants no layer, and handing it one anyway leaves that
          # layer on with nobody to point it anywhere. A title screen of sprites and words
          # showed the game's tile pictures as a grid behind them for exactly that reason.
          def program_bg_layers
            used = @layout.backgrounds.each_value.map(&:bg).uniq
            used.empty? ? [0] : used
          end

          # One-time boot for a program that switches the hardware per scene: put the
          # display in the default scene's mode. A buffered program also uploads its
          # color table here (palette memory survives mode switches), then starts by
          # showing page 0 and drawing into page 1; a tiled default brings up the tile
          # layers and sprites; a direct default is the plain Mode 3 write.
          def emit_boot_screen
            upload_palette if @layout.modes.any_buffered? # the palette exists only for the buffered path
            # Held off until the first frame is set up, as a single-screen game's is (see
            # #initial_forced_blank_bit). Only here: a scene changing the screen later is
            # changing a picture already showing, and must not switch it off.
            held = initial_forced_blank_bit
            case @layout.modes.default_mode
            when :tiled then enter_tiled_mode(held)
            when :affine then enter_affine_mode(held)
            when :buffered then enter_buffered_mode(held)
            else enter_direct_mode(held)
            end
          end

          # Switch the hardware into double-buffered (Mode 4): remember the live DISPCNT
          # so a flip is a cheap bit-toggle, draw into page 1 first, show page 0, and
          # record that buffered is now the live mode.
          # +held+, here and in the three below, is the bit that keeps the picture switched off,
          # given only by the boot (see #emit_boot_screen).
          def enter_buffered_mode(held = 0)
            @background_drawing.reset_bg2_affine_if_needed
            base = MODE_4 | BG2_ENABLE
            @primitives.store_word_immediate(base, @primitives.var_addr(DISPCNT_STATE))
            @primitives.store_word_immediate(PAGE1, @primitives.var_addr(BACKBUF))
            @emitter.write_reg16(REG_DISPCNT, base | held)
            @primitives.store_word_immediate(MODE_BUFFERED, @primitives.var_addr(MODE_STATE))
            # A scene that tints leaves its color table blended, and one that remembers a
            # tint has to be able to trust what is in the table. In a program that crosses
            # to the tiled screen, that screen's own colors have been in this table since —
            # so put the originals back, which is also what makes the remembered tint true
            # again.
            upload_palette if @palette_tint.moves_color_table? && @layout.modes.crosses_display_systems?
          end

          # Switch the hardware into direct-color (Mode 3) and record it as live. Writing
          # the whole register also turns the tile and sprite layers off, so nothing a
          # tiled scene left on screen bleeds under the bitmap one — only BG2 (the
          # framebuffer) shows, which the bitmap scene redraws.
          def enter_direct_mode(held = 0)
            @background_drawing.reset_bg2_affine_if_needed
            @emitter.write_reg16(REG_DISPCNT, MODE_3 | BG2_ENABLE | held)
            @primitives.store_word_immediate(MODE_DIRECT, @primitives.var_addr(MODE_STATE))
          end

          # Switch the hardware into tiled mode (Mode 0). Because the bitmap framebuffer
          # and the tiles share video memory, a bitmap scene overwrites the tile data, so
          # the tile pictures/colors and sprite tiles are (re)uploaded here on entry —
          # cheap, and only on the actual switch. Then turn on the declared background
          # layers (plus the sprite layer if the game has sprites) and record it live.
          # Each background's map and control register are re-set by its own node in the
          # scene body, which runs right after this preamble.
          def enter_tiled_mode(held = 0)
            @background_drawing.reset_bg2_affine_if_needed
            @background_drawing.emit_boot_backgrounds if @layout.tiled && !@layout.backgrounds.empty? # shared BG palette + tile pictures
            @sprite_drawing.emit_boot_objects if @layout.has_objects                             # sprite palette + tiles, and clear OAM
            @layer_blend.emit_restore_layer_blend if @layer_blend.see_through?     # ...and which one is see-through
            value = tiled_dispcnt
            value |= OBJ_ENABLE | OBJ_1D_MAP if @layout.has_objects
            @emitter.write_reg16(REG_DISPCNT, value | held)
            @primitives.store_word_immediate(MODE_TILED, @primitives.var_addr(MODE_STATE))
          end

          # Switch the hardware into the affine layer (Mode 2): re-upload the shared BG
          # palette/tile pictures on entry, same reason #enter_tiled_mode does — bitmap
          # and tile VRAM overlap, so a bitmap scene overwrites what the affine
          # background's tiles need. Its own map/matrix are re-set right after this by
          # the background's own node in the scene body (see BackgroundDrawing#emit_background_hardware),
          # the same as a regular tiled layer's.
          def enter_affine_mode(held = 0)
            @background_drawing.reset_bg2_affine_matrix # the one-time "no turn, no resize yet" starting matrix
            @background_drawing.emit_boot_backgrounds if @layout.tiled && !@layout.backgrounds.empty?
            @sprite_drawing.emit_boot_objects if @layout.has_objects
            @layer_blend.emit_restore_layer_blend if @layer_blend.see_through?
            value = MODE_2 | BG2_ENABLE
            value |= OBJ_ENABLE | OBJ_1D_MAP if @layout.has_objects
            @emitter.write_reg16(REG_DISPCNT, value | held)
            @primitives.store_word_immediate(MODE_AFFINE, @primitives.var_addr(MODE_STATE))
          end

          # Emitted at the top of each scene when a program switches the hardware per
          # scene: switch into this scene's mode, but only if it isn't already there (a
          # transition). Steady frames — the same scene running again — cost just the
          # compare, and a buffered scene's DISPCNT is left to the page flip.
          # WHAT A SCENE TELLS THE DISPLAY AS IT TAKES OVER. Both halves are skipped by the
          # programs that do not need them, so a game with one screen and one set of layers
          # emits nothing here at all.
          #
          # SET UP, THEN SWITCH ON — the order matters and cannot be seen by reading the
          # registers once a frame. Pointing a layer at its map is the long part (a map per
          # layer, sent in one go) and the console draws the picture while it happens, so a
          # layer switched on first draws the tile pictures as a grid for whatever is left of
          # the frame. Switched on last, a layer either draws its own scenery or is not on
          # yet, and not on yet is one frame of backdrop.
          def emit_scene_preamble(name)
            emit_scene_mode(name) if @layout.modes.switched_per_scene?
            emit_scene_scenery(name)
            emit_scene_blend(name)
            emit_scene_layers(name)
          end

          # WHICH LAYERS THIS SCENE BLENDS, for a game whose scenes want different answers.
          #
          # The blend unit is told which layers to mix by NUMBER, and scenes take turns with
          # the console's layers — so the number the see-through layer sits on belongs to
          # the scene rather than to the game. A scene that sees through nothing says so
          # here too, which is what stops whichever background inherited that number being
          # blended in its place.
          #
          # A game whose scenes all want the same thing has nothing here: boot's one write
          # stands for the whole run (see LayerBlend#blend_control_by_scene).
          def emit_scene_blend(name)
            wanted = @layout.scene_blend[name]
            write_reg16(REG_BLDCNT, wanted) if wanted
            @layer_blend.emit_screen_marker(name)
          end

          # WHICH SCENE'S SCENERY IS SET UP, so a scene taking over points its layers at its
          # own maps and a scene already running points them nowhere.
          SCENE_SCENERY_STATE = :_scene_scenery

          # PUT THIS SCENE'S BACKGROUNDS UP, ONCE, AS IT TAKES OVER.
          #
          # Pointing a layer at a background sends the whole map into video memory and puts
          # the layer's scroll back to the top-left corner. That is right the first time and
          # wrong every time after: a background declared inside a scene has its statement in
          # that scene's own routine, which runs on every frame the scene is active, so doing
          # it there undid the scroll the game had asked for and any cell it had changed.
          #
          # Guarded the same way a scene's sprite pictures are, and for the same reason:
          # staying in a scene costs one compare a frame, changing scene costs the setup.
          # A game whose scenery belongs to no scene emits none of this.
          def emit_scene_scenery(name)
            arriving = scene_handover.arriving(name)
            # A SCENE WITH NO SCENERY OF ITS OWN STILL TAKES THE LAST ONE'S DOWN, so it says
            # nobody's is up. Without this, a scene that comes back after one with no
            # scenery found its own marked as still up and skipped putting it up again —
            # keeping the cells and painted tiles of the last visit, where the scene rules
            # say it goes up as declared (see IR::SceneHandover). It is one store a frame,
            # and only in a game where some scene has scenery of its own.
            if arriving.empty?
              if @layout.picture.scenery.any?(&:scene)
                @primitives.store_word_immediate(0, @primitives.var_addr(SCENE_SCENERY_STATE))
              end
              return
            end

            emit_on_scene_entry(SCENE_SCENERY_STATE, scene_scenery_marker(name)) do
              emit_with_bg_layers_disabled(name) do
                tiles = @layout.scene_tiles[name]
                @uploads.emit_dma_blob(tiles.blob, VRAM_START + tiles.offset, tiles.units) if tiles
                arriving.each { |node| @background_drawing.emit_background_hardware(node) }
                arriving.each { |node| @background_drawing.emit_copy_tiles_shown_by(node) }
              end
              # The maps just sent are the first ones declared, so what says which map is
              # showing goes back to the first as well (see IR::SceneHandover).
              scene_handover.map_choices_to_reset(name).each { |var| @primitives.store_word_immediate(0, @primitives.var_addr(var)) }
            end
          end

          # SWITCH THE LAYERS OFF WHILE A SCENE'S SCENERY IS SENT, AND ON AGAIN AFTER.
          #
          # Scenes that take turns put their pictures and maps in the same room (see
          # ScreenLayout#place_each_scene), so sending this scene's writes over what the last
          # scene's layers are still pointed at. The console goes on drawing while the copy
          # runs, and a layer left on would show the last scene's maps drawn out of this
          # scene's pictures — garbage — for whatever is left of the frame. Off, it shows the
          # backdrop, which is the safe way to be wrong for part of one frame; the frame after
          # is this scene's scenery, whole.
          #
          # Only the background layers are touched: the sprites, the arrangement and the rest
          # of the display's settings stay as they were. A scene not drawn from tiles has no
          # layers to switch, and is left alone.
          BG_ENABLE_MASK = BG0_ENABLE | BG1_ENABLE | BG2_ENABLE | BG3_ENABLE

          def emit_with_bg_layers_disabled(name)
            screen = @layout.scene_screens[name]
            return yield unless screen

            change_display_control { emit(ASM.bic_imm(ACC, ACC, BG_ENABLE_MASK)) }
            yield
            on = screen.on.reduce(0) { |bits, layer| bits | BG_ENABLES[layer] }
            change_display_control { emit(ASM.orr_imm(ACC, ACC, on)) } unless on.zero?
          end

          # Read the display's settings into ACC, let the block change them, write them back.
          def change_display_control
            emit(ASM.load_immediate(TMP, REG_DISPCNT))
            emit(ASM.load_halfword(ACC, TMP))
            yield
            emit(ASM.store_halfword(ACC, TMP))
          end

          # What a scene does to the screen as it takes over, said once for both backends.
          def scene_handover = IR::SceneHandover.of(@layout.picture)

          # Which scene's scenery is up, counting from 1 so that 0 means "none yet" — which
          # is what boot writes, since the console makes no promise about its memory at
          # power-on and a stale value here would leave the first scene's layers pointing
          # nowhere.
          def scene_scenery_marker(name)
            @layout.picture.scenery.filter_map(&:scene).uniq.index(name) + 1
          end

          # DO THE BLOCK WHEN A SCENE TAKES OVER, AND NOT WHILE IT RUNS.
          #
          # A scene's own routine is reached on every frame it is active, so anything in it
          # that sets the hardware UP rather than moving what is already there has to be
          # guarded — sending a scene's sprite pictures, pointing its layers at its maps.
          # Both are a copy, and both throw away whatever has happened since if repeated.
          #
          # +state+ is a variable naming whose turn it currently is and +marker+ this
          # scene's number in it, counting from 1 so that the 0 boot writes means nobody's.
          # The cost while a scene runs is the compare and the branch.
          def emit_on_scene_entry(state, marker)
            @primitives.load_var(ACC, state)
            @emitter.emit(ASM.cmp_imm(ACC, marker))
            skip = @emitter.gensym
            @emitter.emit_branch(:bcond, skip, cond: :eq) # already this scene's? nothing to do
            yield
            @emitter.emit(ASM.load_immediate(ACC, marker))
            @primitives.store_var(ACC, state)
            @emitter.place_label(skip)
          end

          # The screen this scene draws on, in a program whose scenes differ. One that does
          # not leaves each `screen` node to write the display control inline.
          def emit_scene_mode(name)
            mode = @layout.modes.func_mode[name]
            @primitives.load_var(ACC, MODE_STATE)
            @emitter.emit(ASM.cmp_imm(ACC, mode_state_marker(mode)))
            skip = @emitter.gensym
            @emitter.emit_branch(:bcond, skip, cond: :eq) # already in this mode? nothing to do
            enter_mode(mode)
            @emitter.place_label(skip)
          end

          # SWITCH ON THE LAYERS THIS SCENE USES, AND ONLY THOSE.
          #
          # Scenes take turns, so they share the console's four layers rather than each
          # having some of their own (see ScreenLayout#layer_slots). A scene that uses fewer than
          # the one before it would otherwise leave the extra ones switched on, still
          # pointed at the last scene's maps, and they would show through wherever this
          # scene's own scenery has a hole in it.
          #
          # It is written every pass rather than guarded by a compare, because it is one
          # store of a number settled during the build — the guard would cost as much as the
          # write. A program whose scenes all use the same layers has an empty table here
          # and emits none of this.
          def emit_scene_layers(name)
            wanted = @layout.scene_layers[name]
            return unless wanted

            value = tiled_dispcnt(wanted.on, turning: wanted.turning)
            value |= OBJ_ENABLE | OBJ_1D_MAP if @layout.has_objects
            write_reg16(REG_DISPCNT, value)
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
          # game that declares its sprites at the top level. A scene whose characters keep one
          # frame at a time has art of its own even when it has nothing to send: another
          # scene's pictures go into the same memory, so taking over has to mark those frames
          # as gone and say this scene is the one loaded.
          #
          # The copy lands where the scene's own routine runs, which is near the top of a
          # frame rather than strictly between frames. A sprite caught half-replaced would
          # show for one frame — on the frame a game changes what the whole screen is, and
          # where the scene it is leaving has already stopped drawing its own sprites.
          def emit_scene_art_upload(name)
            sending = @layout.scene_art[name] || []
            rooms = @layout.objects.each_value.select { |obj| obj.scene == name && obj.frames }
            colors = @layout.scene_obj_palettes[name]
            return if sending.empty? && rooms.empty? && colors.nil?

            emit_on_scene_entry(SCENE_ART_STATE, @layout.scene_art.keys.index(name) + 1) do
              # Its colours first: the groups its sprites name are this scene's now (see
              # ScreenLayout#build_shared_object_palette).
              @palette_tint.emit_send_scene_obj_palette(colors, @layout.obj_palette_units) if colors
              sending.each { |blob, at, units| @uploads.emit_dma_blob(blob, SpriteDrawing::OBJ_TILE_BASE + (at * 32), units * 16) }
              @sprite_drawing.emit_reset_resident_frames(rooms)
            end
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
            @palette_tint.emit_tint_reset_if_tinting # the table now holds the originals again
          end

          # This file's own seams, called as bare methods like the ones in {EmitterCalls}.
          def backing_info(name) = @backing_info.call(name)
          def placed_fade = @layout.placed_fade
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

            color = Graphics::Color.resolve(node.color)
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
            color = Graphics::Color.resolve(node.color)
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

            color = Graphics::Color.resolve(node.color)
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
            @framebuffer.refuse_odd_width!(w, :dma_fill_rect)
            # Held to the area sideways before a single row is emitted: every row of a rectangle
            # spans the same columns, so where it starts and how far it reaches is one answer.
            left = [x, @framebuffer.clip_left].max
            right = [x + w, @framebuffer.clip_right].min
            return if right <= left

            scratch = @framebuffer.emit_color_fill_word(node.color)
            control = @framebuffer.fill_control_for_column(left, right - left)

            h.times do |dy|
              row = y + dy
              next unless (@framebuffer.clip_top...@framebuffer.clip_bottom).cover?(row)

              row_addr = VRAM_START + ((row * SCREEN_WIDTH) + left) * 2
              @framebuffer.emit_dma_fill_row(scratch, row_addr, control)
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

            scratch = @framebuffer.emit_color_fill_word(color)
            control = @framebuffer.fill_control_for_column(nil, right - left)
            (top...bottom).each do |row|
              row_addr = VRAM_START + ((row * SCREEN_WIDTH) + left) * 2
              @framebuffer.emit_dma_fill_row(scratch, row_addr, control)
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
            scratch = @framebuffer.emit_color_fill_word(node.color)

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
            return emit_background_blits(node) unless @layout.tiled
            # A background a scene owns goes up as that scene takes over (see
            # #emit_scene_scenery and IR::SceneHandover), not where it is written.
            return if scene_handover.on_arrival?(node)

            @background_drawing.emit_background_hardware(node)
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
            @framebuffer.emit_text_color(node, ACC) { |color| Graphics::Color.resolve(color) }

            node.fonts.get(node.font).each_pixel(node.text) do |dx, dy|
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
            font = node.fonts.get(node.font)
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
            color = Graphics::Color.resolve(node.color)
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
              Messages::MadeNames.make(:digit_routine, font: font_name)
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
              place_label(Messages::MadeNames.make(:digit_routine, font: font_name))
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
              place_label(:"#{Messages::MadeNames.make(:digit_routine, font: font_name)}_end")
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
