# frozen_string_literal: true

require "test_helper"

# The art these tests collide, shared with the Advance cartridge's own test of the same box
# (test/lowering/gba/vblank/dsl/test_hitbox_cartridge.rb).
module HitboxGames
  # An 8x8 dot with a 4x4 visible block in the middle (columns/rows 2..5) and a 2px
  # transparent border. So its visible box is [2, 2, 4, 4]; its full image is [0,0,8,8].
  DOT_ART = <<~ART
    ........
    ........
    ..####..
    ..####..
    ..####..
    ..####..
    ........
    ........
  ART
end

# Sprite collision hugs the visible art. A sprite's `overlaps?` box is, by default, the
# rectangle around its non-transparent pixels — not the whole image — so it collides on
# the drawn art, not a transparent pixel or two of margin early (the pacman "the ghost
# catches you off the yellow" surprise). It's still an axis-aligned rectangle, not a
# per-pixel or per-shape test. `hitbox:` overrides it: :full for the old whole-image box,
# a number to shrink the image on every side, or an explicit rectangle. Collision is pure
# DSL codegen, so every run plays the same test — with one hardware check, on the Advance's
# cartridge, in test/lowering/gba/vblank/dsl/test_hitbox_cartridge.rb.
class TestHitbox < Minitest::Test
  include VBlank::Console::Hardware
  include HitboxGames

  # Two dots at ax and bx (same y), asked whether they overlap; returns the :hit flag
  # (1 if they collided). Both get the same +hitbox+ so the box rule under test is what
  # decides it.
  private def collided?(ax, bx, hitbox: nil)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      image(:dot, "." => :transparent, "#" => :white) { DOT_ART }
      var :hit, 0
      a  = sprite :dot, at: [ax, 20], hitbox: hitbox
      bb = sprite :dot, at: [bx, 20], hitbox: hitbox
      game_loop do
        wait_vblank
        a.overlaps?(bb).then { set! :hit, 1 }
        halt
      end
    end
    b.finalize_program
    game_player.run(b.program, frames: 3)[:hit] == 1
  end

  # Full 8x8 boxes at x100 (100..107) and x105 (105..112) overlap, but the 4x4 visible
  # blocks (102..105 and 107..110) don't — a 1px gap. The default box collides on the
  # art, so this is NOT a hit.
  def test_transparent_margins_touching_is_not_a_hit_by_default
    refute collided?(100, 105), "the see-through borders overlap but the drawn blocks don't — no hit"
  end

  # Move them one closer (x100 and x103): now the visible blocks (102..105 and 105..108)
  # meet at x105, so they really do collide.
  def test_visible_pixels_meeting_is_a_hit
    assert collided?(100, 103), "the drawn blocks touch, so it's a hit"
  end

  # :full brings back whole-image collision — the see-through borders count again, so
  # the same x100/x105 pair that missed by default now hits.
  def test_hitbox_full_uses_the_whole_image
    assert collided?(100, 105, hitbox: :full), "with hitbox: :full the full boxes touching is a hit"
    refute collided?(100, 105), "...whereas the default (visible) box does not"
  end

  # An explicit whole-image rectangle behaves like :full.
  def test_hitbox_explicit_rectangle
    assert collided?(100, 105, hitbox: [0, 0, 8, 8]), "an explicit full rectangle collides like :full"
  end

  # Shrinking the box makes collision stricter: a pair that hits on the default visible
  # box (x100/x103) misses once each side is pulled in to a 2x2 centre (inset 3).
  def test_hitbox_inset_shrinks_the_box
    assert collided?(100, 103), "sanity: they hit on the default box"
    refute collided?(100, 103, hitbox: 3), "inset to a 2x2 centre, the same pair no longer touches"
  end

  # --- friendly errors for a bad hitbox ---

  def test_a_too_big_inset_is_a_friendly_error
    err = assert_raises(ArgumentError) { collided?(100, 103, hitbox: 4) } # 8x8 shrunk by 4 each side = nothing
    assert_match(/to nothing/, err.message)
  end

  def test_a_malformed_rectangle_is_a_friendly_error
    err = assert_raises(ArgumentError) { collided?(100, 103, hitbox: [1, 2, 3]) }
    assert_match(/\[x, y, w, h\]/, err.message)
  end

  def test_a_nonsense_hitbox_is_a_friendly_error
    err = assert_raises(ArgumentError) { collided?(100, 103, hitbox: :small) }
    assert_match(/:full, a number/, err.message)
  end

  # A posed/animated sprite holds one collision box across its frames: the union of
  # every pose's visible pixels, so the box doesn't jitter as the picture changes.
  def test_a_posed_sprites_box_is_the_union_of_its_poses
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      image(:wide, "." => :transparent, "#" => :white) { "########\n########" } # visible full width
      image(:narrow, "." => :transparent, "#" => :white) { "...##...\n...##..." } # visible only middle
      var :hit, 0
      a = sprite :poser, at: [100, 20], facing: { left: :narrow, right: :wide }
      bar = box 108, 20, 1, 2 # just past the wide pose's right edge (100+8 = 108)
      game_loop do
        wait_vblank
        a.overlaps?(bar).then { set! :hit, 1 }
        halt
      end
    end
    b.finalize_program
    # The union includes the wide pose (full 8 wide), so the box reaches x108 and touches
    # the bar even though the sprite currently shows the narrow pose.
    assert_equal 1, game_player.run(b.program, frames: 3)[:hit],
                 "the collision box covers the widest pose, not just the one on screen"
  end
end
