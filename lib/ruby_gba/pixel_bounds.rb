# frozen_string_literal: true

module RubyGBA
  # Makes a sprite's `overlaps?` shape-accurate. On top of the plain box test from
  # {Bounds}, when BOTH things being compared are sprites collided per-pixel (the
  # default — neither was pinned to a plain `hitbox:`), it adds a second test: do their
  # drawn pixels actually meet? The box test is the cheap gate — sprites nowhere near
  # each other fail it and never reach the per-pixel walk — so the accuracy costs
  # nothing for the far-apart pairs that make up most of a frame.
  #
  # Anything without solid pixels to test — a {Box}, or a sprite that opted out to a
  # plain rectangle with `hitbox:` — skips the per-pixel half and collides on its box,
  # exactly as before. A sprite mixes cleanly with a box that way.
  module PixelBounds
    Build = IR::Build

    def overlaps?(other)
      box = super # the axis-aligned box overlap from Bounds
      return box unless per_pixel_against?(other)

      box & Condition.new(collision_builder, Build.pixels_overlap(
        a_poses: collision_poses, a_pose: collision_pose, a_x: x.node, a_y: y.node,
        b_poses: other.collision_poses, b_pose: other.collision_pose, b_x: other.x.node, b_y: other.y.node
      ))
    end

    private

    # Both sides must be sprites still colliding per-pixel (not opted out to a box) for
    # the shape-accurate test to apply.
    def per_pixel_against?(other)
      pixel_perfect? && other.respond_to?(:pixel_perfect?) && other.pixel_perfect?
    end
  end
end
