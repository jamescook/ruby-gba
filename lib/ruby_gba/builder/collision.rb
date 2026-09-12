# frozen_string_literal: true

module RubyGBA
  class Builder
    # Make rectangles to collision-test. The overlap test itself lives on the shape
    # (`box_a.overlaps?(box_b)`, from {Bounds}), so a sprite — which knows its own
    # bounds — needs no box at all; `box` is the manual escape hatch for a thing that
    # isn't a sprite. A concern of {Builder}, mixed in flat.
    module Collision
      # Make a rectangle from a top-left corner and a size, for collision tests. Each
      # of x, y, w, h can be a fixed number, a :variable, or an expression, so a box
      # can track a moving thing (a ball at its live x/y) or pin a fixed one (a wall).
      # It draws nothing — it's a shape to test — so build one wherever it reads best
      # and reuse it. Test two with `overlaps?`:
      #
      #   ball   = box(ball_x, ball_y, 4, 4)   # follows the ball's variables
      #   paddle = box(8, paddle_y, 4, 24)
      #   ball.overlaps?(paddle).then { ball_dx.abs }   # bounce on contact
      #
      # A sprite already knows its bounds, so `hero.overlaps?(coin)` needs no box.
      def box(x, y, w, h)
        Box.new(self, x, y, w, h)
      end

      # TILE COLLISION: the routine that asks a background's grid whether a box is clear of
      # its solid tiles, built once for each background-and-box-size that needs one. An
      # internal hook a {HardwareSprite} calls when it is `blocked_by` a background — never
      # written by an author, who says `blocked_by` and nothing else.
      #
      # This is tile collision and nothing else. Two things collide in this framework and
      # they share no machinery: a mover against the scenery's solid tiles, which is this,
      # and one thing against another (`overlaps?`, a {Box}, a sprite's own pixels), which
      # is {Bounds}. They used to meet here — the scenery's solid cells were turned into
      # Boxes so the general overlap test could be pointed at them — and that is what made
      # this cost what the room was made of.
      #
      # It is a routine rather than code at each place that moves, and that is the whole
      # point of it. A mover moves on two axes, so eight movers wrote this out sixteen
      # times; emitted once, eight movers cost eight calls.
      #
      # WHICH CELLS IT LOOKS AT. A box covers a bounded number of cells whatever the room
      # is made of — a 16x16 box on 8x8 tiles touches at most three columns and three rows
      # — so the samples are its own edges plus every tile boundary in between, worked out
      # here while the program is built. That is why the cost does not grow with the room:
      # a bordered room and a maze of pillars are the same nine reads.
      #
      # Returns the names the caller needs: where to put the position it is asking about,
      # what to call, and where the answer lands.
      def tile_collision_routine(cells, hit_x, hit_y, hit_w, hit_h)
        @tile_collisions ||= {}
        key = [cells.name, hit_x, hit_y, hit_w, hit_h]
        @tile_collisions[key] ||=
          build_tile_collision(cells, hit_x, hit_y, hit_w, hit_h, @tile_collisions.size)
      end

      private

      # The shared scratch a tile-collision check reads its question from and writes its
      # answer to. One set for the whole program: a check runs to its end before anything
      # else asks, so nothing can be part-way through another question.
      TILE_COLLISION_X = :__tile_collision_x
      TILE_COLLISION_Y = :__tile_collision_y
      TILE_COLLISION_CLEAR = :__tile_collision_clear

      def build_tile_collision(cells, hit_x, hit_y, hit_w, hit_h, index)
        name = :"__tile_collision_#{index}"
        [TILE_COLLISION_X, TILE_COLLISION_Y, TILE_COLLISION_CLEAR].each { |v| ensure_var(v) }

        across = tile_collision_offsets(hit_w, cells.tile_w)
        down = tile_collision_offsets(hit_h, cells.tile_h)
        width = cells.cols * cells.tile_w
        height = cells.rows * cells.tile_h

        func(name) do
          clear = Value.new(self, IR::Build.var_ref(TILE_COLLISION_CLEAR), name: TILE_COLLISION_CLEAR)
          left = Value.new(self, IR::Build.var_ref(TILE_COLLISION_X), name: TILE_COLLISION_X) + hit_x
          top = Value.new(self, IR::Build.var_ref(TILE_COLLISION_Y), name: TILE_COLLISION_Y) + hit_y
          # WHICH ROOM'S WALLS, worked out once for the whole check rather than once per
          # cell: every sample a mover takes is in the map it is standing in, so the offset
          # to that map's grid is the same for all nine. That is what keeps a background
          # with two hundred rooms the same nine reads as a background with one.
          base = map_base_for(cells)
          clear.set 1
          down.each do |dy|
            py = top + dy
            across.each do |dx|
              px = left + dx
              # Outside the map is not solid, so a mover may walk off the edge exactly as it
              # could when the scenery's solid cells were rectangles. Held on the PIXEL
              # rather than the cell, because dividing truncates toward zero and would fold
              # a pixel just left of the map onto column 0.
              inside = (px >= 0) & (px < width) & (py >= 0) & (py < height)
              cell = ((py / cells.tile_h) * cells.cols) + (px / cells.tile_w)
              solid = cells.table[base ? base + cell : cell]
              (inside & (solid == 1)).then { clear.set 0 }
            end
          end
        end

        { name: name, x: TILE_COLLISION_X, y: TILE_COLLISION_Y, clear: TILE_COLLISION_CLEAR }
      end

      # Where the showing map's walls start in the table, as a {Value} — nil for a
      # background with one map, whose grid starts at 0 and needs no arithmetic at all.
      # Nothing holds the number to the range here because nothing has to: the variable is
      # written by the frame-boundary copy, which only ever puts a real map there, and a
      # table read makes an out-of-range index safe on its own.
      def map_base_for(cells)
        return nil if cells.map_var.nil?

        Value.new(self, IR::Build.var_ref(cells.map_var), name: cells.map_var) * cells.cells_per_map
      end

      # Where along a box to ask, for a box +size+ pixels across on +tile+-pixel cells:
      # its leading edge, every tile boundary it spans, and its far edge. Two samples for
      # a box exactly one tile across, because it can still straddle two cells.
      def tile_collision_offsets(size, tile)
        offsets = (0...size).step(tile).to_a
        offsets << size - 1 unless offsets.last == size - 1
        offsets
      end
    end
  end
end
