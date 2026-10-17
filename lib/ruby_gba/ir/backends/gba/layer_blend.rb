# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # SEEING THROUGH ONE LAYER TO WHAT IS BEHIND IT.
        #
        # The console blends as it draws the scanline: it is told which layers are the
        # near side of a blend, which are the far side, and how much of each to take. So
        # nothing is redrawn, no pixel in memory changes, and a see-through layer costs
        # the same whatever is on screen — the same bargain `fade` and `camera` make.
        #
        # TWO PATHS, and the difference is real even though it does not reach the author.
        #
        #   A LAYER OF SCENERY is named as the near side of the blend in the blend-control
        #   register, with everything behind it as the far side. That register also holds
        #   WHICH effect is running, so this path needs the effect set to "mix two layers".
        #
        #   A LAYER OF SPRITES needs none of that. A sprite can be marked see-through in
        #   its own table entry, and the display then blends that sprite and no other
        #   whatever the effect bits say. It is one bit OR'd into an entry the frame
        #   already writes, so it costs nothing and it picks out exactly the sprites in
        #   that layer.
        #
        # NEITHER PATH SURVIVES A FADE THAT USES THIS REGISTER, measured rather than
        # assumed. The sprite's own bit frees it from the effect field, but a see-through
        # sprite still has to be told WHAT it blends with — the far side of that same
        # register — and a fade writes the register whole. So such a fade takes the blend
        # from both paths for as long as it runs, and both get it back when it lifts (see
        # ScreenEffects#emit_fade_beside_see_through).
        #
        # Keeping the far side across a fade was tried, and the picture it gives is worse.
        # The sprite does go on blending — but the display then blends it with the darkened
        # picture WITHOUT darkening the sprite itself, so fading out to a game-over screen
        # leaves half-bright ghosts floating on a black screen. Letting the fade have the
        # whole register makes everything darken together, which is what a fade out is
        # supposed to look like, and it costs nothing to do.
        #
        # WHICH IS WHY A WHOLE-SCREEN FADE DOES NOT COME HERE AT ALL any more. A program
        # that sees through a layer fades by walking its color table instead, which never
        # touches this register and leaves both paths blending right through the fade (see
        # IR::Fading, and ScreenEffects#emit_palette_fade). What still arrives here
        # is a fade PLACED in the stack, which is the one thing only this register can do,
        # and a fade left on from a painted screen, which has no colors to walk and fades by
        # this register too (see #note_display_fades for what that asks of this class).
        #
        # An author writes the same keyword either way and never learns which they got.
        #
        # Owns @layers — which layers this program can be seen through, if any, and
        # how much. Reads the screen's layout ({ScreenLayout}: how the scenery and sprites
        # stack, and which of the console's layers each background landed on), handed over
        # through #screen= once it exists, since it is worked out from the program after this
        # object is built (the same shape Functions#modes= is set in). `drawing:` reaches
        # Drawing for the fade/blend arithmetic it shares with a tint and a fade — GBA builds
        # this object before its own @drawing exists, so it hands in `self` and the call
        # resolves once @drawing does (see gba.rb#initialize).
        class LayerBlend
          include Console::Hardware

          # attr0 bits 10-11 = 1: draw this sprite through the blend rather than straight.
          # (The same two bits hold OBJ_WINDOW_MODE at 2, which is why they are one field
          # and a sprite cannot be both.)
          OBJ_SEMI_TRANSPARENT = 0x0400

          def initialize(emitter:, lowering:, primitives:, drawing:)
            @emitter = emitter
            @lowering = lowering
            @primitives = primitives
            @drawing = drawing
            # Nothing has a layer until the backgrounds are given their slots, and a
            # program with no tiled backgrounds never gives out any. A see-through layer of
            # SPRITES is the case that arrives here — it names no background at all.
            @hardware_layers = {}
          end

          # The screen's layout: how the picture stacks, the same picture cut into what can be
          # on screen AT ONCE, and which of the console's layers each background landed on.
          def screen=(layout)
            @picture = layout.picture
            @screenfuls = layout.screenfuls
            @hardware_layers = layout.hardware_layers
          end

          # WHICH OF A SEE-THROUGH LAYER'S SCREENS IS UP. A game with a see-through layer on
          # more than one screen writes, as each scene takes over, which of its layers that
          # screen shows — counting from 1, so the 0 nothing has written means none. The
          # frame boundary reads it to tell the display that layer's amounts and no other's.
          SCREEN_STATE = :_see_through_screen

          # Which layers this program can be seen through, and how much — read off the
          # stack the program declared. Nothing at all for a program that declares none,
          # which is what keeps such a program byte for byte as it was.
          def prepare_layer_blend(program)
            @layers = IR::SeeThrough.layers(program)
            # An amount the program works out has no number here. What boot writes is what
            # its variable starts at, so the first frame is already right rather than right
            # one frame later.
            @starting = @layers.to_h do |node|
              shows, behind = [node.shows, node.behind].map do |amount|
                @primitives.const_int(amount) || starting_amount(program, amount)
              end
              [node.name, IR::SeeThrough.weights(node, shows, behind)]
            end
            @amount_layers = @layers.reject { |layer| constant_amounts?(layer) }.to_h { |layer| [routine_name(layer), layer] }
            @amount_routines = @amount_layers.transform_values { |layer| scene_of(layer) }
          end

          # Does this program see through any layer at all?
          def see_through?
            !@layers.nil? && !@layers.empty?
          end

          # Is there a see-through layer on more than one screen? Then which one the display
          # mixes changes as the screens take turns, and a game with only one pays nothing
          # for the bookkeeping.
          def several_see_through_layers? = @layers.size > 1

          # DOES THE FRAME BOUNDARY ASK WHICH SCREEN IS UP before telling the display a layer's
          # amounts? Where there are several see-through layers, so it tells the one on screen.
          # And where the one there is belongs to a single scene and its amounts are worked
          # out: then on any other scene's frames nothing on screen is mixed by them, and
          # working them out anyway would be that scene's arithmetic paid for by every other,
          # from wherever its routine was placed. Asking costs each scene one store and the
          # boundary one compare.
          def tracks_see_through_screen?
            several_see_through_layers? || amount_routines.values.any? { |owner| owner != Placement::FRAME_ROUTINE }
          end

          # What an amount the game works out starts at: the initial value of the variable
          # it reads, when it is one plain variable. An amount worked out from more than
          # that starts at the picture as drawn — the safe way to be wrong for one frame.
          def starting_amount(program, amount)
            return 0 unless amount.kind == :var_ref

            # The first thing written to that name is its declaration, which the build has
            # already moved to the front of the program.
            first = program.walk.find { |n| n.kind == :set && n.var == amount.name }
            (first && @primitives.const_int(first.value)) || 0
          end

          # Does this program see through a layer of SCENERY? Only that half touches the
          # blend-control register, and only that half has to be set up at boot.
          def blends_scenery?
            see_through? && @picture.scenery.any? { |node| see_through_name?(node.layer) }
          end

          # Turn the blend on, once, at boot. The near side is the see-through scenery;
          # the far side is everything behind it, which always includes the backdrop —
          # where the layer behind has a hole, what shows through is the backdrop, and it
          # has to be blended too or that hole would come out at full strength.
          #
          # A see-through layer of SPRITES leaves the effect bits at nothing and writes the
          # far side alone: the sprites blend because their own entries say so, and nothing
          # else has to be in force for them.
          #
          # Called again wherever the register has to be put back the way this left it —
          # entering a display mode, and a fade lifting.
          def emit_boot_layer_blend
            emit_blend_targets
            first = see_through_layer_on(first_screen_that_blends) || @layers.first
            @emitter.write_reg16(REG_BLDALPHA, pack_blend_weights(@starting.fetch(first.name)))
            emit_store_see_through_screen(first) if tracks_see_through_screen?
          end

          # PUT THE BLEND BACK, for whatever took it — entering a display mode, and a fade
          # lifting. Both happen while the game is running, so this writes the amount the
          # picture has NOW rather than the one it started with: a game whose fog is half
          # thick when a hit flash ends must come back half thick, not clear.
          #
          # For a number the author wrote there is no difference and no extra instruction:
          # then and now are the same number.
          #
          # Which layers are mixed is the first screen's answer where every screen wants the
          # same, and the answer of the scene that is up where they do not and a fade can be
          # lifted on any of them (see #emit_scene_blend_control).
          def emit_restore_layer_blend
            if @scenes_say_control
              @primitives.load_var(ACC, SCENE_CONTROL)
              @primitives.store_halfword_acc(REG_BLDCNT)
            else
              emit_blend_targets
            end
            @layers.each { |layer| emit_blend_amounts_or_call(layer) }
          end

          # A FADE THE DISPLAY DOES AND A SEE-THROUGH LAYER, IN ONE GAME. Everything below is
          # for that game and no other, so that a game without the pair comes out byte for
          # byte as it did.
          #
          # Such a fade stays until the game lifts it, across a change of scene and a change
          # of screen: fading out on one screen and in on the next relies on it. And it is in
          # the same register the see-through layer is set up in. So the three places that
          # set the layer up while the game runs — a screen drawn from tiles taking over, a
          # scene saying which layers it mixes, and a fade or tint that moves the colors
          # taking the display fade's place — each ask that register first. It can be read
          # back, where the one holding how far a fade has gone cannot, and in this game a
          # fade of nothing is never left in it: every statement that ends a display fade
          # hands the register back (see ScreenEffects#emit_fade_beside_see_through and
          # #emit_blend_back_from_display_fade). So the effect it names is the one in force.
          #
          # +scene_blend+ is what each scene tells the blend unit, empty where they all agree.
          def note_display_fades(fading, scene_blend)
            @fade_can_hold_blend = see_through? && fading.any_display_fade?
            @scenes_say_control = @fade_can_hold_blend && !scene_blend.empty?
          end

          # The bit of the blend-control register that both ways of fading set and that
          # mixing two layers does not: the effect field reads "toward white" or "toward
          # black" with it, and "mix" or "nothing" without.
          FADE_HOLDS_BLEND = BLD_BRIGHTEN & BLD_DARKEN

          # WHAT THE SCENE THAT IS UP TELLS THE BLEND UNIT, kept where a fade lifting can read
          # it. A fade lifts wherever the game says, and what it hands the register back to
          # has to be that scene's layers, not the first screen's.
          SCENE_CONTROL = :_scene_blend_control

          # COMING ONTO A SCREEN DRAWN FROM TILES: tell the display which layer is seen
          # through, unless a fade is holding the blend. Setting the layer up regardless ended
          # a fade left on from the screen before, and the new screen arrived bright.
          def emit_layer_blend_on_entry
            return emit_restore_layer_blend unless @fade_can_hold_blend

            emit_unless_fade_holds_blend { emit_restore_layer_blend }
          end

          # A SCENE SAYS WHICH LAYERS IT MIXES, on every pass it runs (see
          # Drawing#emit_scene_blend). Where a fade can hold the blend the scene's answer is
          # remembered and written only while none does; the fade lifting writes it then.
          def emit_scene_blend_control(wanted)
            return @emitter.write_reg16(REG_BLDCNT, wanted) unless @fade_can_hold_blend

            @primitives.store_word_immediate(wanted, @primitives.var_addr(SCENE_CONTROL))
            emit_unless_fade_holds_blend { @emitter.write_reg16(REG_BLDCNT, wanted) }
          end

          # A FADE OR A TINT THAT MOVES THE COLORS TAKES THE PLACE OF A FADE THE DISPLAY WAS
          # DOING, since a picture has one such effect at a time. It lifts that fade by
          # another road than the display's own, so it hands the blend back the way the
          # display's own lift does. Nothing where no display fade can be in force.
          def emit_blend_back_from_display_fade
            return unless @fade_can_hold_blend

            emit_if_fade_holds_blend { emit_restore_layer_blend }
          end

          # HOW SEE-THROUGH A LAYER IS, NOW. A picture whose amounts the program works out
          # gets one of these at every frame boundary, so the display is told again before
          # the frame it applies to is drawn — and a game with a see-through layer on more
          # than one screen gets one for each, of which only the one on screen writes.
          #
          # It writes the weights and nothing else: which layers blend with which is settled
          # at boot, or as each scene takes over, so the per-frame part is one register.
          def emit_see_through(node)
            return unless see_through?

            emit_blend_amounts_or_call(@layers.find { |layer| layer.name == node.layer })
          end

          # THE ROUTINES THAT WORK OUT AMOUNTS THE GAME CHANGES, each with the scene it works
          # for — or with the frame's own routine, for a layer that is not one scene's alone.
          #
          # Turning two percentages into the display's sixteenths is a multiply, a divide and
          # a clamp apiece. Written straight into the frame boundary, that sat in the game
          # loop's own body, which is the first thing kept in the quick memory — so a title
          # screen kept out of that memory on purpose still spent it, on every scene's behalf.
          # As a routine of the layer's own it is weighed like the scene it belongs to and
          # takes that scene's `fast:`, and the boundary keeps a call. It is called at the same
          # place the work was, so the display hears each pair on the same frame as before.
          #
          # A pair of numbers the author wrote needs none: that is one write of a number.
          def amount_routines = @amount_routines || {}

          # The body of one of those routines. Whether its layer's screen is up is asked before
          # the call (see #emit_blend_amounts_or_call), so another screen's frames do not call
          # it at all.
          def emit_amounts_routine(name)
            emit_blend_amounts(@amount_layers.fetch(name))
          end

          # WHICH SEE-THROUGH LAYER THIS SCENE'S SCREEN SHOWS, written as the scene runs so
          # the frame boundary tells the display that one's amounts. Nothing for a game that
          # never has to ask (see #tracks_see_through_screen?).
          #
          # ON THE PASS IT CHANGES, the scene tells the display its layer's amounts there and
          # then. The boundary is too late for that one frame: the scene has just said which
          # layers to mix, the display holds one pair of amounts, and until the boundary that
          # pair is the last screen's — so the scene's first frame would be mixed by the other
          # layer's amounts, or by nothing at all coming from a screen that saw through none.
          # Every pass after, the marker already holds and this is a compare.
          def emit_screen_marker(scene)
            return unless see_through? && tracks_see_through_screen?

            screenful = @screenfuls.find { |each| each.scene == scene }
            layer = screenful && see_through_layer_on(screenful)
            @primitives.load_var(ACC, SCREEN_STATE)
            @emitter.emit(ASM.cmp_imm(ACC, screen_number(layer)))
            same = @emitter.gensym
            @emitter.emit_branch(:bcond, same, cond: :eq)
            emit_store_see_through_screen(layer)
            emit_blend_amounts_or_call(layer) if layer
            @emitter.place_label(same)
          end

          # Turn the blend on for the screen this program starts with. A program whose
          # screens all want the same thing is done here and writes nothing else ever
          # again; one whose screens differ has each scene correct it as it takes over
          # (see #blend_control_by_scene), before anything of that scene is drawn.
          def emit_blend_targets
            control = blend_control(first_screen_that_blends)
            @emitter.write_reg16(REG_BLDCNT, control)
            # ...and it stands as the scene's answer until a scene gives its own.
            @primitives.store_word_immediate(control, @primitives.var_addr(SCENE_CONTROL)) if @scenes_say_control
          end

          # WHAT EACH SCENE HAS TO TELL THE BLEND UNIT, or nothing at all where every scene
          # wants the same thing.
          #
          # The register names a layer by NUMBER, and scenes take turns with the console's
          # layers — so the number the see-through layer sits on is a fact about the scene
          # rather than about the program. A scene that sees through nothing has to say so
          # too, or whichever background inherited that number is quietly blended in its
          # place.
          #
          # The same rule as a scene's layers (see ScreenLayout#layers_differ_by_scene?): where
          # the scenes all agree this is empty and boot's one write stands, which is what keeps a game that has
          # scenes but one screenful's worth of blending byte for byte what it was. A game
          # with a see-through layer on more than one screen always has each scene say it.
          def blend_control_by_scene(modes)
            return {} unless see_through?

            wanted = @screenfuls.reject { |screenful| screenful.scene.nil? }
                                .to_h { |screenful| [screenful.scene, blend_control(screenful)] }
            wanted.select! { |scene, _| modes.func_mode[scene] == IR::Modes::TILED }
            several_see_through_layers? || wanted.values.uniq.size > 1 ? wanted : {}
          end

          # Tell the display the two shares of +layer+ (a SeeThroughLayer). Numbers the
          # author wrote are one write of a number settled here.
          def emit_blend_amounts(layer)
            shows = @primitives.const_int(layer.shows)
            behind = @primitives.const_int(layer.behind)
            if shows && behind
              return @emitter.write_reg16(REG_BLDALPHA, pack_blend_weights(IR::SeeThrough.weights(layer, shows, behind)))
            end
            return emit_split_amount(layer.behind) if layer.split

            @lowering.value(IR::SeeThrough.packed_shares_expr(layer))
            @primitives.store_halfword_acc(REG_BLDALPHA)
          end

          # The one-number form worked out as the game runs: what is behind is the amount's
          # share, and the layer takes what is left of a whole.
          def emit_split_amount(amount)
            @lowering.value(@drawing.fade_steps_value(amount))
            @drawing.emit_clamp_blend_steps
            @drawing.emit_blend_weights_from_acc
          end

          # The weight pair as one halfword: how much of the layer itself survives in the
          # low byte, how much of what is behind comes through above it. The same shape
          # the tint's weights take, because it is the same blend unit.
          def pack_blend_weights((near, far)) = near | (far << 8)

          private

          # Write the block's code so it runs only while no fade holds the blend...
          def emit_unless_fade_holds_blend(&) = emit_guarded_by_fade_bit(run_when_set: false, &)

          # ...and only while one does.
          def emit_if_fade_holds_blend(&) = emit_guarded_by_fade_bit(run_when_set: true, &)

          # Read the blend-control register, test its fade bit, and jump over the block's
          # code when the bit is the other way from +run_when_set+.
          def emit_guarded_by_fade_bit(run_when_set:)
            skip = @emitter.gensym
            @emitter.emit_number(TMP, REG_BLDCNT)
            @emitter.emit(ASM.load_halfword(TMP, TMP))
            @emitter.emit(ASM.tst_imm(TMP, FADE_HOLDS_BLEND))
            # The test leaves "equal" when the bit is clear.
            @emitter.emit_branch(:bcond, skip, cond: run_when_set ? :eq : :ne)
            yield
            @emitter.place_label(skip)
          end

          # Tell the display +layer+'s amounts: by calling the routine that works them out,
          # where they change, and by writing them here where they are numbers.
          def emit_blend_amounts_or_call(layer)
            name = routine_name(layer)
            emit_if_on_screen(layer) do
              amount_routines.key?(name) ? @lowering.statement(Build.call(name)) : emit_blend_amounts(layer)
            end
          end

          def routine_name(layer) = Messages::MadeNames.make(:see_through_amounts, layer: layer.name)

          def constant_amounts?(layer) = [layer.shows, layer.behind].all? { |amount| @primitives.const_int(amount) }

          # The one scene whose screens show +layer+, or the frame's own routine when it is
          # shown outside any scene or by more than one.
          def scene_of(layer)
            scenes = @screenfuls.select { |screenful| see_through_layer_on(screenful) == layer }.map(&:scene).uniq
            scenes.size == 1 && scenes.first ? scenes.first : Placement::FRAME_ROUTINE
          end

          # Emit the block's code to run — where the game asks which screen is up — only while
          # +layer+'s screen is the one up.
          def emit_if_on_screen(layer)
            return yield unless tracks_see_through_screen?

            @primitives.load_var(ACC, SCREEN_STATE)
            @emitter.emit(ASM.cmp_imm(ACC, screen_number(layer)))
            skip = @emitter.gensym
            @emitter.emit_branch(:bcond, skip, cond: :ne)
            yield
            @emitter.place_label(skip)
          end

          def emit_store_see_through_screen(layer)
            @primitives.store_word_immediate(screen_number(layer), @primitives.var_addr(SCREEN_STATE))
          end

          # +layer+'s number in SCREEN_STATE, or 0 for none.
          def screen_number(layer) = layer ? @layers.index(layer) + 1 : 0

          def see_through_name?(name) = @layers.any? { |layer| layer.name == name }

          # The see-through layer +screenful+ shows, or nil. It shows one at most — two is
          # refused before this runs (see Guardrails::Checks::SeeThroughPerScreen).
          def see_through_layer_on(screenful) = IR::SeeThrough.on_screen(screenful, @layers).first

          # WHAT THE BLEND REGISTER SAYS FOR ONE SCREENFUL: which layers are the near side
          # of the blend, which are the far side, and which effect is running.
          #
          # A screen holding neither see-through scenery nor a see-through sprite turns the
          # whole thing OFF rather than leaving the last screen's layers named. Those layer
          # numbers belong to whatever is on screen now, so leaving them is not a harmless
          # leftover — it blends the wrong picture.
          def blend_control(screenful)
            layer = see_through_layer_on(screenful)
            return BLD_OFF unless layer

            near = screenful.scenery.select { |node| node.layer == layer.name }
            mode = near.empty? ? BLD_OFF : BLD_ALPHA
            mode | bits_for(near) | (far_side_bits(screenful, layer.name) << BLD_SECOND_SHIFT)
          end

          # The screen boot sets the console up for: the first one that blends anything, so
          # a program with no scenes gets its exact answer and one with scenes gets a real
          # layer number rather than a placeholder.
          def first_screen_that_blends
            @screenfuls.find { |screenful| blend_control(screenful) != BLD_OFF } || @screenfuls.first
          end

          # Everything on this screen BEHIND the see-through layer: the scenery below it,
          # the sprites below it, and the backdrop, which is behind everything there is.
          # The scenery is read off the picture rather than off the stack, because what the
          # register names is a hardware layer number and only the picture knows which
          # background got which.
          def far_side_bits(screenful, layer)
            kept = IR::Stacking.at_or_above(@picture, layer).map(&:name)
            behind = screenful.scenery.reject { |node| kept.include?(node.name) }
            bits = BLD_BACKDROP | bits_for(behind)
            bits |= BLD_OBJ if screenful.objects.any? { |node| !kept.include?(node.name) }
            bits
          end

          # The register bits naming these backgrounds, by the hardware layer each one
          # really landed on. That is NOT where the background sits in the program's list
          # of scenery: scenes take turns with the console's layers, so the second scene's
          # first background is fifth in the program and first on the hardware.
          #
          # A background with no layer at all contributes nothing, because there is nothing
          # for the register to name — a `background` on a bitmap screen is stamped into
          # that screen's one picture where it is declared and is not a layer afterwards.
          def bits_for(nodes)
            nodes.sum(0) do |node|
              layer = @hardware_layers[node.name]
              layer ? BLD_BG0 << layer : 0
            end
          end
        end
      end
    end
  end
end
