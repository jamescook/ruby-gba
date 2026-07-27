# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Stacked tiled backgrounds (declaring more than one `background`): they compose in
# declaration order — the first is the backmost, each later one in front — and a
# front layer's empty/backdrop pixels are see-through, so the layer behind shows
# there. Scrolled at different speeds, near-and-far layers give parallax. Asserted on
# the interpreter oracle and on real hardware; the dev only writes two `background`s.
class TestBackgroundLayers < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  SOLID8 = (["########"] * 8).join("\n")

  # A FAR layer (backmost): a blue field with a GREEN landmark tile at cell (5,5) ->
  # px (40,40). A NEAR layer (front): transparent everywhere (spaces) except a RED
  # landmark tile at cell (10,5) -> px (80,40). Where near is transparent, far shows.
  # Each layer is scrolled to its own offset, so they can move at different speeds.
  def two_layers(far_x, near_x)
    far_map  = Array.new(32) { |r| (0...32).map { |c| r == 5 && c == 5  ? "G" : "B" }.join }
    near_map = Array.new(32) { |r| (0...32).map { |c| r == 5 && c == 10 ? "R" : " " }.join }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:blue_t,  "#" => :blue)  { SOLID8 }
      image(:green_t, "#" => :green) { SOLID8 }
      image(:red_t,   "#" => :red)   { SOLID8 }
      tiles :far_set,  "B" => :blue_t, "G" => :green_t
      tiles :near_set, "R" => :red_t
      far  = background :far,  tiles: :far_set,  map: far_map   # declared first -> backmost
      near = background :near, tiles: :near_set, map: near_map  # declared second -> in front
      far.scroll_to far_x, 0
      near.scroll_to near_x, 0
      game_loop do
        wait_vblank
        halt
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "LAYERS", code: "BLYR", maker: "01")
  end

  # At rest the two landmarks sit apart (green at x44, red at x84), and where the near
  # layer is empty its blue backdrop layer shows through.
  def test_layers_compose_with_the_front_transparent_where_empty
    s = Ruby.new.run(two_layers(0, 0)).screen
    assert_equal Color.resolve(:green), s.pixel(44, 44), "the far layer's green landmark shows through the empty near layer"
    assert_equal Color.resolve(:red),   s.pixel(84, 44), "the near layer's red landmark sits in front"
    assert_equal Color.resolve(:blue),  s.pixel(100, 100), "elsewhere the near layer is see-through, so the far layer shows"
  end

  # Scroll far by 20 and near by 40 (near twice as fast): the green landmark slides to
  # x24 while the red slides to x44 — they were 40px apart, now 20px apart. That change
  # in relative spacing *is* parallax (the near layer moved more than the far one).
  def test_layers_scroll_at_independent_speeds_parallax
    s = Ruby.new.run(two_layers(20, 40)).screen
    assert_equal Color.resolve(:green), s.pixel(24, 44), "the far layer slid 20px (its landmark to x24)"
    assert_equal Color.resolve(:red),   s.pixel(44, 44), "the near layer slid 40px (its landmark to x44) — twice as far"
  end

  # --- Hardware (gemba): the layers really composite and parallax-scroll ---

  def test_layers_compose_on_the_console
    v = assert_gemba_loads_rom(rom_for(two_layers(0, 0)), frames: 3)
    assert v.green?(44, 44), "far green shows through the empty near layer, got 0x#{format('%04X', v.pixel_gba(44, 44))}"
    assert v.red?(84, 44),   "near red sits in front, got 0x#{format('%04X', v.pixel_gba(84, 44))}"
    assert v.blue?(100, 100), "the near layer is see-through elsewhere, got 0x#{format('%04X', v.pixel_gba(100, 100))}"
  end

  def test_layers_parallax_on_the_console
    v = assert_gemba_loads_rom(rom_for(two_layers(20, 40)), frames: 3)
    assert v.green?(24, 44), "far slid 20px, got 0x#{format('%04X', v.pixel_gba(24, 44))}"
    assert v.red?(44, 44),   "near slid 40px — twice as far (parallax), got 0x#{format('%04X', v.pixel_gba(44, 44))}"
  end
end
