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
        # Drawing#emit_fade_sharing_the_blend).
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
        # IR::Fading, and Drawing#emit_fade_by_walking_the_colors). What still arrives here
        # is a fade PLACED in the stack, which is the one thing only this register can do.
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
          end

          # Does this program see through any layer at all?
          def see_through?
            !@layers.nil? && !@layers.empty?
          end

          # Is there a see-through layer on more than one screen? Then which one the display
          # mixes changes as the screens take turns, and a game with only one pays nothing
          # for the bookkeeping.
          def several? = @layers.size > 1

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
            first = layer_on(first_screen_that_blends) || @layers.first
            @emitter.write_reg16(REG_BLDALPHA, halfword(@starting.fetch(first.name)))
            store_screen(first) if several?
          end

          # PUT THE BLEND BACK, for whatever took it — entering a display mode, and a fade
          # lifting. Both happen while the game is running, so this writes the amount the
          # picture has NOW rather than the one it started with: a game whose fog is half
          # thick when a hit flash ends must come back half thick, not clear.
          #
          # For a number the author wrote there is no difference and no extra instruction:
          # then and now are the same number.
          def emit_layer_blend_again
            emit_blend_targets
            @layers.each { |layer| emit_amounts_if_on_screen(layer) }
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

            emit_amounts_if_on_screen(@layers.find { |layer| layer.name == node.layer })
          end

          # WHICH SEE-THROUGH LAYER THIS SCENE'S SCREEN SHOWS, written as the scene runs so
          # the frame boundary tells the display that one's amounts. Nothing for a game with
          # one see-through layer, which never has to ask.
          def emit_screen_marker(scene)
            return unless see_through? && several?

            screenful = @screenfuls.find { |each| each.scene == scene }
            store_screen(screenful && layer_on(screenful))
          end

          # Turn the blend on for the screen this program starts with. A program whose
          # screens all want the same thing is done here and writes nothing else ever
          # again; one whose screens differ has each scene correct it as it takes over
          # (see #scene_blend), before anything of that scene is drawn.
          def emit_blend_targets
            @emitter.write_reg16(REG_BLDCNT, blend_control(first_screen_that_blends))
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
          # Same shape, and the same rule, as ScreenLayout#scene_layers_for: where the scenes all agree
          # this is empty and boot's one write stands, which is what keeps a game that has
          # scenes but one screenful's worth of blending byte for byte what it was. A game
          # with a see-through layer on more than one screen always has each scene say it.
          def scene_blend(modes)
            return {} unless see_through?

            wanted = @screenfuls.reject { |screenful| screenful.scene.nil? }
                                .to_h { |screenful| [screenful.scene, blend_control(screenful)] }
            wanted.select! { |scene, _| modes.func_mode[scene] == IR::Modes::TILED }
            several? || wanted.values.uniq.size > 1 ? wanted : {}
          end

          # Tell the display the two shares of +layer+ (a SeeThroughLayer). Numbers the
          # author wrote are one write of a number settled here.
          def emit_blend_amounts(layer)
            shows = @primitives.const_int(layer.shows)
            behind = @primitives.const_int(layer.behind)
            if shows && behind
              return @emitter.write_reg16(REG_BLDALPHA, halfword(IR::SeeThrough.weights(layer, shows, behind)))
            end
            return emit_split_amount(layer.behind) if layer.split

            @lowering.value(IR::SeeThrough.weights_value(layer))
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
          def halfword((near, far)) = near | (far << 8)

          private

          # Tell the display +layer+'s amounts — where the game has a see-through layer on
          # more than one screen, only while +layer+'s screen is the one up.
          def emit_amounts_if_on_screen(layer)
            return emit_blend_amounts(layer) unless several?

            @primitives.load_var(ACC, SCREEN_STATE)
            @emitter.emit(ASM.cmp_imm(ACC, screen_number(layer)))
            skip = @emitter.gensym
            @emitter.emit_branch(:bcond, skip, cond: :ne)
            emit_blend_amounts(layer)
            @emitter.place_label(skip)
          end

          def store_screen(layer)
            @primitives.store_word_immediate(screen_number(layer), @primitives.var_addr(SCREEN_STATE))
          end

          # +layer+'s number in SCREEN_STATE, or 0 for none.
          def screen_number(layer) = layer ? @layers.index(layer) + 1 : 0

          def see_through_name?(name) = @layers.any? { |layer| layer.name == name }

          # The see-through layer +screenful+ shows, or nil. It shows one at most — two is
          # refused before this runs (see Guardrails::Checks::SeeThroughPerScreen).
          def layer_on(screenful) = IR::SeeThrough.on_screen(screenful, @layers).first

          # WHAT THE BLEND REGISTER SAYS FOR ONE SCREENFUL: which layers are the near side
          # of the blend, which are the far side, and which effect is running.
          #
          # A screen holding neither see-through scenery nor a see-through sprite turns the
          # whole thing OFF rather than leaving the last screen's layers named. Those layer
          # numbers belong to whatever is on screen now, so leaving them is not a harmless
          # leftover — it blends the wrong picture.
          def blend_control(screenful)
            layer = layer_on(screenful)
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
