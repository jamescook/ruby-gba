# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# a.overlaps?(b): a rectangle-collision test built from the expression DSL. It
# returns a Condition you branch on with `.then`, so a game bounces a ball, picks up
# an item, or takes damage in one readable line. It works on anything with bounds —
# an explicit `box`, or a sprite that knows its own size. These assert the observable
# result — a marker drawn only when the shapes actually touch — on the interpreter
# and on real hardware.
class TestOverlaps < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Condition = RubyGBA::Condition
  Color = RubyGBA::Color

  # Draw a white marker at (0, 0) iff box A overlaps box B, and report the marker
  # pixel from the interpreter. Coordinates are plain integers here so the test
  # pins the geometry, not the machinery.
  def marker_when(a_dims, b_dims)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      box(*a_dims).overlaps?(box(*b_dims)).then { pixel 0, 0, :white }
    end
    b.emit_pending_functions
    Ruby.new.run(b.program).screen.pixel(0, 0)
  end

  A = [10, 10, 8, 8].freeze # spans x 10..18, y 10..18

  def test_overlapping_rectangles_fire
    assert_equal Color.resolve(:white), marker_when(A, [14, 14, 8, 8]), "clearly overlapping"
  end

  def test_touching_edges_count_as_a_hit
    # B's left edge (18) meets A's right edge (10+8=18): inclusive, so it's a hit.
    assert_equal Color.resolve(:white), marker_when(A, [18, 10, 8, 8]), "edge-touching is inclusive"
  end

  def test_separated_rectangles_do_not_fire
    assert_equal 0, marker_when(A, [30, 30, 8, 8]), "far apart: no marker"
  end

  def test_a_one_pixel_gap_does_not_fire
    # B's left edge (19) is one past A's right edge (18): no overlap.
    assert_equal 0, marker_when(A, [19, 10, 8, 8]), "a 1px gap is a miss"
  end

  def test_overlaps_returns_a_condition
    b = Builder.new
    a = b.box(0, 0, 4, 4)
    c = b.box(2, 2, 4, 4)
    assert_kind_of Condition, a.overlaps?(c), "overlaps? is a Condition, usable in .then / & / |"
  end

  # A box can be pinned to a variable, so it tracks a moving thing. Slide a ball
  # rightward through a fixed wall and count the frames the two overlap.
  def test_a_box_follows_a_moving_variable
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      ball_x = var :ball_x, 0
      hits   = var :hits, 0
      wall   = box(20, 0, 4, 8) # spans x 20..24
      game_loop do
        ball_x.add 1
        box(ball_x, 0, 4, 8).overlaps?(wall).then { hits.add 1 }
        (ball_x >= 40).then { halt }
      end
    end
    b.emit_pending_functions
    # The loop is frame-paced (one pass per frame), so give it enough frames for the
    # ball to travel all the way through the wall and reach its halt at x 40.
    i = Ruby.new.run(b.program, frames: 50)
    # The 4-wide ball overlaps the wall (x 20..24) while its left edge is in 16..24,
    # i.e. ball_x from 16 through 24 — nine frames.
    assert_equal 9, i[:hits], "overlaps? fires exactly on the overlapping frames"
  end

  # The headline: a sprite knows its own bounds (position + image size), so two
  # sprites collide with no box at all — `hero.overlaps?(item)`. Draw a green marker
  # when they touch, and report it, for a pair placed overlapping vs far apart.
  def sprites_touch?(hero_at, item_at)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image(:hero, "#" => :white) { "####\n####\n####\n####" } # 4x4
      image(:item, "#" => :cyan)  { "####\n####\n####\n####" } # 4x4
      clear_screen :black
      hero  = sprite :hero, at: hero_at
      item  = sprite :item, at: item_at
      frame = var :frame, 0
      game_loop do
        wait_vblank
        hero.overlaps?(item).then { pixel 0, 0, :green }
        frame.add 1
        (frame >= 2).then { halt }
      end
    end
    b.emit_pending_functions
    Ruby.new.run(b.program).screen.pixel(0, 0)
  end

  def test_two_sprites_collide_by_their_own_bounds
    assert_equal Color.resolve(:green), sprites_touch?([10, 10], [12, 12]), "overlapping sprites collide"
    assert_equal 0, sprites_touch?([10, 10], [40, 40]), "far-apart sprites do not"
  end

  # The same test, run on the console: a green marker is painted only while the two
  # boxes overlap. Two static cases — one overlapping, one apart — prove the verb
  # lowers to hardware, not just the interpreter.
  def rom_for(a_dims, b_dims)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      box(*a_dims).overlaps?(box(*b_dims)).then { fill_rect 100, 80, 4, 4, :green }
      halt
    end
    b.emit_pending_functions
    ROM.assemble(GBA.new.lower(b.program), title: "OVERLAP", code: "BOVL", maker: "01")
  end

  def test_overlap_lowers_to_hardware
    v = assert_gemba_loads_rom(rom_for(A, [14, 14, 8, 8]), frames: 2)
    assert v.green?(101, 81), "overlapping boxes light the marker on hardware"
  end

  def test_no_overlap_draws_nothing_on_hardware
    v = assert_gemba_loads_rom(rom_for(A, [40, 40, 8, 8]), frames: 2)
    assert v.black?(101, 81), "separated boxes leave the screen clear on hardware"
  end

  # Regression for the overlapping-sprite smear (what left Pac-Man's screen littered
  # with pellet fragments). A hero walks onto a coin and, while it's covering it, the
  # coin vanishes. If the per-frame repaint erased-and-drew each sprite in turn, the
  # hero — drawn first — would capture the still-present coin under itself, then paint
  # that captured copy back when it moved off, leaving a fragment where the coin no
  # longer is. Erasing EVERY sprite before drawing any means the hero captures clean
  # background, so nothing is smeared. The coin is hidden, so any coin-colour pixel
  # left on screen is a fragment.
  def test_a_sprite_passing_over_a_vanishing_one_leaves_no_fragment
    magenta = Color.resolve(:magenta)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image(:hero, "#" => :red)     { "####\n####\n####\n####" }
      image(:coin, "#" => :magenta) { "####\n####\n####\n####" }
      clear_screen :black
      hero  = sprite :hero, at: [8, 20]  # drawn first — it's the one that captures
      coin  = sprite :coin, at: [20, 20]
      frame = var :frame, 0
      game_loop do
        wait_vblank
        hero.x.add 2
        (frame == 6).then { coin.hide } # vanish while the hero is on top of it
        frame.add 1
        (frame >= 24).then { halt }
      end
    end
    b.emit_pending_functions
    screen = Ruby.new.run(b.program).screen

    fragments = (0...RubyGBA::IR::Screen::HEIGHT).sum do |y|
      (0...RubyGBA::IR::Screen::WIDTH).count { |x| screen.pixel(x, y) == magenta }
    end
    assert_equal 0, fragments, "the hidden coin should leave no fragment where the hero passed over it"
  end
end
