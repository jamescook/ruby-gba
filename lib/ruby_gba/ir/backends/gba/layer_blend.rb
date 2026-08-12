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
        # TWO PATHS, and the difference is worth having rather than hiding, because one of
        # them survives a fade and the other does not.
        #
        #   A LAYER OF SCENERY is named as the near side of the blend in the blend-control
        #   register, with everything behind it as the far side. That register also holds
        #   WHICH effect is running, so this is the path a fade collides with.
        #
        #   A LAYER OF SPRITES needs none of that. A sprite can be marked see-through in
        #   its own table entry, which blends that sprite and no other whatever the effect
        #   bits say. It is one bit OR'd into an entry the frame already writes — so it
        #   costs nothing, it picks out exactly the sprites in that layer, and it keeps
        #   working while the screen fades.
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
            @see_through = node && { layer: node.transparent, steps: fade_steps(node.transparency) }
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
          # A program whose see-through layer holds only sprites never emits this: those
          # carry their own bit and need no effect mode at all.
          # A see-through layer of SPRITES leaves the effect bits at nothing, and that is
          # the point of the second path: the sprites still blend, because their own
          # entries say so, and the effect a `fade` runs is left free.
          def emit_boot_layer_blend
            mode = blends_scenery? ? BLD_ALPHA : BLD_OFF
            write_reg16(REG_BLDCNT, mode | near_side_bits | (far_side_bits << BLD_SECOND_SHIFT))
            write_reg16(REG_BLDALPHA, blend_weights)
          end

          # The weight pair as one halfword: how much of the layer itself survives in the
          # low byte, how much of what is behind comes through above it. The same shape
          # the tint's weights take, because it is the same blend unit.
          def blend_weights
            steps = @see_through[:steps]
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
