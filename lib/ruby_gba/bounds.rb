# frozen_string_literal: true

module RubyGBA
  # The rectangle-bounds contract for collision. Anything that knows its top-left
  # corner (`x`, `y`) and its far edges (`right`, `bottom`) can be tested for
  # overlap — mix this in and it gains `overlaps?`. A {Box} answers those four from
  # a corner and a size; a {Sprite} answers them from its position and image size,
  # so `hero.overlaps?(coin)` works with no boxes at all. Anything else you write
  # that exposes the same four joins in for free.
  module Bounds
    # Whether this rectangle overlaps +other+ — the collision test games run every
    # frame. Two rectangles touch when, on each axis, neither one starts past where
    # the other ends. Returns a {Condition}, so branch on it like any comparison:
    #
    #   hero.overlaps?(coin).then { score.add 1 }
    #
    # Touching edges count as a hit (the test is inclusive). +other+ is anything with
    # x / y / right / bottom — another box, a sprite, a handle of your own.
    def overlaps?(other)
      (x <= other.right) & (other.x <= right) & (y <= other.bottom) & (other.y <= bottom)
    end
  end
end
