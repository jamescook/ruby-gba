# frozen_string_literal: true

require "test_helper"

# Sprite collision is per-pixel by default: `hero.overlaps?(coin)` is true only when
# their DRAWN pixels actually meet, whatever their shape and whichever animation frame
# is showing. A cheap box test gates it, and `hitbox:` opts out to a plain rectangle.
# These assert the observable difference through the DSL surface — the case a plain
# bounding box gets wrong. The same case on the Advance's cartridge, read in the emulator, is in
# test/lowering/gba/vblank/dsl/test_pixel_perfect_collision_cartridge.rb, which draws the shape
# kept here in PixelPerfectCollisionGames.
module PixelPerfectCollisionGames
  # An 8x8 shape drawn only in two opposite corners (top-left and bottom-right 2x2
  # blocks); the middle is see-through. Its bounding box is the whole 8x8, but almost
  # none of that box is solid — so two of them can have overlapping BOXES while none of
  # their drawn pixels meet. That's exactly what a box test gets wrong.
  CORNERS = <<~ART
    ##......
    ##......
    ........
    ........
    ........
    ........
    ......##
    ......##
  ART
end

class TestPixelPerfectCollision < Minitest::Test
  include PixelPerfectCollisionGames

  # Do two corner-shapes at these spots register a hit? Returns the :hit flag.
  private def collided?(a_at, b_at, hitbox: nil)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      image(:corners, "." => :transparent, "#" => :white) { CORNERS }
      var :hit, 0
      a  = sprite :corners, at: a_at, hitbox: hitbox
      bb = sprite :corners, at: b_at, hitbox: hitbox
      game_loop do
        wait_vblank
        a.overlaps?(bb).then { set! :hit, 1 }
        halt
      end
    end
    b.finalize_program
    game_player.run(b.program, max_steps: 2_000)[:hit] == 1
  end

  # Boxes overlap (A 100..107, B 103..110), but A's only pixels in that overlap are its
  # bottom-right block and B's are its top-left block — different spots. So: no hit.
  def test_overlapping_boxes_with_no_shared_pixels_do_not_collide
    refute collided?([100, 20], [103, 23]), "the boxes overlap, but the drawn pixels never meet"
  end

  # The same pair, opted out to whole-image boxes, DOES collide — proving the default
  # really was looking at the pixels, not the box.
  def test_hitbox_full_falls_back_to_the_box
    assert collided?([100, 20], [103, 23], hitbox: :full),
           "with hitbox: :full it's a plain box test again, so the overlapping boxes hit"
  end

  # When the shapes line up so their corner blocks actually coincide, it's a real hit.
  def test_pixels_that_coincide_do_collide
    assert collided?([100, 20], [100, 20]), "identical positions: the corner blocks land on each other"
  end

  # A Box has no pixels, so a sprite-vs-box test stays a plain box overlap — the sprite's
  # whole footprint counts, even the see-through middle.
  def test_sprite_versus_box_is_a_plain_box_test
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      image(:corners, "." => :transparent, "#" => :white) { CORNERS }
      var :hit, 0
      a = sprite :corners, at: [100, 20]
      middle = box 103, 23, 2, 2 # sits in the sprite's transparent middle
      game_loop do
        wait_vblank
        a.overlaps?(middle).then { set! :hit, 1 }
        halt
      end
    end
    b.finalize_program
    assert_equal 1, game_player.run(b.program, max_steps: 2_000)[:hit],
                 "a box collides on the sprite's whole rectangle, transparent middle included"
  end

  # Animation-aware: the mask tested is the frame currently shown. A sprite facing a
  # wide pose reaches a bar its narrow pose can't.
  def test_collision_follows_the_current_animation_frame
    hit_when = lambda do |dir|
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        clear_screen :black
        image(:wide,   "." => :transparent, "#" => :white) { "########\n########" } # solid to x7
        image(:narrow, "." => :transparent, "#" => :white) { "##......\n##......" } # solid only to x1
        image(:pin,    "#" => :white) { "##\n##" }                                  # a small solid sprite
        var :hit, 0
        a = sprite :poser, at: [100, 20], facing: { right: :wide, left: :narrow }
        pin = sprite :pin, at: [106, 20] # only the wide pose's pixels (x100..107) reach it
        game_loop do
          wait_vblank
          a.face(dir)
          a.overlaps?(pin).then { set! :hit, 1 }
          halt
        end
      end
      b.finalize_program
      game_player.run(b.program, max_steps: 2_000)[:hit]
    end
    assert_equal 1, hit_when.call(:right), "facing wide, the sprite reaches the bar"
    assert_equal 0, hit_when.call(:left),  "facing narrow, the same sprite doesn't"
  end
end
