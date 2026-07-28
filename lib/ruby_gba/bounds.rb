# frozen_string_literal: true

module RubyGBA
  # The rectangle-bounds contract for collision. Anything that knows its four edges
  # (`left`, `top`, `right`, `bottom`) can be tested for overlap — mix this in and it
  # gains `overlaps?`. A {Box} answers those four from a corner and a size; a {Sprite}
  # answers them from its position and its collision box (by default the rectangle
  # around its visible pixels, trimming the transparent margin around the art — see the
  # sprite verb's `hitbox:`), so `hero.overlaps?(coin)` works with no boxes at all. It
  # stays a rectangle test, not a per-pixel or per-shape one. Anything else you write
  # that exposes the same four joins in for free.
  module Bounds
    # Whether this rectangle overlaps +other+ — the collision test games run every
    # frame. Two rectangles touch when, on each axis, neither one starts past where
    # the other ends. Returns a {Condition}, so branch on it like any comparison:
    #
    #   hero.overlaps?(coin).then { score.add 1 }
    #
    # Touching edges count as a hit (the test is inclusive). +other+ is anything with
    # left / top / right / bottom — another box, a sprite, a handle of your own.
    def overlaps?(other)
      (left <= other.right) & (other.left <= right) & (top <= other.bottom) & (other.top <= bottom)
    end
  end
end
