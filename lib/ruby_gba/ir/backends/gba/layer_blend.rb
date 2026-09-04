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
        # NEITHER PATH SURVIVES A FADE, measured rather than assumed. The sprite's own bit
        # frees it from the effect field, but a see-through sprite still has to be told
        # WHAT it blends with — the far side of that same register — and a fade writes the
        # register whole. So a fade takes the blend from both paths for as long as it runs,
        # and both get it back when it lifts (see Drawing#emit_fade_sharing_the_blend).
        #
        # Keeping the far side across a fade was tried, and the picture it gives is worse.
        # The sprite does go on blending — but the display then blends it with the darkened
        # picture WITHOUT darkening the sprite itself, so fading out to a game-over screen
        # leaves half-bright ghosts floating on a black screen. Letting the fade have the
        # whole register makes everything darken together, which is what a fade out is
        # supposed to look like, and it costs nothing to do.
        #
        # An author writes the same keyword either way and never learns which they got.
        module LayerBlend
          include Constants

          # attr0 bits 10-11 = 1: draw this sprite through the blend rather than straight.
          # (The same two bits hold OBJ_WINDOW_MODE at 2, which is why they are one field
          # and a sprite cannot be both.)
          OBJ_SEMI_TRANSPARENT = 0x0400

          # Which layer this program can be seen through, and how much — read off the
          # stack the program declared. Nothing at all for a program that declares none,
          # which is what keeps such a program byte for byte as it was.
          def prepare_layer_blend(program)
            node = program.walk.find { |n| n.kind == :layers && n.transparent }
            return @see_through = nil unless node

            fixed = const_int(node.transparency)
            @see_through = { layer: node.transparent,
                             amount: node.transparency,
                             # An amount the program works out has no number here. What boot
                             # writes is what its variable starts at, so the first frame is
                             # already right rather than right one frame later.
                             steps: fade_steps(fixed || starting_amount(program, node.transparency)) }
          end

          # What an amount the game works out starts at: the initial value of the variable
          # it reads, when it is one plain variable. An amount worked out from more than
          # that starts at the picture as drawn — the safe way to be wrong for one frame.
          def starting_amount(program, amount)
            return 0 unless amount.kind == :var_ref

            # The first thing written to that name is its declaration, which the build has
            # already moved to the front of the program.
            first = program.walk.find { |n| n.kind == :set && n.var == amount.name }
            (first && const_int(first.value)) || 0
          end

          # Does this program see through a layer of SCENERY? Only that half touches the
          # blend-control register, and only that half has to be set up at boot.
          def blends_scenery?
            @see_through && see_through_scenery.any?
          end

          # Is this sprite in the see-through layer? Asked once per sprite while its table
          # entry is being worked out, so the per-frame draw carries the bit for free.
          def see_through_object?(node)
            @see_through && node.layer == @see_through[:layer]
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
            write_reg16(REG_BLDALPHA, blend_weights(@see_through[:steps]))
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
            emit_blend_amount(@see_through[:amount])
          end

          # HOW SEE-THROUGH THE LAYER IS, NOW. A picture whose amount the program works out
          # gets one of these at every frame boundary, so the display is told again before
          # the frame it applies to is drawn.
          #
          # It writes the weights and nothing else: which layers blend with which was
          # settled at boot and does not change, so the per-frame part is one register.
          def emit_see_through(node)
            emit_blend_amount(node.amount) if @see_through
          end

          def emit_blend_targets
            mode = blends_scenery? ? BLD_ALPHA : BLD_OFF
            write_reg16(REG_BLDCNT, mode | near_side_bits | (far_side_bits << BLD_SECOND_SHIFT))
          end

          def emit_blend_amount(amount)
            if (fixed = const_int(amount))
              return write_reg16(REG_BLDALPHA, blend_weights(fade_steps(fixed)))
            end

            @lowering.value(fade_steps_value(amount))
            emit_clamp_blend_steps
            emit_blend_weights_from_acc
          end

          # The weight pair as one halfword: how much of the layer itself survives in the
          # low byte, how much of what is behind comes through above it. The same shape
          # the tint's weights take, because it is the same blend unit.
          def blend_weights(steps)
            (BLD_MAX - steps) | (steps << 8)
          end

          private

          # The scenery in the see-through layer, and the scenery behind it. Both are read
          # off the picture rather than the stack, because what the register names is a
          # hardware layer number and only the picture knows which background got which.
          def see_through_scenery
            @picture.scenery.select { |node| node.layer == @see_through[:layer] }
          end

          def near_side_bits
            bits_for(see_through_scenery)
          end

          # Everything BEHIND the see-through layer: the scenery below it, the sprites
          # below it, and the backdrop, which is behind everything there is.
          def far_side_bits
            kept = IR::Stacking.at_or_above(@picture, @see_through[:layer]).map(&:name)
            behind = @picture.scenery.reject { |node| kept.include?(node.name) }
            bits = BLD_BACKDROP | bits_for(behind)
            bits |= BLD_OBJ if @picture.objects.any? { |node| !kept.include?(node.name) }
            bits
          end

          # The register bits naming these backgrounds. A background's place in the
          # picture IS its hardware layer number (see #prepare_backgrounds), so the bit is
          # that place counted up from the first one.
          def bits_for(nodes)
            nodes.sum(0) { |node| BLD_BG0 << @picture.scenery.index(node) }
          end
        end
      end
    end
  end
end
