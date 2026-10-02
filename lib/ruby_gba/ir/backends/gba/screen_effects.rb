# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # WHAT HAPPENS TO THE WHOLE PICTURE rather than to anything in it: moving the window
        # onto it (the camera), fading it toward black or white, and tinting it toward a
        # colour. None of these redraws anything. Each tells the display to show what is
        # already there differently — slid, darkened, mixed — or, where the display cannot,
        # moves the colour table instead (see PaletteTint).
        #
        # The fade and the tint share their arithmetic with PaletteTint and LayerBlend, which
        # reach it through the backend (#fade_steps_value and friends are public for that reason).
        class ScreenEffects
          include Console::Hardware
          include EmitterCalls

          def initialize(emitter:, primitives:, lowering:, palette_tint:, layer_blend:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @palette_tint = palette_tint
            @layer_blend = layer_blend
            @layout = nil
          end

          attr_writer :layout

          def placed_fade = @layout.placed_fade

          # Move the visible window over the whole picture.
          #
          # The bitmap screen is drawn by the console's one scalable layer, and that
          # layer fetches its pixels starting from a reference point. Write a new
          # reference point and the whole picture slides, with no redrawing at all —
          # which is what makes a screen shake nearly free. The game keeps drawing
          # exactly what it drew before; only the window onto it moves.
          #
          # Two details the hardware needs. The reference point counts in a fixed-point
          # number with 8 fraction bits, so a whole number of pixels is that number
          # shifted up by 8. And the same layer carries a scale/rotate matrix that the
          # console powers on holding zeroes, which would shrink the picture away to
          # nothing; setting it to no-scale-no-rotate here keeps the pan a plain slide.
          # It is set beside the offset rather than at boot so a program that never
          # moves the camera emits not one extra byte.
          def emit_camera(node)
            raise LoweringError, CAMERA_NEEDS_BITMAP if @layout.modes.default_mode == :tiled

            write_reg16(REG_BG2PA, FIXED_ONE)
            write_reg16(REG_BG2PB, 0)
            write_reg16(REG_BG2PC, 0)
            write_reg16(REG_BG2PD, FIXED_ONE)
            emit_camera_axis(node.x, REG_BG2X)
            emit_camera_axis(node.y, REG_BG2Y)
          end

          CAMERA_NEEDS_BITMAP =
            "the camera cannot move a tiled screen yet. It moves the bitmap screen, so " \
            "`shake_screen` needs `screen :bitmap`. To move a tiled background, use " \
            "`scroll_by` or `scroll_to` on the background."

          def emit_camera_axis(value, reg)
            @lowering.value(value)                   # r0 = the offset in whole pixels
            emit(ASM.lsl_imm(ACC, ACC, 8))      # ...into the 8-fraction-bit format
            store_word_acc(reg)
          end

          # Blend the whole picture toward black or white.
          #
          # The console can do this as it draws: one register says which layers to
          # blend and which way, another says how far. Nothing is redrawn and no pixel
          # in memory changes, so a fade costs the same whatever is on screen and the
          # picture is still all there when it lifts. Every layer and the backdrop are
          # blended, so this works the same on a bitmap screen and a tiled one.
          #
          # "How far" counts in sixteenths, while the DSL talks in percent, so the
          # amount is scaled. A fixed amount is worked out here and written as a plain
          # number; an amount the game computes is scaled at run time, which is a
          # multiply and a divide once per call — nothing next to a frame.
          def emit_fade(node)
            return emit_palette_fade(node) if @layout.fading.walks_the_colors?(node)

            # On a screen drawn through a color table the two effects are separate pieces
            # of hardware, so nothing puts a tint away by itself. The display still holds
            # one whole-picture effect at a time — that is the rule the DSL states and the
            # interpreter models — so a fade puts the colors back. Only a program that
            # tints such a screen emits this, and the check inside is one compare.
            if @palette_tint.moves_a_color_table? && @palette_tint.palette_screen?(node)
              @palette_tint.emit_lift_palette_tint(@layout.modes.mode_at(node))
            end
            return emit_fade_beside_see_through(node) if @layer_blend.see_through?

            emit_fade_registers(node)
          end

          # A fade that moves the COLORS rather than asking the display to blend — which
          # is how the games on this console fade, and the only way a see-through layer
          # survives one (IR::Fading says which fades those are and why).
          #
          # Moving every entry of the color table a fraction of the way to black and
          # moving the finished picture there come to the same picture, so this is the
          # tint walk with black or white as the color — rounded the way the display's own
          # fade rounds, so a fade in shows the picture on the same frame either way (see
          # PaletteTint::DARKEN). Nothing else here runs: the blend registers are never
          # written, so the layer keeps the setup it was given at boot and there is nothing
          # to hand back when the fade lifts.
          def emit_palette_fade(node)
            toward = node.toward == :black ? PaletteTint::DARKEN : Graphics::Color.resolve(node.toward)
            @palette_tint.emit_palette_tint(color: toward,
                                            amount: node.amount,
                                            fraction_bits: node.fraction_bits,
                                            mode: @layout.modes.mode_at(node))
          end

          # Which layers the fade reaches and which way, then how far.
          def emit_fade_registers(node)
            emit_fade_control(node)

            if (steps = constant_fade_steps(node))
              write_reg16(REG_BLDY, steps)
            else
              @lowering.value(display_steps_value(node))
              store_halfword_acc(REG_BLDY)
            end
          end

          def emit_fade_control(node)
            mode = node.toward == :white ? BLD_BRIGHTEN : BLD_DARKEN
            write_reg16(REG_BLDCNT, mode | placed_fade.blend_target_bits(node.under))
            # Where this fade sits in the stack, for the window twins to read. Only a
            # program that has twins writes it (see ScreenLayout, which makes the PlacedFade).
            store_word_immediate(placed_fade.fade_stack_index(node.under), var_addr(EFFECT_LINE)) if placed_fade.any?
          end

          # How far the fade has come, in the sixteenths the hardware counts in, for an
          # amount the game works out as it runs.
          #
          # A class method because the estimate prices this conversion, and the conversion
          # is not in the tree to be found — the lowering builds it. Handed a number, it
          # answers the shape, which is what the estimate wants to price.
          def self.fade_steps_value(amount)
            Build.binop(:/, Build.binop(:*, amount, Build.int(Console::Hardware::BLD_MAX)), Build.int(100))
          end

          def fade_steps_value(amount) = ScreenEffects.fade_steps_value(amount)

          # Where the amount waits while the registers around it are written. Free within
          # a statement, like the other scratch registers.
          FADE_HELD = 2

          # A FADE AND A SEE-THROUGH LAYER ARE THE SAME PIECE OF DISPLAY, so only one of
          # them can be in force. The blend unit is told which effect it is running in one
          # field of one register: mixing two layers together, or moving the whole picture
          # toward black. A fade writes that field, and the layer's blend is gone while it
          # holds it — the layer draws solid, and darkens with everything else, which is
          # what a fade out is supposed to look like.
          #
          # What must not happen is that it stays gone. A fade ends AT ZERO — invisible,
          # but still a fade as far as the register is concerned — so without this a single
          # hit flash would leave the water solid for the rest of the game, with nothing on
          # screen or in the build to say why.
          #
          # So a fade of nothing hands the register back rather than writing a dead fade.
          # A zero the author wrote is settled here and costs not one instruction; an amount
          # the game works out is a compare and a branch, which is what a fade walked over
          # frames arrives as.
          def emit_fade_beside_see_through(node)
            if (steps = constant_fade_steps(node))
              return @layer_blend.emit_restore_layer_blend if steps.zero?

              return emit_fade_registers(node)
            end

            emit_fade_or_restore_blend(node)
          end

          def emit_fade_or_restore_blend(node)
            hand_back = gensym
            done = gensym
            @lowering.value(display_steps_value(node))
            emit(ASM.mov_reg(FADE_HELD, ACC))
            emit(ASM.cmp_imm(FADE_HELD, 0))
            emit_branch(:bcond, hand_back, cond: :eq)
            emit_fade_control(node)
            emit(ASM.mov_reg(ACC, FADE_HELD))
            store_halfword_acc(REG_BLDY)
            emit_branch(:b, done)
            place_label(hand_back)
            @layer_blend.emit_restore_layer_blend
            place_label(done)
          end

          # How far a fade or a tint goes in those sixteenths, when its amount is written in
          # the program — whole or with a fraction (see IR::Fading) — and nil when the game
          # works it out.
          def constant_fade_steps(node)
            amount = const_int(node.amount)
            amount && FadeSteps.steps(amount, fraction_bits: node.fraction_bits, walked: false)
          end

          # ...and the same for an amount the game works out, as a value to lower.
          def display_steps_value(node)
            FadeSteps.steps_value(node.amount, fraction_bits: node.fraction_bits, walked: false)
          end

          # Mix a color INTO the whole picture, which is a different piece of the display
          # from the fade above and not a fade with a color argument.
          #
          # Two mechanisms, chosen by the screen — see PaletteTint for the other one, and
          # for why a screen that draws through a color table cannot use this one.
          #
          # The display can blend two layers together as it draws, weighing each one. So
          # the picture is blended against the BACKDROP — the color shown where nothing
          # was drawn — with the backdrop set to the tint. Turn the weights toward the
          # backdrop and the whole picture moves toward that color. Nothing is redrawn
          # and no pixel in memory changes, so this costs the same whatever is on screen
          # and the picture is all still there when the amount returns to 0.
          #
          # This works because on the direct-color screen the picture is one layer of
          # its own colors, so the backdrop is free to be anything and nothing else in
          # the picture reads it. The screens that draw through a shared color table —
          # the tiled one and the tear-free bitmap one — cannot do it this way, because
          # the backdrop is the first color of that table and the picture reads it. They
          # move the table instead, which is the branch at the top of this method.
          #
          # The weights are a pair that adds to sixteen: what is left of the picture,
          # and how much of the color has come in.
          def emit_tint(node)
            if @palette_tint.palette_screen?(node)
              return @palette_tint.emit_palette_tint(color: Graphics::Color.resolve(node.color),
                                                     amount: node.amount,
                                                     fraction_bits: node.fraction_bits,
                                                     mode: @layout.modes.mode_at(node))
            end

            write_reg16(PALETTE_START, Graphics::Color.resolve(node.color)) # the backdrop IS the tint
            write_reg16(REG_BLDCNT, BLD_ALPHA | BLD_BG2 | (BLD_BACKDROP << BLD_SECOND_SHIFT))

            if (steps = constant_fade_steps(node))
              write_reg16(REG_BLDALPHA, tint_weights(steps))
            else
              @lowering.value(display_steps_value(node))
              emit_blend_weights_from_acc
            end
          end

          # The weight pair as one halfword: how much of the picture survives in the low
          # byte, how much of the color comes in above it.
          def tint_weights(steps)
            (BLD_MAX - steps) | (steps << 8)
          end

          # The same pair, for an amount the game works out. r0 holds the steps.
          #
          # Shared by the two things that blend two layers together: a tint on the
          # direct-color screen, and a see-through layer. They mean different things by
          # the two sides — a color coming in, or what is behind showing through — and the
          # register does not care, so neither does this.
          def emit_blend_weights_from_acc
            emit(ASM.load_immediate(TMP, BLD_MAX))
            emit(ASM.sub_reg(TMP, TMP, ACC))              # r1 = what is left of the near side
            emit(ASM.orr_reg_lsl(ACC, TMP, ACC, 8))       # ...with the far side's share above it
            store_halfword_acc(REG_BLDALPHA)
          end

          # An amount past either end settles at that end rather than running off it, the
          # same as the interpreter does. Where the weights go into a register the display
          # itself clamps this is free, but a share worked out here can be more than all of
          # it — and that takes a picture somewhere no color goes.
          #
          # +most+ is the far end: the display's sixteen, or a walk's thirty-two.
          def emit_clamp_blend_steps(most = BLD_MAX)
            emit(ASM.cmp_imm(ACC, 0))
            emit(ASM.mov_imm_cond(:lt, ACC, 0))
            emit(ASM.cmp_imm(ACC, most))
            emit(ASM.mov_imm_cond(:gt, ACC, most))
          end
        end
      end
    end
  end
end
