# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Hardware sprites: on a `screen :tiled`, `sprite :hero, at:` gives a sprite the
# console composites over the tiled background — the SAME handle you get in bitmap
# mode (x / y / move), so the game code doesn't change. These assert the observable
# result: the right sprite over the background at its position, no trail when it
# moves, and the friendly guardrails — on the interpreter oracle and on real
# hardware. The dev never touches OAM, tile indices, or object memory.
class TestHardwareSprite < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  EIGHT_BY_EIGHT = (["########"] * 8).join("\n") # a solid 8x8 tile of one color

  # A blue floor of 8x8 tiles filling the screen, and a red 8x8 hero sprite that
  # slides right by +step+ while :right is held, halting after +frames+ steps so its
  # resting place is deterministic. The hero is drawn each frame by the framework —
  # there's no draw call in the loop, exactly like the software sprite.
  def hero_program(frames:, step: 8, start: [40, 40])
    start_x, start_y = start
    floor_map = Array.new(20, "#" * 30) # 30x20 tiles = the whole 240x160 screen
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :blue) { EIGHT_BY_EIGHT }
      image(:hero,  "#" => :red)  { EIGHT_BY_EIGHT }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: floor_map
      hero = sprite :hero, at: [start_x, start_y]
      f = var :f, 0
      game_loop do
        wait_vblank
        held(:right).then { hero.x.add step }
        f.add 1
        (f >= frames).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "HWSPRITE", code: "BHWS", maker: "01")
  end

  # --- it renders, composited over the background ---

  def test_the_sprite_renders_over_the_tiled_background
    # No input held, so the hero stays at (40, 40): its 8x8 body covers 40..47.
    screen = Ruby.new.run(hero_program(frames: 2)).screen
    assert_equal Color.resolve(:red),  screen.pixel(44, 44), "the hero renders over the background"
    assert_equal Color.resolve(:blue), screen.pixel(8, 8),   "the floor shows where the hero isn't"
  end

  def test_the_sprite_renders_on_the_console
    v = assert_gemba_loads_rom(rom_for(hero_program(frames: 2)), frames: 3)
    assert v.red?(44, 44),  "the hero renders on hardware, got 0x#{format('%04X', v.pixel_gba(44, 44))}"
    assert v.blue?(8, 8),   "the floor renders behind it, got 0x#{format('%04X', v.pixel_gba(8, 8))}"
  end

  # --- it moves, and the console redraws the whole scene so no trail is left ---

  # Holding right for 3 frames (step 8): drawn at 40, 48, 56 on successive frames,
  # so it comes to rest with its body over 56..63 while the start column shows floor.
  def test_a_moving_sprite_leaves_no_trail
    screen = Ruby.new.input_each_frame { [:right] }.run(hero_program(frames: 3)).screen
    assert_equal Color.resolve(:red),  screen.pixel(60, 44), "the hero is at its new spot"
    assert_equal Color.resolve(:blue), screen.pixel(44, 44), "the start column shows floor again — no trail"
  end

  def test_a_moving_sprite_leaves_no_trail_on_the_console
    v = assert_gemba_loads_rom(rom_for(hero_program(frames: 3)), frames: 5, keys: KEY_RIGHT)
    assert v.red?(60, 44),  "the hero moved right, got 0x#{format('%04X', v.pixel_gba(60, 44))}"
    assert v.blue?(44, 44), "no trail at the start column, got 0x#{format('%04X', v.pixel_gba(44, 44))}"
  end

  # --- friendly guardrails ---
  # (facing/poses now work in tiled mode — see test_hardware_sprite_facing.rb)

  def test_a_non_tile_sized_sprite_is_a_friendly_error
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:blob, "#" => :red) { "#####\n#####\n#####" } # 5x3 — not a sprite size
      sprite :blob, at: [0, 0]
    end
    b.emit_pending_functions
    err = assert_raises(GBA::LoweringError) { GBA.new.lower(b.program) }
    assert_match(/sizes/, err.message)
  end
end
