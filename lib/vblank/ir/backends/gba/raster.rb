# frozen_string_literal: true

module VBlank
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
        # A LIGHT IS FED THE SAME WAY. A spotlight is the display's first window, a rectangle
        # whose left and right edges are read again for every line like a scroll is — so a
        # circle is a span per row, worked out into a table in the same gap and moved into the
        # window's register by the same engine or the same interrupt. Everything below that
        # says "bend" holds for the light too; it is one more table, keyed {LIGHT}, fed to a
        # different register. What a light adds is the setting up around it: which layers
        # show inside the window and outside it, and how dark outside is (#emit_boot_light,
        # #emit_light_amount).
        #
        # Owns the five maps/flags that answer "which layers bend, and how": which nodes
        # bend (@row_bends), each one's own scroll to measure from (@row_bend_base), its
        # table of worked-out offsets when one is latched ahead of the frame
        # (@row_bend_table), which copying engine feeds that table (@row_bend_engine), and
        # whether a copier is doing the feeding at all (@copies_row_bends) — and the light
        # (@light), whose table and engine sit in the same two maps under LIGHT. `backgrounds:`
        # is a live reference to the backend's own name -> layer map — it is filled after
        # this object is built (tiled backgrounds are prepared first), so only bg_number,
        # called at emission time, ever actually reads it.
        class Raster
          include Console::Hardware

          # The lines the picture is drawn on. The display counts on past the bottom of the
          # picture (through 227) while nothing is being drawn, so a line at or past this
          # has nothing to bend — except the very last one, which is where the top line of
          # the NEXT frame is set up.
          VISIBLE_LINES = 160
          LAST_LINE = 227

          attr_reader :row_bends # name -> :scroll_rows node (Drawing reads this to skip a bending layer's own scroll)

          def initialize(emitter:, primitives:, memory:, lowering:, framebuffer:)
            @emitter = emitter
            @primitives = primitives
            @memory = memory
            @lowering = lowering
            @layers = {} # background name -> which of the console's layers draws it (see #prepare_row_bends)
            # dma_fill_control lives on Framebuffer, alongside the other shared clip/fill
            # machinery a bend's boot table also needs.
            @framebuffer = framebuffer
            @row_bends = {}         # name -> :scroll_rows node giving each of that layer's rows its own offset
            @row_bend_base = {}     # name -> the layer's own scroll, which a row's offset is measured from
            @row_bend_table = {}    # name -> where its table of row offsets sits, worked out each frame
            @row_bend_engine = {}   # name -> which copying engine feeds it from that table
            @copies_row_bends = false # are those tables fed by a copying engine rather than per-line interrupts?
            @light = nil            # the light's :shade_outside node, fed under the key LIGHT
          end

          # The key the light's table and engine are kept under, beside the backgrounds'
          # names. Underscored the way every name the framework makes for itself is, so no
          # background a game declares can be called it.
          LIGHT = :__spotlight

          # Which backgrounds bend, name -> its :scroll_rows node, and the light, if there is
          # one. Collected in the definitions pass so whichever mechanism answers them can be
          # set up at boot, before any of the program's own code runs.
          def register_row_bends(program)
            program.walk.each do |node|
              @row_bends[node.name] = node if node.kind == :scroll_rows # last wins if repeated
              @light = node if node.kind == :shade_outside
            end
            @dark_scenes = IR::LightScenes.switches?(program) ? IR::LightScenes.dark(program).keys : []
          end

          # What the blend unit is told while the light is on: darken every layer, the sprites
          # and the backdrop, by however much the frame says.
          LIGHT_CONTROL = BLD_DARKEN | BLD_ALL_LAYERS

          # Does the light take turns with scenes it is off in (see IR::LightScenes)?
          def switches_light? = @light && !@dark_scenes.empty?

          # WHETHER THE LAST GAP BETWEEN FRAMES SWITCHED THE LIGHT ON, 1 or 0. A lit scene's
          # pass reads it to tell the blend unit the same, so a scene arriving from one the light
          # was off in shows its first picture with no light, as every backend does.
          LIGHT_SHOWN = :_light_shown

          # TAKING TURNS WITH THE LIGHT, said by a scene as its pass starts. The light switches
          # OFF at once — the scene it is off in takes the blend unit for its own mixing there and
          # then, and lets that mixing through the light's window, inside as well as out — and
          # back ON only at the next gap between frames, where its darkness is worked out (see
          # #emit_light_for_scene). This is what the other backends do, by the same rule
          # (Reference#advance_frame).
          #
          # A scene the light is off in hands back the light's darkening before anything of its
          # own is told the blend unit, so what it then says is not taken for a fade holding it.
          def emit_light_leaving(scene)
            return unless switches_light? && @dark_scenes.include?(scene)

            @emitter.write_reg16(REG_WININ, WIN_ALL_LAYERS | WIN_EFFECT)
            kept = @emitter.gensym
            @emitter.emit_number(ADDR, REG_BLDCNT)
            @emitter.emit(ASM.load_halfword(ACC, ADDR))
            @emitter.emit_number(TMP, LIGHT_CONTROL)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, kept, cond: :ne)
            @emitter.write_reg16(REG_BLDCNT, BLD_OFF)
            @emitter.place_label(kept)
          end

          # ...and a scene the light is on in tells the blend unit what the last gap did: the
          # darkening if it switched the light on, nothing if the light is still off. Said after
          # anything else the scene tells the blend unit, so it is the last word.
          def emit_light_for_lit_scene(scene)
            return unless switches_light? && !@dark_scenes.include?(scene)

            shown = @emitter.gensym
            done = @emitter.gensym
            @primitives.load_var(ACC, LIGHT_SHOWN)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, shown, cond: :ne)
            @emitter.write_reg16(REG_BLDCNT, BLD_OFF)
            @emitter.emit_branch(:b, done)
            @emitter.place_label(shown)
            @emitter.write_reg16(REG_BLDCNT, LIGHT_CONTROL)
            @emitter.place_label(done)
          end

          # Whether any row is answered per line by an interrupt — which is what decides
          # whether the display is asked to announce its lines at all.
          def interrupts_rows?
            feeds_rows? && !@copies_row_bends
          end

          # Is anything fed to the display a row at a time: a bend, or a light?
          def feeds_rows? = !@row_bends.empty? || !@light.nil?

          # Does this program have a light, whose window has to be switched on?
          def feeds_light? = !@light.nil?

          # Every thing fed a row at a time, by the key its table and engine are kept under.
          def feed_keys = @row_bends.keys + (@light ? [LIGHT] : [])

          def copies_row_bends?
            @copies_row_bends
          end

          # Whether the rows are worked out ahead of the frame into a table. True for every
          # bend in a paced program, whichever moves the numbers afterwards; false only where
          # there is no frame to work them out in, and the handler runs the block per line.
          def row_bend_tables?
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

          # +layers+ says which of the console's layers draws each background, which is what a
          # bend writes the offsets of. +scene_scenery+ is the backgrounds a scene puts up as it
          # takes over, each saying its scene, and +scene_entry+ keeps the note of whose are up (see
          # #emit_if_bend_up). A background not among them is up in every scene it is shown in.
          def prepare_row_bends(program, layers:, scene_scenery:, scene_entry:)
            @layers = layers
            @scene_of = scene_scenery.to_h { |node| [node.name, node.scene] }
            @scene_entry = scene_entry
            @row_bends.each_key { |name| @row_bend_base[name] = row_bend_base(program, name) }
            @flat_on_bent_layers = flat_backgrounds_on_bent_layers
            @flat_scroll = @flat_on_bent_layers.to_h { |name, _| [name, row_bend_base(program, name)] }
            @copies_row_bends = BendForm.fed_by_dma?(program)
            return unless BendForm.rows_precomputed?(program)

            # A table per bending layer, and an engine each for as many as there are engines
            # to give. The table lives in the same quick memory the variables do, and holds a
            # row's offset per entry with one to spare: the engine's last move of a frame
            # reads one past the bottom of the picture, on a line nothing is drawn on.
            engines = @copies_row_bends ? BendForm.free_engines(program) : []
            feed_keys.each_with_index do |name, i|
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
              # From one word of zeroes, read over and over.
              @primitives.emit_start_copy_engine(from: scratch, to: base,
                                                 control: @framebuffer.dma_fill_control(TABLE_BYTES / 4))
              next unless copies_row_bends?

              @primitives.store_word_immediate(register_fed(name), COPIER_DAD[engine_for(name)])
            end
            emit_boot_light if @light
            emit_rearm_row_bend_copiers if copies_row_bends?
          end

          # The register a row's number goes into: a bending layer's sideways scroll, or the
          # light's window edges.
          def register_fed(name) = name == LIGHT ? REG_WIN0H : BackgroundDrawing::BG_HOFS_REGS[bg_number(name)]

          # WHAT THE WINDOW MEANS, set once at boot. Inside it every layer and every sprite
          # shows and the darkening is off; outside it the same things show and the darkening
          # is on. Its top and bottom are the whole screen, so which rows are lit is entirely
          # the spans: a row outside the circle has a span with no columns in it. The darkening
          # reaches every layer, the sprites and the backdrop, and starts at none — how dark is
          # the frame's to say (see #emit_light_amount).
          #
          # The window itself is switched on with the layers, in the display's control register
          # (see Drawing#tiled_bg_enable_bits), so a screen that is not drawn from tiles has none.
          def emit_boot_light
            @emitter.write_reg16(REG_WIN0V, VISIBLE_LINES)
            @emitter.write_reg16(REG_WININ, WIN_ALL_LAYERS)
            @emitter.write_reg16(REG_WINOUT, WIN_ALL_LAYERS | WIN_EFFECT)
            @emitter.write_reg16(REG_BLDCNT, LIGHT_CONTROL)
            @emitter.write_reg16(REG_BLDY, 0)
            @primitives.store_word_immediate(0, @primitives.var_addr(LIGHT_ROWS_FILLED)) # no rows worked out yet
          end

          # THE LIGHT AT THE GAP BETWEEN FRAMES, in a game where it takes turns: where the scene
          # that just ran has it on, it is the darkening and a window whose inside is left alone,
          # as at boot, and its darkness for the frame to come. Either way the gap remembers what
          # it did, for the next pass of a lit scene to say (see #emit_light_for_lit_scene). Where
          # the light is off the scene has already said so (see #emit_light_leaving).
          def emit_light_for_scene
            off = @emitter.gensym
            done = @emitter.gensym
            @primitives.load_var(ACC, IR::LightScenes::ON)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, off, cond: :eq)
            @emitter.write_reg16(REG_WININ, WIN_ALL_LAYERS)
            @emitter.write_reg16(REG_BLDCNT, LIGHT_CONTROL)
            emit_light_amount
            @primitives.store_word_immediate(1, @primitives.var_addr(LIGHT_SHOWN))
            @emitter.emit_branch(:b, done)
            @emitter.place_label(off)
            @primitives.store_word_immediate(0, @primitives.var_addr(LIGHT_SHOWN))
            @emitter.place_label(done)
          end

          # How dark outside the light is this frame: the program's amount, 0 to 100, turned
          # into the display's sixteenths the way a fade's is, and held to them.
          def emit_light_amount
            @lowering.value(FadeSteps.steps_value(@light.amount, fraction_bits: nil, walked: false))
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit(ASM.mov_imm_cond(:lt, ACC, 0))
            @emitter.emit(ASM.cmp_imm(ACC, BLD_MAX))
            @emitter.emit(ASM.mov_imm_cond(:gt, ACC, BLD_MAX))
            @primitives.store_halfword_acc(REG_BLDY)
            @primitives.store_var(ACC, LIGHT_STEPS)
          end

          # Point the engine back at the top of the table, in the gap between frames. It
          # walks forward as it feeds the display and there is no telling it to start over,
          # so this is how a table gets read again: stop it, aim it, start it.
          #
          # It aims one entry IN, because the engine's first move of a frame lands on row 1
          # — the end of line 0 is the first line-end there is. Row 0 is the frame's own to
          # write (see #emit_fill_row_bend_tables).
          #
          # An engine whose bend is not up is stopped and left stopped (see #emit_if_bend_up).
          def emit_rearm_row_bend_copiers
            @row_bend_table.each do |name, base|
              engine = engine_for(name)
              @primitives.store_word_immediate(0, COPIER_CNT[engine])
              emit_if_bend_up(name) do
                @primitives.store_word_immediate(base + 2, COPIER_SAD[engine])
                @primitives.store_word_immediate(COPIER_CONTROL, COPIER_CNT[engine])
              end
            end
          end

          # A BEND IS FED ONLY WHILE ITS BACKGROUND IS UP. Scenes take turns showing their
          # backgrounds, and two scenes' backgrounds can be shown on the same layer of the console,
          # one at a time. Each bend has a table and a feeder of its own, all aimed at that one
          # layer's scroll register: fed regardless, the last one fed wins, and a scene that bends
          # its background bends the next scene's as well. So everything that FEEDS a bend — its
          # row 0 into the register at the gap, its engine, the per-line handler — asks first
          # whether the scene its background belongs to is the one whose backgrounds are up, from
          # the same note the scene keeps as it puts them up (SceneEntry). Its rows are still worked
          # out at every gap, up or not, because a scene's first picture is drawn from the rows the
          # gap before it worked out, while the last scene was still up (see #emit_bends_on_arrival).
          # A background up in every scene is fed every frame, as before, and so is the light.
          def emit_if_bend_up(key, &block)
            scene = key == LIGHT ? nil : @scene_of[key]
            return yield unless scene

            @scene_entry.emit_if_scene_up(:scenery, scene, &block)
          end

          # ...and a layer whose bend is not up gets back the plain sideways scroll of the
          # background that is, since the last bend fed left its own last row in the register. A
          # scene's background is up only while its scene's are, so on each layer at most one of
          # these writes. Written at the gap with the bends' first rows, before the picture starts.
          def emit_flat_scroll_of_backgrounds_up
            @flat_on_bent_layers.each do |name, scene|
              @scene_entry.emit_if_scene_up(:scenery, scene) { emit_flat_scroll(name) }
            end
          end

          def emit_flat_scroll(name)
            @lowering.value(@flat_scroll.fetch(name))
            @primitives.store_halfword_acc(register_fed(name))
          end

          # The backgrounds a scene puts up that do not bend, name -> scene, on a layer some scene's
          # bend is fed to.
          def flat_backgrounds_on_bent_layers
            bent = @row_bends.keys.select { |name| @scene_of[name] }.map { |name| bg_number(name) }
            @scene_of.select { |name, _| !@row_bends.key?(name) && bent.include?(bg_number(name)) }
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
          #
          # THE LIGHT'S DARKNESS GOES WITH ITS ROW 0, and before any table, for the same
          # reason: it is a register the whole picture reads.
          #
          # THE LIGHT'S ROWS ARE WORKED OUT ONLY WHEN THEY CAN SHOW AND HAVE CHANGED. Every row is a
          # few dozen instructions, and a light is often there doing nothing — switched off in a
          # scene that sees through a layer, darkening nothing until an iris starts, or standing
          # still — so its darkness is worked out first, and the rows only on a frame the light
          # darkens something and has moved or changed size since they were last worked out. The
          # table keeps the rows from then, and its first row is fed to the display again, since
          # the engine has walked the register on through the table. The picture is the same.
          def emit_fill_row_bend_tables
            emit_light_this_frame if @light
            feed_keys.each { |key| key == LIGHT ? emit_light_first_row : emit_bend_first_row(key) }
            emit_flat_scroll_of_backgrounds_up
            feed_keys.each { |key| key == LIGHT ? emit_if_light_rows { emit_fill_row_table(key) } : emit_fill_row_table(key) }
          end

          # A bend's row 0: always into its table, since every bend is worked out at every gap
          # whether its background is up or not, as the interpreter works them out; into the
          # layer's register only while its background is up.
          def emit_bend_first_row(key)
            return emit_first_row(key) unless @scene_of[key]

            emit_first_row_into_table(key)
            emit_if_bend_up(key) { emit_table_top_into_register(key) }
          end

          # The row 0 a bend's table holds, into its layer's register.
          def emit_table_top_into_register(key)
            @emitter.emit_number(ADDR, @row_bend_table.fetch(key))
            @emitter.emit(ASM.load_halfword(ACC, ADDR))
            @primitives.store_halfword_acc(register_fed(key))
          end

          # A SCENE TAKING OVER SWITCHES ITS LAYERS' BENDS, as its backgrounds go up. The gap before
          # fed whatever was up then, the last scene's, and the scene's first picture is drawn
          # from the bends of the backgrounds it shows: so here the other scenes' engines on the
          # layers this scene's backgrounds use stop, this scene's bend is pointed at its table
          # (worked out at that gap, as every bend is), and a background of its own that does not
          # bend puts its plain scroll back.
          def emit_bends_on_arrival(scene)
            return unless row_bend_tables?

            layers = @scene_of.select { |_, owner| owner == scene }.keys.map { |name| bg_number(name) }
            sharing = @row_bends.keys.select { |name| @scene_of[name] && layers.include?(bg_number(name)) }
            arriving, leaving = sharing.partition { |name| @scene_of[name] == scene }
            leaving.each { |name| @primitives.store_word_immediate(0, COPIER_CNT[engine_for(name)]) } if copies_row_bends?
            arriving.each do |name|
              emit_table_top_into_register(name)
              next unless copies_row_bends?

              engine = engine_for(name)
              @primitives.store_word_immediate(0, COPIER_CNT[engine])
              @primitives.store_word_immediate(@row_bend_table.fetch(name) + 2, COPIER_SAD[engine])
              @primitives.store_word_immediate(COPIER_CONTROL, COPIER_CNT[engine])
            end
            @flat_on_bent_layers.each { |name, owner| emit_flat_scroll(name) if owner == scene }
          end

          # Whether this frame works the light's rows out, 1 or 0; whether the rows in the table were
          # ever worked out, which they are not at power-on; and the darkness last worked out, in
          # sixteenths, kept because the display's own register for it cannot be read back.
          LIGHT_ROWS_THIS_FRAME = :_light_rows_this_frame
          LIGHT_ROWS_FILLED = :_light_rows_filled
          LIGHT_STEPS = :_light_steps

          # Where each number the light's rows are worked out from stood when they last were.
          def light_rows_from_var(name) = :"_light_rows_from_#{name}"

          # The light's darkness for the frame to come, and whether its rows are worked out: only
          # where it shows, darkens something, and has moved since they last were.
          def emit_light_this_frame
            done = @emitter.gensym
            changed = @emitter.gensym
            @primitives.store_word_immediate(0, @primitives.var_addr(LIGHT_ROWS_THIS_FRAME))
            if switches_light?
              emit_light_for_scene
              emit_branch_if_zero(LIGHT_SHOWN, done)
            else
              emit_light_amount
            end
            emit_branch_if_zero(LIGHT_STEPS, done)
            emit_branch_if_zero(LIGHT_ROWS_FILLED, changed)
            IR::LightScenes.span_vars(@light).each do |name|
              @primitives.load_var(ACC, name)
              @primitives.load_var(TMP, light_rows_from_var(name))
              @emitter.emit(ASM.cmp_reg(ACC, TMP))
              @emitter.emit_branch(:bcond, changed, cond: :ne)
            end
            @emitter.emit_branch(:b, done)
            @emitter.place_label(changed)
            IR::LightScenes.span_vars(@light).each do |name|
              @primitives.load_var(ACC, name)
              @primitives.store_var(ACC, light_rows_from_var(name))
            end
            @primitives.store_word_immediate(1, @primitives.var_addr(LIGHT_ROWS_FILLED))
            @primitives.store_word_immediate(1, @primitives.var_addr(LIGHT_ROWS_THIS_FRAME))
            @emitter.place_label(done)
          end

          # THE LIGHT WORKED OUT DURING A PASS (Spotlight#show_now), for the picture being drawn:
          # what a game does that hands the display its rows while it draws. The same as the gap
          # does — the darkness, and the rows only where they show and have changed — into the
          # same table, which the display goes on reading a line at a time, so every line it has
          # not reached yet shows the new rows. Row 0 goes straight into the register only while
          # the display is still between pictures; once it is drawing, the register is fed a line
          # at a time from the table, and a write would land on the line being drawn.
          #
          # This is the lead the gap's own comment warns of — the light a picture ahead of the
          # sprites — and that is the point: a game that asks for it is copying one that has it.
          def emit_light_now(_node = nil)
            return unless feeds_light? && row_bend_tables?

            drawing = @emitter.gensym
            emit_light_this_frame
            emit_if_light_rows do
              emit_first_row_into_table(LIGHT)
              # Asked after row 0 is worked out, not before, so a long shape cannot carry the
              # write past the gap.
              @emitter.emit_number(ADDR, REG_VCOUNT)
              @emitter.emit(ASM.load_halfword(TMP, ADDR))
              @emitter.emit(ASM.cmp_imm(TMP, VISIBLE_LINES))
              @emitter.emit_branch(:bcond, drawing, cond: :lt)
              @primitives.store_halfword_acc(register_fed(LIGHT))
              @emitter.place_label(drawing)
              emit_fill_row_table(LIGHT)
            end
          end

          # The light's row 0: worked out, where the rows are; otherwise the one the table keeps.
          def emit_light_first_row
            kept = @emitter.gensym
            done = @emitter.gensym
            emit_branch_if_zero(LIGHT_ROWS_THIS_FRAME, kept)
            emit_first_row(LIGHT)
            @emitter.emit_branch(:b, done)
            @emitter.place_label(kept)
            @emitter.emit_number(ADDR, @row_bend_table.fetch(LIGHT))
            @emitter.emit(ASM.load_halfword(ACC, ADDR))
            @primitives.store_halfword_acc(register_fed(LIGHT))
            @emitter.place_label(done)
          end

          def emit_if_light_rows
            skip = @emitter.gensym
            emit_branch_if_zero(LIGHT_ROWS_THIS_FRAME, skip)
            yield
            @emitter.place_label(skip)
          end

          # Go to +label+ when the variable +name+ holds nought.
          def emit_branch_if_zero(name, label)
            @primitives.load_var(ACC, name)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, label, cond: :eq)
          end

          # One thing's row 0: into the table, and straight into its register, since
          # whatever feeds the rest only starts moving numbers at the end of line 0. Nothing
          # else writes that register for a bending layer — a `scroll_by` on one leaves it
          # alone, because the layer's scroll is already in every entry of the table (see
          # BackgroundDrawing#emit_scroll_background).
          def emit_first_row(key)
            emit_first_row_into_table(key)
            @primitives.store_halfword_acc(register_fed(key))
          end

          # ...into the table alone, its value left in r0.
          def emit_first_row_into_table(key)
            @primitives.store_word_immediate(0, @primitives.var_addr(row_var(key)))
            emit_row_value(key)
            @emitter.emit_number(ADDR, @row_bend_table.fetch(key))
            @emitter.emit(ASM.store_halfword(ACC, ADDR))
          end

          # ...and the rest of its rows, 1 up. The loop keeps its count in the block's own
          # row variable, which the block reads anyway: the block is free to reach a routine
          # or the console's divide, and either would land in whatever register a count was
          # being held in.
          def emit_fill_row_table(key)
            row = row_var(key)
            base = @row_bend_table.fetch(key)
            top = @emitter.gensym
            @primitives.store_word_immediate(1, @primitives.var_addr(row))
            @emitter.place_label(top)
            emit_row_value(key)
            @primitives.load_var(TMP, row)
            @emitter.emit(ASM.lsl_imm(SPARE, TMP, 1))         # two bytes an entry
            @emitter.emit_number(ADDR, base)
            @emitter.emit(ASM.add_reg(ADDR, ADDR, SPARE))
            @emitter.emit(ASM.store_halfword(ACC, ADDR))
            @emitter.emit(ASM.add_imm(TMP, TMP, 1))
            @primitives.store_var(TMP, row)
            @emitter.emit(ASM.cmp_imm(TMP, VISIBLE_LINES))
            @emitter.emit_branch(:bcond, top, cond: :lt)
          end

          # The variable a thing fed by rows is handed each row number in.
          def row_var(key) = key == LIGHT ? @light.row : @row_bends.fetch(key).row

          # The number for the row now in that variable, left in r0. First whatever else the
          # thing works out once a row. Then, for a bending layer, its offset, measured from the
          # layer's own scroll; for the light, its span, as the window's register holds one —
          # the left edge in the high byte and the right in the low.
          def emit_row_value(key)
            node = key == LIGHT ? @light : @row_bends.fetch(key)
            node.children.each { |child| @lowering.statement(child) }
            @lowering.value(key == LIGHT ? light_span : Build.binop(:+, node.offset, @row_bend_base[node.name]))
          end

          def light_span = Build.binop(:|, Build.binop(:<<, @light.left, Build.int(8)), @light.right)

          # Which of the console's layers draws this background. Outside tile mode there is
          # none, and the scroll registers do nothing — the same harmless fallback a plain
          # scroll takes.
          def bg_number(name)
            @layers[name] || 0
          end

          # The per-line handler, run from the interrupt dispatcher.
          #
          # The line the display is ABOUT to draw is one past the one it just finished, so
          # the offset written here is the next line's. On the display's last line that
          # wraps to the top line of the next frame, which is what keeps the topmost row of
          # the picture bent like all the others.
          def emit_row_bend_handler
            done = @emitter.gensym
            @emitter.emit_number(TMP, REG_VCOUNT)
            @emitter.emit(ASM.load_halfword(ACC, TMP))         # r0 = the line just finished
            @emitter.emit(ASM.cmp_imm(ACC, LAST_LINE))
            @emitter.emit(ASM.mov_imm_cond(:eq, ACC, 0))       # the last line sets up the next frame's first
            @emitter.emit(ASM.add_imm_cond(:ne, ACC, ACC, 1))  # ...otherwise the next line down
            @emitter.emit(ASM.cmp_imm(ACC, VISIBLE_LINES))
            @emitter.emit_branch(:bcond, done, cond: :ge)      # below the picture: nothing to bend
            if row_bend_tables?
              @emitter.emit(ASM.lsl_imm(SPARE, ACC, 1))        # two bytes an entry, held for them all
              feed_keys.each { |key| emit_if_bend_up(key) { emit_read_row_from_table(key) } }
            else
              # Every bend is told the line first, because working one offset out needs the
              # accumulator the line number is sitting in.
              feed_keys.each { |key| @primitives.store_var(ACC, row_var(key)) }
              feed_keys.each { |key| emit_row_without_table(key) }
            end
            @emitter.place_label(done)
          end

          # One thing's row, out of the table and into its register. The display reads that
          # register as it draws the line, so this is the whole of the handler's work — the
          # number was worked out in the gap between frames.
          def emit_read_row_from_table(key)
            @emitter.emit_number(ADDR, @row_bend_table.fetch(key))
            @emitter.emit(ASM.add_reg(ADDR, ADDR, SPARE))
            @emitter.emit(ASM.load_halfword(ACC, ADDR))
            @primitives.store_halfword_acc(register_fed(key))
          end

          # One thing's number for this line, worked out here and now and written. This is
          # what a program with no frame gets, having had no gap to work its rows out in
          # ahead of time.
          def emit_row_without_table(key)
            emit_row_value(key)
            @primitives.store_halfword_acc(register_fed(key))
          end
        end
      end
    end
  end
end
