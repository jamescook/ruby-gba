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
    end
  end
end
