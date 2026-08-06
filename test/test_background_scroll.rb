# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Scrolling a tiled background (`background(...).scroll_to` / `scroll_by`): the
# visible window slides over a map bigger than the screen, and wraps at the map's
# edge. Asserted by tracking landmark tiles as the view moves — on the interpreter
# oracle and on real hardware. The dev never touches a scroll register.
class TestBackgroundScroll < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Builder = RubyGBA::Builder
  Reference = RubyGBA::IR::Backends::Reference
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  SOLID8 = (["########"] * 8).join("\n")

  # A 32x32-tile world (256x256, bigger than the 240x160 screen and wrapping at 256).
  # It's blue, with a RED landmark tile at cell (10, 10) — map pixels (80, 80) — and a
  # GREEN one at cell (0, 0), so a wrap brings green in from the map's left edge.
  def world_scrolled_to(sx, sy)
    map = Array.new(32) do |r|
      (0...32).map { |c| r == 10 && c == 10 ? "R" : (r.zero? && c.zero? ? "G" : "B") }.join
    end
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:red_t,   "#" => :red)   { SOLID8 }
      image(:green_t, "#" => :green) { SOLID8 }
      image(:blue_t,  "#" => :blue)  { SOLID8 }
      tiles :terrain, "R" => :red_t, "G" => :green_t, "B" => :blue_t
      world = background :world, tiles: :terrain, map: map
      world.scroll_to sx, sy
      game_loop do
        wait_vblank
        halt
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_scrolling_moves_the_view
    still = Reference.new.run(world_scrolled_to(0, 0)).screen
    assert_equal Color.resolve(:red), still.pixel(84, 84), "at rest the landmark sits at map pixel (80,80)"

    # Scroll the window 40px right: the landmark slides 40px left, to screen x 44.
    moved = Reference.new.run(world_scrolled_to(40, 0)).screen
    assert_equal Color.resolve(:red),  moved.pixel(44, 84), "scrolling right slides the landmark left"
    assert_equal Color.resolve(:blue), moved.pixel(84, 84), "and its old spot now shows the next tile"
  end

  def test_scrolling_wraps_at_the_map_edge
    # Window at x=250 on a 256-wide map: screen x 0..5 show map 250..255 (blue), and at
    # screen x=6 the map wraps back to x=0 — the green corner tile.
    wrapped = Reference.new.run(world_scrolled_to(250, 0)).screen
    assert_equal Color.resolve(:blue),  wrapped.pixel(2, 4), "before the wrap it's the map's right edge (blue)"
    assert_equal Color.resolve(:green), wrapped.pixel(8, 4), "past the wrap the map repeats from its left (green)"
  end

  def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "SCROLL", code: "BSCR", maker: "01")
  end

  def test_scrolling_on_the_console
    still = assert_gemba_loads_rom(rom_for(world_scrolled_to(0, 0)), frames: 3)
    assert still.red?(84, 84), "at rest the landmark is at (80,80), got 0x#{format('%04X', still.pixel_gba(84, 84))}"

    moved = assert_gemba_loads_rom(rom_for(world_scrolled_to(40, 0)), frames: 3)
    assert moved.red?(44, 84), "scrolled right, the landmark slid left, got 0x#{format('%04X', moved.pixel_gba(44, 84))}"
  end

  # --- scrolling and sprites together: the sprite floats over the moving scene ---

  # A blue world with a RED landmark tile at cell (10,10) -> map px (80,80), a GREEN
  # hero sprite parked at screen (100,60), and the view scrolling right 2px/frame,
  # halting after 20 frames so it settles at offset 40 (the landmark has slid left to
  # screen x=40, while the hero stays put on top).
  def scroll_with_hero
    map = Array.new(32) { |r| (0...32).map { |c| r == 10 && c == 10 ? "R" : "B" }.join }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:red_t,  "#" => :red)   { SOLID8 }
      image(:blue_t, "#" => :blue)  { SOLID8 }
      image(:hero,   "#" => :green) { SOLID8 }
      tiles :terrain, "R" => :red_t, "B" => :blue_t
      world = background :world, tiles: :terrain, map: map
      sprite :hero, at: [100, 60]
      game_loop do
        wait_vblank
        world.scroll_by 2, 0
        after(20) { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_sprite_stays_over_a_scrolling_background
    s = Reference.new.run(scroll_with_hero).screen
    assert_equal Color.resolve(:green), s.pixel(104, 64),
                 "the hero stays drawn on top as the world scrolls under it"
    assert_equal Color.resolve(:red), s.pixel(44, 84),
                 "and the background really scrolled (the landmark slid left to screen x=40)"
  end

  def test_scrolling_with_a_sprite_on_the_console
    v = assert_gemba_loads_rom(rom_for(scroll_with_hero), frames: 25)
    assert v.green?(104, 64),
           "the hero renders over the scrolling world on hardware, got 0x#{format('%04X', v.pixel_gba(104, 64))}"
    assert v.red?(44, 84),
           "the world scrolled under it on hardware, got 0x#{format('%04X', v.pixel_gba(44, 84))}"
  end
end
