# frozen_string_literal: true

require "test_helper"

# Stacked tiled backgrounds (declaring more than one `background`): they compose in
# declaration order — the first is the backmost, each later one in front — and a
# front layer's empty/backdrop pixels are see-through, so the layer behind shows
# there. Scrolled at different speeds, near-and-far layers give parallax. Asserted on
# the interpreter oracle and on real hardware; the dev only writes two `background`s.
class TestBackgroundLayers < Minitest::Test
  include RubyGBA::Console::Hardware

  # A FAR layer (backmost): a blue field with a GREEN landmark tile at cell (5,5) ->
  # px (40,40). A NEAR layer (front): transparent everywhere (spaces) except a RED
  # landmark tile at cell (10,5) -> px (80,40). Where near is transparent, far shows.
  # Each layer is scrolled to its own offset, so they can move at different speeds.
  private def two_layers(far_x, near_x)
    far_map  = Array.new(32) { |r| (0...32).map { |c| r == 5 && c == 5  ? "G" : "B" }.join }
    near_map = Array.new(32) { |r| (0...32).map { |c| r == 5 && c == 10 ? "R" : " " }.join }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:blue_t,  "#" => :blue)  { SOLID_TILE }
      image(:green_t, "#" => :green) { SOLID_TILE }
      image(:red_t,   "#" => :red)   { SOLID_TILE }
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
    builder.finalize_program
    builder.program
  end

  private def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "LAYERS", code: "BLYR", maker: "01")
  end

  # A front layer drawn in pure black over a red one. Black is a colour like any other: it
  # is see-through only where the picture says see-through, never because its number is 0.
  RED = Color.rgb(31, 0, 0)

  private def black_over_red(&front)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :red, width: 8, height: 8, colors: [:transparent, RED], places: [1] * 64
      tiles :reds, "#" => :red
      background :behind, tiles: :reds, map: Array.new(20) { "#" * 30 }
      instance_eval(&front)
      game_loop {}
    end
    builder.finalize_program
    builder.program
  end

  # Tiles the game paints hold place numbers too: every pixel here is place 2, black.
  private def black_painted
    black_over_red do
      colors :inks, [:transparent, RED, 0x0000]
      bytes = list :bytes, capacity: 32, width: :byte
      box = tiles :box, from: bytes, count: 1, colors: :inks
      background :front, tiles: :box, map: [[1]]
      repeat(32) { bytes.push 0x22 }
      box.changed
    end
  end

  def test_black_painted_at_a_place_covers
    assert_equal 0x0000, game_player.run(black_painted, frames: 3).screen.pixel(2, 2)
    assert_equal 0x0000, assert_emulator_loads_rom(rom_for(black_painted), frames: 3).pixel_gba(2, 2)
  end

  # --- Hardware (the emulator): the layers really composite and parallax-scroll ---

  def test_layers_compose_on_the_console
    v = assert_emulator_loads_rom(rom_for(two_layers(0, 0)), frames: 3)
    assert v.green?(44, 44), "far green shows through the empty near layer, got 0x#{format('%04X', v.pixel_gba(44, 44))}"
    assert v.red?(84, 44),   "near red sits in front, got 0x#{format('%04X', v.pixel_gba(84, 44))}"
    assert v.blue?(100, 100), "the near layer is see-through elsewhere, got 0x#{format('%04X', v.pixel_gba(100, 100))}"
  end

  def test_layers_parallax_on_the_console
    v = assert_emulator_loads_rom(rom_for(two_layers(20, 40)), frames: 3)
    assert v.green?(24, 44), "far slid 20px, got 0x#{format('%04X', v.pixel_gba(24, 44))}"
    assert v.red?(44, 44),   "near slid 40px — twice as far (parallax), got 0x#{format('%04X', v.pixel_gba(44, 44))}"
  end
end
