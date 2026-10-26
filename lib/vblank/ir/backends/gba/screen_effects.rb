# frozen_string_literal: true

module VBlank
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

          def placed_fade = @layout.screen.placed_fade

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
            if @layout.fading.palette_walk?(node)
              return emit_walked_fade_by_screen_up(node) if @palette_tint.tint_crosses_screens?

              return emit_palette_fade(node)
            end
            # A fade takes the tint's place, so no tint is left to put back on a change of screen.
            @palette_tint.emit_clear_remembered_tint if @palette_tint.tint_crosses_screens?

            # On a screen drawn through a color table the two effects are separate pieces
            # of hardware, so nothing puts a tint away by itself. The display still holds
            # one whole-picture effect at a time — that is the rule the DSL states and the
            # interpreter models — so a fade puts the colors back. Only a program that
            # tints such a screen emits this, and the check inside is one compare.
            if @palette_tint.moves_color_table? && @palette_tint.palette_screen?(node)
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
          # PaletteTint::DARKEN). The blend registers are not written for this fade, so the
          # layer keeps the setup it was given at boot and there is nothing to hand back when
          # it lifts.
          #
          # WHAT IT MAY HAVE TO HAND BACK IS ANOTHER FADE'S. The display holds one fade at a
          # time, so this one takes the place of whatever fade was in force — and in a game
          # with a see-through layer that can be a fade the display itself was doing: one
          # placed in the stack, or one left on from a painted screen that has no colors to
          # walk. That fade holds the blend the layer needs, and nothing but this statement
          # is going to lift it (see LayerBlend#emit_blend_back_from_display_fade).
          def emit_palette_fade(node, mode: @layout.modes.mode_at(node))
            @layer_blend.emit_blend_back_from_display_fade
            toward = node.toward == :black ? PaletteTint::DARKEN : Graphics::Color.resolve(node.toward)
            @palette_tint.emit_palette_tint(color: toward,
                                            amount: node.amount,
                                            fraction_bits: node.fraction_bits,
                                            mode: mode)
          end

          # A FADE THAT WALKS THE COLORS, IN A GAME WITH MORE THAN ONE SCREEN, is done the way
          # the screen up NOW does it, as a tint is (see #emit_tint_by_screen_up): a flash runs
          # from a routine of its own every frame, whichever scene is up. The plain bitmap
          # screen has no colors to walk, so there the display fades it, in sixteenths; every
          # other screen walks its tables. And it is kept, like a tint, so the next screen to
          # take over puts it back its own way (see #emit_kept_tint_on_entry).
          def emit_walked_fade_by_screen_up(node)
            toward = walked_fade_color(node)
            @palette_tint.emit_remember_tint(toward, node.amount, node.fraction_bits)
            emit_for_each_screen_kind do |mode|
              mode == IR::Modes::DIRECT ? emit_walked_fade_by_display : emit_palette_fade(node, mode: mode)
            end
          end

          # The color a walked fade is kept as: black's rounding marker, or white with the bit
          # that tells it from a tint toward white.
          def walked_fade_color(node)
            node.toward == :black ? PaletteTint::DARKEN : Graphics::Color.resolve(:white) | PaletteTint::BRIGHTEN
          end

          # The fade just kept in TINT_ASKED, done by the display on the plain bitmap screen:
          # toward black or white by the marker, as far as the walk's thirty-seconds come to in
          # the display's sixteenths. A fade of nothing leaves the effect off rather than a fade
          # of nothing on, which is what a screen with a see-through layer looks for on arrival.
          def emit_walked_fade_by_display
            load_var(KEPT, PaletteTint::TINT_ASKED)
            emit_display_fade_from_kept
          end

          # KEPT holds a kept fade (its color is DARKEN or carries BRIGHTEN): tell the display.
          def emit_display_fade_from_kept
            off = gensym
            brighten = gensym
            done = gensym
            emit(ASM.and_imm(ACC, KEPT, (1 << PaletteTint::TINT_COLOR_SHIFT) - 1))
            emit(ASM.lsr_imm(ACC, ACC, 1))                     # a walk's thirty-seconds, in sixteenths
            emit(ASM.cmp_imm(ACC, 0))
            emit_branch(:bcond, off, cond: :eq)
            store_halfword_acc(REG_BLDY)
            emit_whole_screen_window
            emit(ASM.lsr_imm(ACC, KEPT, PaletteTint::TINT_COLOR_SHIFT))
            emit(ASM.tst_imm(ACC, PaletteTint::DARKEN))
            emit_branch(:bcond, brighten, cond: :eq)
            write_reg16(REG_BLDCNT, BLD_DARKEN | placed_fade.blend_target_bits(nil))
            emit_branch(:b, done)
            place_label(brighten)
            write_reg16(REG_BLDCNT, BLD_BRIGHTEN | placed_fade.blend_target_bits(nil))
            emit_branch(:b, done)
            place_label(off)
            write_reg16(REG_BLDCNT, 0)
            place_label(done)
          end

          # Which layers the fade reaches and which way, then how far.
          def emit_fade_registers(node)
            emit_fade_window(node.reaches, node.area) if @layout.fading.rectangle_fades?
            emit_fade_control(node)

            if (steps = constant_fade_steps(node))
              write_reg16(REG_BLDY, steps)
            else
              @lowering.value(display_steps_value(node))
              store_halfword_acc(REG_BLDY)
            end
          end

          # A FADE HELD TO A RECTANGLE is the display's own fade with its first window switched
          # on. The window is a rectangle the display is told about, and two registers say what
          # happens inside it and outside: which layers show (all of them, both sides, always
          # here) and whether the color effect — the darkening a fade is — applies. So holding a
          # fade inside a rectangle is the effect switched on inside and off outside, and
          # `outside:` is the other way round.
          #
          # The window is switched on for the whole of a game that holds a fade anywhere (see
          # Drawing#display_window_bits), so every fade in it says where it reaches, a fade over
          # the whole screen included: the effect on both sides. The last fade said is the one
          # in force, as it always is. Four register writes, every one of a number settled at
          # build time.
          #
          # Right and bottom are one past the last column and row the window covers, which is how
          # the display counts them. The rectangle was clipped to the screen as the program was
          # built, so the display is never handed an edge past it. +reaches+ nil is the whole
          # screen, and then the rectangle does not matter and nothing is written for it.
          def emit_fade_window(reaches, area)
            write_reg16(REG_WIN0H, reaches ? (area[0] << 8) | area[2] : 0)
            write_reg16(REG_WIN0V, reaches ? (area[1] << 8) | area[3] : 0)
            inside, outside = fade_window_switches(reaches)
            write_reg16(REG_WININ, inside)
            write_reg16(REG_WINOUT, outside)
          end

          # What the window's two regions are told: every layer shows in both, and the darkening
          # applies on the side the fade reaches, or on both for a fade over the whole screen.
          def fade_window_switches(reaches)
            [reaches == :outside ? WIN_ALL_LAYERS : WIN_ALL_LAYERS | WIN_EFFECT,
             reaches == :inside ? WIN_ALL_LAYERS : WIN_ALL_LAYERS | WIN_EFFECT]
          end

          # The window as power-on leaves it in a game that holds a fade, and as a tint the
          # display mixes in leaves it: no rectangle, and the effect on everywhere. A tint is the
          # same color effect, so it has to say it reaches the whole screen, or it would stop at
          # the rectangle the last fade was held to.
          def emit_whole_screen_window
            emit_fade_window(nil, nil) if @layout.fading.rectangle_fades?
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
            return emit_tint_by_screen_up(node) if @palette_tint.tint_crosses_screens?

            emit_tint_for_mode(node, @layout.modes.mode_at(node))
          end

          # The tint on the screen +mode+ draws on.
          def emit_tint_for_mode(node, mode)
            unless mode == IR::Modes::DIRECT
              # A tint takes the place of a fade as a fade does, so it hands back the blend a
              # fade the display was doing held (see #emit_palette_fade).
              @layer_blend.emit_blend_back_from_display_fade
              return @palette_tint.emit_palette_tint(color: Graphics::Color.resolve(node.color),
                                                     amount: node.amount,
                                                     fraction_bits: node.fraction_bits,
                                                     mode: mode)
            end

            write_reg16(PALETTE_START, Graphics::Color.resolve(node.color)) # the backdrop IS the tint
            emit_whole_screen_window
            write_reg16(REG_BLDCNT, TINT_BLEND)
            if (steps = constant_fade_steps(node))
              write_reg16(REG_BLDALPHA, tint_weights(steps))
            else
              @lowering.value(display_steps_value(node))
              emit_blend_weights_from_acc
            end
          end

          # The picture's layer blended with the backdrop, which is how the plain bitmap screen
          # tints.
          TINT_BLEND = BLD_ALPHA | BLD_BG2 | (BLD_BACKDROP << BLD_SECOND_SHIFT)

          # A TINT IN A GAME WITH MORE THAN ONE SCREEN is done the way the screen up NOW does
          # it, which a statement cannot know from where it is written: a flash runs from a
          # routine of its own every frame, whichever scene is up. So the tint is kept for the
          # next change of screen (see PaletteTint::TINT_ASKED), and then done one way or the
          # other by which screen the display is in.
          def emit_tint_by_screen_up(node)
            @palette_tint.emit_remember_tint(Graphics::Color.resolve(node.color), node.amount, node.fraction_bits)
            emit_for_each_screen_kind { |mode| emit_tint_for_mode(node, mode) }
          end

          # The block's code once for each kind of screen the game draws on, each run only while
          # the display is in that one: a compare against which screen is up, per kind.
          def emit_for_each_screen_kind
            done = gensym
            @layout.modes.modes_in_use.each do |mode|
              other = gensym
              load_var(ACC, MODE_STATE)
              emit(ASM.cmp_imm(ACC, MODE_MARKERS.fetch(mode)))
              emit_branch(:bcond, other, cond: :ne)
              yield mode
              emit_branch(:b, done)
              place_label(other)
            end
            place_label(done)
          end

          # PUT THE TINT KEPT IN TINT_ASKED BACK as the display changes to +mode+'s screen.
          # What the last screen left would be wrong here either way round: a walked table is
          # sent again as drawn, and the blend the plain bitmap screen tints with reads the
          # first color of a table, which a tiled screen has just filled with its own. With no
          # tint kept nothing is written, so a fade the display is holding stays on.
          def emit_kept_tint_on_entry(mode)
            return unless @palette_tint.tint_crosses_screens?
            return emit_blend_to_kept_tint if mode == IR::Modes::DIRECT

            @palette_tint.emit_walk_to_kept_tint(mode) do
              # The blend the plain bitmap screen tinted with would mix this screen's third
              # layer with its backdrop. A see-through layer's own blend is written as the
              # screen takes over — unless the display was fading the screen before, which
              # held it; the kept effect is walked into the colors now, so it hands it back.
              if @layer_blend.see_through?
                @layer_blend.emit_blend_back_from_display_fade
              else
                write_reg16(REG_BLDCNT, 0)
              end
            end
          end

          # Where the kept tint waits while its color goes in: a change of screen runs between
          # statements, so nothing else is held there.
          KEPT = 2

          def emit_blend_to_kept_tint
            skip = gensym
            fade = gensym
            load_var(KEPT, PaletteTint::TINT_ASKED)
            emit(ASM.cmp_imm(KEPT, 0))
            emit_branch(:bcond, skip, cond: :eq)
            # A kept fade is the display's fade on this screen, not a tint (see
            # #emit_walked_fade_by_screen_up).
            emit(ASM.lsr_imm(ACC, KEPT, PaletteTint::TINT_COLOR_SHIFT))
            emit(ASM.tst_imm(ACC, PaletteTint::DARKEN))
            emit_branch(:bcond, fade, cond: :ne)
            emit(ASM.tst_imm(ACC, PaletteTint::BRIGHTEN))
            emit_branch(:bcond, fade, cond: :ne)
            emit_tint_from_kept
            emit_branch(:b, skip)
            place_label(fade)
            emit_display_fade_from_kept
            place_label(skip)
          end

          # KEPT holds a kept tint: the backdrop becomes its color and the picture is mixed with it.
          def emit_tint_from_kept
            emit(ASM.lsr_imm(ACC, KEPT, PaletteTint::TINT_COLOR_SHIFT))
            store_halfword_acc(PALETTE_START) # the backdrop IS the tint
            emit_whole_screen_window # a tint said on another screen did not say where it reaches
            write_reg16(REG_BLDCNT, TINT_BLEND)
            emit(ASM.and_imm(ACC, KEPT, (1 << PaletteTint::TINT_COLOR_SHIFT) - 1))
            emit(ASM.lsr_imm(ACC, ACC, 1)) # a walk's thirty-seconds, in the display's sixteenths
            emit_blend_weights_from_acc
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
            emit_number(TMP, BLD_MAX)
            emit(ASM.sub_reg(TMP, TMP, ACC))              # r1 = what is left of the near side
            emit(ASM.orr_reg_lsl(ACC, TMP, ACC, 8))       # ...with the far side's share above it
            store_halfword_acc(REG_BLDALPHA)
          end

          # Show the picture in blocks of this many pixels each way.
          #
          # One register holds the size, and nothing else is written: which things are
          # drawn in blocks was settled as the cartridge was built (see Pixelation). The
          # register keeps four sizes — across and down for backgrounds, then across and
          # down for sprites — each in four bits and each one LESS than the pixels, so the
          # same number goes into all four places.
          #
          # A size written in the program is worked out here and stored as a plain number.
          # One the game works out is held to the sizes there are first, since the fields
          # are four bits wide and a number past them would spill into its neighbour.
          def emit_pixelate(node)
            if (size = const_int(node.size))
              field = Blocks.size(size) - 1
              pair = field | (field << MOSAIC_DOWN_SHIFT)
              return write_reg16(REG_MOSAIC, pair | (pair << MOSAIC_SPRITES_SHIFT))
            end

            @lowering.value(node.size)
            emit(ASM.cmp_imm(ACC, 1))
            emit(ASM.mov_imm_cond(:lt, ACC, 1))
            emit(ASM.cmp_imm(ACC, Blocks::LARGEST))
            emit(ASM.mov_imm_cond(:gt, ACC, Blocks::LARGEST))
            emit(ASM.sub_imm(ACC, ACC, 1))
            emit(ASM.orr_reg_lsl(ACC, ACC, ACC, MOSAIC_DOWN_SHIFT)) # across and down
            emit(ASM.orr_reg_lsl(ACC, ACC, ACC, MOSAIC_SPRITES_SHIFT)) # ...and the same pair again for sprites
            store_halfword_acc(REG_MOSAIC)
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
