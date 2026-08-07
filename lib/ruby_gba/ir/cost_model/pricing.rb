# frozen_string_literal: true

module RubyGBA
  module IR
    class CostModel
      # What ONE op costs, in scanlines. Nothing here knows about frames, loops or
      # budgets — it answers "how dear is this single thing", and {Rollup} decides how
      # many times a frame pays for it.
      #
      # Two questions get asked of every node: what the op itself costs, and what the
      # operands it was handed cost. Keeping those apart is what lets the operand half be
      # found from a node's attributes instead of named one kind at a time — see
      # #operand_cost.
      module Pricing
        private

        # What one statement costs: the op itself, plus the arithmetic in whatever operands
        # it was given. The split is the same one #expr_cost makes, and for the same reason —
        # `blit :ship, (col * W), (top + row)` does the multiply and the add before it draws
        # a single pixel, and a `clamp` whose bounds are worked out at run time evaluates
        # them every time. Operands are found from the node's attributes, so an op added
        # later can't hold unpriced work.
        def op_cost(node, worst: true)
          own_op_cost(node) + operand_cost(node, worst)
        end

        def own_op_cost(node)
          case node.kind
          when :pixel then @weights[:plot_pixel]                     # one hand-plotted pixel
          when :fill_rect then plot_rect_cost(node[:w], node[:h])    # a CPU per-pixel loop
          when :dma_fill_rect, :draw_rect_at then dma_rows_cost(node[:w], node[:h]) # per-row DMA
          when :clear_screen then dma_blob_cost(SCREEN_W * SCREEN_H) # the whole screen in one DMA
          when :draw_text then Fonts.get(node[:font]).text_pixels(node[:text]) * @weights[:plot_pixel]
          when :draw_digit then Fonts.get(node[:font]).max_glyph_pixels(DIGITS) * @weights[:plot_pixel]
          when :blit then blit_cost(node[:name])
          when :blit_pose then blit_cost(node[:poses].first)         # one pose draws; all are the same size
          when :save_region, :restore_region then region_cost(node[:buffer])
          # Tiled-mode per-frame upkeep: one position rewrite per presented sprite, and
          # the two scroll-register writes when a background moves.
          when :present_objects then node[:names].to_a.length * @weights[:obj_write]
          when :scroll_background then @weights[:scroll_write]
          # Telling the display what to show, without redrawing a pixel: where the window
          # over the picture sits, and how far the whole picture is blended toward a color.
          # Cheap next to drawing, but not free, and `shake_screen` moves the camera on
          # every frame it runs.
          when :camera then @weights[:camera_move]
          when :fade then fade_cost(node)
          when :background then dma_blob_cost(background_cells(node)) # one-time map stamp (boot, not per frame)
          when :play_song then song_cost(node[:name])
          when :beep then BEEP_WRITES * @weights[:sound_write]
          when :noise then NOISE_WRITES * @weights[:sound_write]
          when :wave then WAVE_WRITES * @weights[:sound_write]
          when :stop_wave then STOP_WAVE_WRITES * @weights[:sound_write]
          when :enable_sound then ENABLE_WRITES * @weights[:sound_write]
          when :stop_music then STOP_WRITES * @weights[:sound_write]
          # Logic / compute statements. Each is at least one step; the expression it
          # evaluates is added by #op_cost, so a divide buried in a value shows up. This
          # is what stops a compute loop — enemy AI, physics, a list walk — from reading
          # as free: run it N times and its per-op cost scales with N.
          when :set, :add, :sub then @weights[:op_step]
          when :copy, :negate, :abs, :negate_abs then @weights[:op_step]
          when :clamp then 2 * @weights[:op_step] # a low compare and a high compare
          when :list_push, :list_set, :list_drop then @weights[:op_step]
          # Every change to a save_var mirrors it back to save memory, right after the
          # change. Save memory sits on a slow bus and takes one byte at a time, so this
          # costs several times the step that triggered it — worth seeing when a game
          # keeps a live counter in one.
          when :save_store then @weights[:save_write]
          else note_unpriced(node.kind, FREE_STATEMENT_KINDS)
          end
        end

        # A fade is two register writes: which way to blend, and how far. "How far" is a
        # percentage, and the hardware counts in sixteenths — so a level the game works
        # out has to be converted as the program runs, which is a multiply and a divide on
        # top. A level written into the program is converted while building and is free.
        # (The conversion is built by the lowering, so it is not in the tree to be found;
        # Backends::GBA::Drawing#emit_fade is where it lives. If one moves, both must.)
        def fade_cost(node)
          return @weights[:fade_set] if const_side(node[:amount])

          @weights[:fade_set] + @weights[:op_mul] + @weights[:op_div_const]
        end

        # A kind that fell through to the zero-cost fallback: 0 if it's a declared-free
        # kind, otherwise 0 too — but remembered, so the estimate can announce that it
        # couldn't account for it (rather than silently treating real work as free).
        def note_unpriced(kind, free_kinds)
          @unpriced << kind unless free_kinds.include?(kind) || @unpriced.include?(kind)
          0
        end

        # The cost of evaluating a value expression: every operator it's built from,
        # summed. A bare variable or literal is a load — effectively free — so the cost
        # is in the operators, and a divide weighs far more than an add (see the op_*
        # weights). This is why `(a * b) / c` in a per-frame loop isn't free, and why
        # the chain of comparisons behind a collision test (overlaps?) has a real cost.
        #
        # Two parts, and the split is what keeps it honest: what this node's own operator
        # costs, plus what every operand hanging off it costs. Operands are found from the
        # node's attributes rather than named one kind at a time, so a value kind added
        # later cannot go unpriced inside.
        # +worst+ chooses which question is being asked: true for "everything this frame
        # could cost", false for "what every frame really pays". They differ only where an
        # op has a worst case it seldom reaches — see #pixels_overlap_cost.
        def expr_cost(value, worst: true)
          return 0 unless value.is_a?(Node)

          own_cost(value, worst) + operand_cost(value, worst)
        end

        # What a value's own operator costs, ignoring what it is applied to.
        def own_cost(value, worst)
          case value.kind
          when :binop then op_weight(value)
          when :mul_fix then @weights[:op_mul_fix]
          when :div_fix then div_fix_weight(value)
          # One instruction, so it is priced at the cheapest tier. Measured against the
          # same harness the weights come from, it is 0.019 scanlines where an add is
          # 0.029 and the division it replaces is 0.177 — so this tier slightly
          # over-charges it, which is the safe direction to be wrong in.
          when :shift_right then @weights[:op_step]
          when :neg then @weights[:op_step]
          when :chance then @weights[:op_step] # a random draw and a compare
          when :pixels_overlap then worst ? pixels_overlap_cost(value) : 0
          else note_unpriced(value.kind, FREE_VALUE_KINDS) # int/var_ref/held/… are free loads; anything else is unknown
          end
        end

        # Every value operand a node holds, priced too. A read like `t[i]` is a single
        # load and costs nothing, but whatever computes `i` is arithmetic like any other:
        # charging an index nothing would hide a third of the raycaster's frame, whose hot
        # divides all sit inside `world[…]`. Attributes that aren't nodes — a name, a
        # width, a list of image names — aren't operands and add nothing.
        def operand_cost(value, worst)
          value.attrs.each_value.sum do |slot|
            slot.is_a?(Array) ? slot.sum { |item| expr_cost(item, worst: worst) } : expr_cost(slot, worst: worst)
          end
        end

        # The worst-case cost of a per-pixel collision test: walking the whole overlap
        # rectangle. That rectangle can be no wider than the narrower sprite and no taller
        # than the shorter one, so its worst case is min(widths) x min(heights) cells,
        # each priced at one overlap_pixel. (The cheap box gate around it is priced as the
        # ordinary comparisons it lowers to.)
        #
        # This is a real cost — two 16x16 sprites lying on top of each other genuinely walk
        # 256 cells, about a quarter of a frame — but it is a cost the frame seldom pays.
        # The walk covers the OVERLAP rectangle, so two sprites that miss walk nothing at
        # all, and that is what almost every pair does on almost every frame. So it counts
        # in the worst case and not in the recurring load, the same call #selectivity makes
        # for a `pressed` body. Charging it every frame made a shmup whose busiest measured
        # frame is 54 scanlines report 101% of budget.
        def pixels_overlap_cost(node)
          aw, ah = mask_dims(node[:a_poses])
          bw, bh = mask_dims(node[:b_poses])
          [aw, bw].min * [ah, bh].min * @weights[:overlap_pixel]
        end

        # A sprite's pixel dimensions from its (same-size) poses, or [0, 0] if unknown.
        def mask_dims(poses)
          dims = @bitmaps && @bitmaps[poses.first]
          dims ? [dims[0], dims[1]] : [0, 0]
        end

        # An operator's weight: multiply and divide are their own (pricier) tiers;
        # everything else — add, subtract, the comparisons, the and/or that combine
        # conditions — is one plain step.
        #
        # Dividing and wrapping have three tiers, because the lowering gives them three
        # costs. By a POWER OF TWO written into the program it is a shift or two, priced
        # as a plain step. By ANY OTHER number written into the program it is a multiply
        # by a reciprocal worked out at build time — dearer than a shift, far cheaper
        # than a call. Only a divisor the GAME works out still reaches the console's
        # divide routine. So `explain` can say a divide by 256 is free, a divide by 100
        # costs about an add and a half, and a divide by a variable costs five times
        # that. Those are the same facts the lowering acts on; if one moves, both must.
        def op_weight(node)
          case node[:op]
          when :* then power_of_two_operand?(node[:rhs]) ? @weights[:op_step] : @weights[:op_mul]
          when :/, :% then divide_weight(const_side(node[:rhs]))
          else @weights[:op_step]
          end
        end

        # Dividing one number that holds a fraction by another. When the numerator is
        # written into the program it is widened at build time and this is an ordinary
        # division, priced as one. Otherwise the widening happens as the program runs and
        # the division walks the whole width of the answer, at a fixed price — there is
        # no cheap way to know in advance how much of that width matters.
        def div_fix_weight(node)
          return @weights[:op_div_fix] unless div_fix_folds?(node)

          divide_weight(const_side(node[:rhs]))
        end

        # Whether a fraction divide's numerator is a number written into the program and
        # small enough to widen while building — the case that lowers to an ordinary
        # division, so it is priced and named as one.
        # (The same test Backends::GBA::Divide#folds_to_plain_divide? makes; if one
        # moves, both must.)
        def div_fix_folds?(node)
          numerator = const_side(node[:lhs])
          return false unless numerator

          widened = numerator << node[:fraction_bits]
          widened > Int32::MIN && widened <= Int32::MAX
        end

        # What one divide or wrap costs, from where its divisor comes from. A negative
        # divisor reduces the same way its size does, with the answer flipped after.
        #
        # op_div is one number for something that is not one price: a division worked out
        # as the program runs walks the answer a bit at a time, so it costs about 79
        # cycles plus 4 for every bit of the answer — 0.064 scanlines for a small answer
        # and 0.194 for a full-width one. This prices it at the small end, which is where
        # it is measured. The spread used to be five-fold and is now under two and a half,
        # which is what makes a single number defensible at all.
        def divide_weight(divisor)
          size = divisor&.abs
          return @weights[:op_div] unless size && size > 1
          return @weights[:op_step] if power_of_two?(size)

          @weights[:op_div_const]
        end

        # What to call one arithmetic operator in a report, or nil for anything that
        # costs a plain step — which is most arithmetic, and not worth a line of its own.
        # This lives here, beside the weights, because it makes the same three-way call
        # #divide_weight makes: a name that disagreed with the price would be worse than
        # no name at all.
        #
        # Naming the divides apart is the point. They differ by five times, an author can
        # act on which one they have (make the divisor a fixed number, precompute a
        # `table`), and one word for all three would hide exactly that.
        def arithmetic_kind(value)
          case value.kind
          when :binop then binop_kind(value)
          when :mul_fix then Arithmetic.new(op: :multiply_fraction, name: "multiply (fraction)")
          when :div_fix then div_fix_kind(value)
          end
        end

        def div_fix_kind(value)
          return divide_kind(const_side(value[:rhs])) if div_fix_folds?(value)

          Arithmetic.new(op: :divide_fraction, name: "divide (fraction)")
        end

        def binop_kind(value)
          case value[:op]
          when :* then Arithmetic.new(op: :multiply, name: "multiply") unless power_of_two_operand?(value[:rhs])
          when :/, :% then divide_kind(const_side(value[:rhs]))
          end
        end

        # Which divide a divisor gives, named rather than priced — the same split
        # #divide_weight prices. A power of two is a shift, no dearer than an add, so it
        # gets no line of its own.
        def divide_kind(divisor)
          size = divisor&.abs
          return Arithmetic.new(op: :divide_worked_out, name: "divide (worked out)") unless size && size > 1
          return nil if power_of_two?(size)

          Arithmetic.new(op: :divide_fixed, name: "divide (fixed number)")
        end

        # Whether the right-hand side is a power of two settled while building — the
        # thing that lets the lowering reduce the operation to shifts.
        def power_of_two_operand?(operand)
          value = const_side(operand)
          value&.positive? && power_of_two?(value)
        end

        def power_of_two?(value)
          value > 1 && (value & (value - 1)).zero?
        end

        # How many map cells a background stamps — the map is rows of tile cells, so
        # this is their total, the size of the one-time upload to tile memory.
        def background_cells(node)
          node[:map].to_a.sum { |row| row.respond_to?(:length) ? row.length : 1 }
        end

        # A rectangle filled the slow way: a CPU loop writing each pixel, which is what
        # fill_rect does in direct color. No per-row DMA setup, just the per-pixel plot, so
        # the cost is the area times one plotted pixel — far dearer than the DMA fill
        # (dma_fill_rect) for the same rectangle.
        def plot_rect_cost(w, h)
          w * h * @weights[:plot_pixel]
        end

        # A rectangle filled/copied by DMA one row at a time (a DMA fill, an opaque blit, a
        # save/restore): each row is a DMA, so the fixed per-row setup is paid h times,
        # and the pixels are transferred on top. This is why a tall rectangle costs more
        # than a wide one of the same area.
        def dma_rows_cost(w, h)
          w = const_side(w)
          h = const_side(h)
          # A side the game works out as it runs has no provable size, so — like a loop
          # whose trip count is unknown — it contributes nothing rather than a guess, and
          # the estimate says out loud that it could not account for it.
          return 0 unless w && h

          (h * @weights[:dma_setup]) + (w * h * @weights[:dma_pixel])
        end

        # A rect side as a build-time number, or nil when the game works it out as it
        # runs (a variable, an expression).
        def const_side(side)
          case side
          when Integer then side
          when Node then side[:value] if side.kind == :int
          end
        end

        # Whether a rect's size is only known at run time, so #dma_rows_cost had to
        # leave it out of the estimate.
        def runtime_sized_rect?(node)
          return false unless %i[fill_rect dma_fill_rect draw_rect_at].include?(node.kind)

          const_side(node[:w]).nil? || const_side(node[:h]).nil?
        end

        # A single DMA transfer of +pixels+ pixels in one shot (a whole-screen clear):
        # one setup, then the transfer. For a big blob the transfer dominates.
        def dma_blob_cost(pixels)
          @weights[:dma_setup] + pixels * @weights[:dma_pixel]
        end

        # The per-frame cost of playing +name+. The sequencer keeps a cursor per voice
        # and writes only the note currently due each frame (see the GBA backend's
        # pointer-based emit_play_song), so the cost is per active VOICE, not per note —
        # a long tune costs the same as a short one, the same way a real GBA sound
        # driver works. An unknown name costs nothing (the backend reports it).
        def song_cost(name)
          song = @songs && @songs[name]
          return 0 unless song

          song[:voices].length * @weights[:music_voice]
        end

        # How many notes a song holds — summed across its parts. Informational (shown in
        # the music-budget message); the per-frame cost no longer depends on it.
        def song_notes(name)
          song = @songs && @songs[name]
          return 0 unless song

          song[:voices].sum { |voice| voice[:events].to_a.length }
        end

        # A blit costs by how it's drawn: an opaque image streams by per-row DMA, but a
        # transparent one is plotted pixel by pixel (so its see-through pixels can be
        # skipped), which is far dearer. The size and transparency live on the bitmap
        # definition, catalogued in #index. An unknown image costs nothing.
        def blit_cost(name)
          w, h, transparent = @bitmaps && @bitmaps[name]
          return 0 unless w

          transparent ? w * h * @weights[:plot_pixel] : dma_rows_cost(w, h)
        end

        # Saving or restoring a patch copies its footprint by per-row DMA — the same
        # cost as an opaque blit of that size. The size lives on the backing_buffer
        # declaration, catalogued in #index. An unknown buffer costs nothing.
        def region_cost(name)
          w, h = @backing && @backing[name]
          w ? dma_rows_cost(w, h) : 0
        end
      end
    end
  end
end
