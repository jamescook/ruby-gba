# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Per-pixel sprite collision — the shape-accurate half of `overlaps?`. A cheap
        # box test decides whether two sprites are even near each other; when they are,
        # this walks the rectangle where their boxes overlap and asks whether any pixel
        # is *drawn* (non-transparent) in both at once. That's collision on the art,
        # regardless of shape, and it follows the animation for free — the pixels tested
        # are the frame each sprite is showing right now.
        #
        # To answer that at run time the console needs, for each sprite, a flat table
        # saying which of its pixels are solid. We build one byte per pixel (1 = drawn,
        # 0 = see-through) for every pose, laid out pose after pose, so the picture a
        # sprite is showing is `base + pose * (width * height)`. The whole routine is
        # emitted inline where the test is used, keeping its working state in a handful
        # of hidden variables rather than juggling registers.
        #
        # Three of a test's own operands — a sprite's x, y, and current pose — are
        # themselves value nodes, evaluated through the {Lowering} this class is handed
        # rather than through whatever else happens to own value evaluation.
        class Collision
          include Constants

          # The hidden variables the routine works in (IWRAM scratch, reused each call —
          # a collision test never runs nested inside another).
          PO_AX = :__po_ax   # sprite A's top-left x / y
          PO_AY = :__po_ay
          PO_BX = :__po_bx   # sprite B's top-left x / y
          PO_BY = :__po_by
          PO_A_MASK = :__po_a_mask # address of A's solid-pixel table for its current pose
          PO_B_MASK = :__po_b_mask
          PO_X0 = :__po_x0   # the overlapping rectangle
          PO_Y0 = :__po_y0
          PO_X1 = :__po_x1
          PO_Y1 = :__po_y1
          PO_X = :__po_x     # the walk cursor
          PO_Y = :__po_y
          PO_ROW = :__po_row # a scratch row offset while indexing a mask
          PO_RES = :__po_res # the answer, 0 or 1

          def initialize(emitter:, primitives:, lowering:, bitmaps:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @bitmaps = bitmaps
            @pixel_masks = {} # poses (an array of image names) -> { blob:, w:, h: }
          end

          # Build a solid-pixel table for every distinct set of poses any collision test
          # uses. Runs after the bitmaps are collected (it reads their pixels), before
          # any code is emitted. Cheap and skipped entirely when nothing collides
          # per-pixel.
          def prepare_pixel_masks(program)
            program.walk.each do |node|
              next unless node.kind == :pixels_overlap

              register_pixel_mask(node.a_poses)
              register_pixel_mask(node.b_poses)
            end
          end

          # Reserve one flat solid/transparent table for a poses set: each pose's mask
          # (width*height bytes, 1 where the pixel is drawn) concatenated in order, so a
          # run-time pose index picks its slice by multiplication. Deduplicated by the
          # poses themselves, so sprites sharing art share the table.
          def register_pixel_mask(poses)
            @pixel_masks[poses] ||= begin
              first = @bitmaps.fetch(poses.first)
              bytes = poses.each_with_object(+"".b) { |image, acc| acc << mask_bytes(@bitmaps.fetch(image)) }
              blob = :"__pixmask_#{@pixel_masks.size}"
              @emitter.data_blobs[blob] = bytes
              { blob: blob, w: first.width, h: first.height }
            end
          end

          # One byte per pixel of an image: 1 where it's drawn, 0 where it's the
          # see-through colour (an opaque image, with no transparent colour, is solid
          # everywhere). Same "is this pixel drawn?" test the blit uses to skip
          # transparent pixels.
          def mask_bytes(bmp)
            pixels = bmp.pixels
            transparent = bmp.transparent
            out = (+"".b)
            (bmp.width * bmp.height).times do |i|
              color = pixels.getbyte(i * 2) | (pixels.getbyte((i * 2) + 1) << 8)
              out << ((transparent.nil? || color != transparent) ? 1 : 0).chr
            end
            out
          end

          # Emit the test, leaving 1 (their drawn pixels overlap) or 0 in the
          # accumulator. Structure: stash both sprites' positions and current-pose mask
          # addresses, work out the overlapping rectangle, and if it isn't empty walk it
          # row by row, stopping at the first pixel solid in both.
          def eval_pixels_overlap(node)
            a = @pixel_masks.fetch(node.a_poses)
            b = @pixel_masks.fetch(node.b_poses)

            stash_position(node.a_x, PO_AX, node.a_y, PO_AY)
            stash_position(node.b_x, PO_BX, node.b_y, PO_BY)
            stash_mask_address(node.a_pose, a, PO_A_MASK)
            stash_mask_address(node.b_pose, b, PO_B_MASK)

            # The overlapping rectangle: the later of the two left/top edges, the earlier
            # of the two right/bottom edges.
            store_max(PO_X0, PO_AX, 0, PO_BX, 0)
            store_max(PO_Y0, PO_AY, 0, PO_BY, 0)
            store_min(PO_X1, PO_AX, a[:w], PO_BX, b[:w])
            store_min(PO_Y1, PO_AY, a[:h], PO_BY, b[:h])

            @emitter.emit(ASM.load_immediate(ACC, 0))
            @primitives.store_var(ACC, PO_RES) # default: no overlap

            done = @emitter.gensym
            branch_if_ge(PO_X0, PO_X1, done) # an empty rectangle can't overlap
            branch_if_ge(PO_Y0, PO_Y1, done)
            walk_overlap(a[:w], b[:w], done)

            @emitter.place_label(done)
            @primitives.load_var(ACC, PO_RES)
          end

          private

          # Evaluate an (x, y) pair and stash both into hidden variables.
          def stash_position(x_node, x_var, y_node, y_var)
            @lowering.value(x_node)
            @primitives.store_var(ACC, x_var)
            @lowering.value(y_node)
            @primitives.store_var(ACC, y_var)
          end

          # Work out where the sprite's current pose sits in its mask table —
          # base + pose*(w*h) — and stash the address.
          def stash_mask_address(pose_node, mask, dest)
            @lowering.value(pose_node) # ACC = pose index
            @emitter.emit(ASM.load_immediate(TMP, mask[:w] * mask[:h]))
            @emitter.emit(ASM.mul(ACC, TMP, ACC)) # ACC = pose * area
            @emitter.emit_load_data_address(TMP, mask[:blob])
            @emitter.emit(ASM.add_reg(ACC, TMP, ACC)) # ACC = base + pose*area
            @primitives.store_var(ACC, dest)
          end

          # dest = max(varA + addA, varB + addB).
          def store_max(dest, var_a, add_a, var_b, add_b)
            edge(var_a, add_a)          # ACC = A edge
            edge_into(var_b, add_b, TMP) # TMP = B edge
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            keep = @emitter.gensym
            @emitter.emit_branch(:bcond, keep, cond: :ge) # A >= B: keep A
            @emitter.emit(ASM.mov_reg(ACC, TMP))
            @emitter.place_label(keep)
            @primitives.store_var(ACC, dest)
          end

          # dest = min(varA + addA, varB + addB).
          def store_min(dest, var_a, add_a, var_b, add_b)
            edge(var_a, add_a)
            edge_into(var_b, add_b, TMP)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            keep = @emitter.gensym
            @emitter.emit_branch(:bcond, keep, cond: :le) # A <= B: keep A
            @emitter.emit(ASM.mov_reg(ACC, TMP))
            @emitter.place_label(keep)
            @primitives.store_var(ACC, dest)
          end

          # ACC = the value in +var+ plus a constant (an edge = a corner plus a size).
          def edge(var, add)
            @primitives.load_var(ACC, var)
            @emitter.emit(ASM.add_imm(ACC, ACC, add)) if add.positive?
          end

          def edge_into(var, add, reg)
            @primitives.load_var(reg, var)
            @emitter.emit(ASM.add_imm(reg, reg, add)) if add.positive?
          end

          # Branch to +target+ when var_a >= var_b (signed) — coordinates can be
          # negative when a sprite hangs off the left/top edge.
          def branch_if_ge(var_a, var_b, target)
            @primitives.load_var(ACC, var_a)
            @primitives.load_var(TMP, var_b)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, target, cond: :ge)
          end

          # Walk the overlapping rectangle, row by row and column by column; the moment a
          # pixel is drawn in both sprites, record a hit and jump to +done+. +aw+/+bw+ are
          # the mask row strides (each sprite's width).
          def walk_overlap(aw, bw, done)
            y_loop = @emitter.gensym
            y_end = @emitter.gensym
            x_loop = @emitter.gensym
            x_end = @emitter.gensym
            next_x = @emitter.gensym

            @primitives.load_var(ACC, PO_Y0)
            @primitives.store_var(ACC, PO_Y)
            @emitter.place_label(y_loop)
            branch_if_ge(PO_Y, PO_Y1, y_end)

            @primitives.load_var(ACC, PO_X0)
            @primitives.store_var(ACC, PO_X)
            @emitter.place_label(x_loop)
            branch_if_ge(PO_X, PO_X1, x_end)

            # A pixel counts only if it's drawn in BOTH sprites; a see-through pixel in
            # either means move on to the next column.
            load_mask_byte(PO_A_MASK, aw, PO_AX, PO_AY)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, next_x, cond: :eq)
            load_mask_byte(PO_B_MASK, bw, PO_BX, PO_BY)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, next_x, cond: :eq)
            @emitter.emit(ASM.load_immediate(ACC, 1)) # both solid: a real hit
            @primitives.store_var(ACC, PO_RES)
            @emitter.emit_branch(:b, done)

            @emitter.place_label(next_x)
            increment(PO_X)
            @emitter.emit_branch(:b, x_loop)

            @emitter.place_label(x_end)
            increment(PO_Y)
            @emitter.emit_branch(:b, y_loop)

            @emitter.place_label(y_end)
          end

          # Leave in the accumulator the mask byte for the current cursor pixel of one
          # sprite: mask[(y - oy) * w + (x - ox)], where (ox, oy) is the sprite's corner.
          def load_mask_byte(mask_var, width, ox_var, oy_var)
            @primitives.load_var(ACC, PO_Y)
            @primitives.load_var(TMP, oy_var)
            @emitter.emit(ASM.sub_reg(ACC, ACC, TMP))     # y - oy
            @emitter.emit(ASM.load_immediate(TMP, width))
            @emitter.emit(ASM.mul(ACC, TMP, ACC))         # (y - oy) * width
            @primitives.store_var(ACC, PO_ROW)
            @primitives.load_var(ACC, PO_X)
            @primitives.load_var(TMP, ox_var)
            @emitter.emit(ASM.sub_reg(ACC, ACC, TMP))     # x - ox
            @primitives.load_var(TMP, PO_ROW)
            @emitter.emit(ASM.add_reg(ACC, TMP, ACC))     # the flat index into the mask
            @primitives.load_var(TMP, mask_var)
            @emitter.emit(ASM.add_reg(ADDR, TMP, ACC))    # mask base + index
            @emitter.emit(ASM.ldrb_offset(ACC, ADDR, 0))  # the solid/transparent byte
          end

          def increment(var)
            @primitives.load_var(ACC, var)
            @emitter.emit(ASM.add_imm(ACC, ACC, 1))
            @primitives.store_var(ACC, var)
          end
        end
      end
    end
  end
end
