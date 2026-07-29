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

    # --- where am I relative to the screen ---
    #
    # Common "has it left the screen" tests, read from this rectangle's own edges and
    # the screen size — so game code needs no coordinate literals or sprite-size math.
    # Each returns a {Condition}, so branch on it like any comparison:
    #
    #   shot.above_top?.then   { shot.hide }          # a bullet flew off the top
    #   enemy.below_bottom?.then { enemy.respawn }    # an enemy fell off the bottom
    #
    # "Off an edge" means FULLY past it — nothing of the rectangle still shows there —
    # so a thing sliding half off a side isn't off_screen? yet. The screen is the
    # 240x160 display (see {IR::Screen}); a rectangle's right/bottom read one past its
    # last pixel (see {Box}), so the edge tests below are written to match.

    # Fully past the left edge: the right side has crossed x = 0.
    def off_left?
      right <= 0
    end

    # Fully past the right edge: the left side has reached the screen's width.
    def off_right?
      left >= IR::Screen::WIDTH
    end

    # Fully past the top edge: the bottom has crossed y = 0.
    def above_top?
      bottom <= 0
    end

    # Fully past the bottom edge: the top has reached the screen's height.
    def below_bottom?
      top >= IR::Screen::HEIGHT
    end

    # Fully off the screen past ANY edge — nothing of it shows.
    def off_screen?
      off_left? | off_right? | above_top? | below_bottom?
    end
  end
end
