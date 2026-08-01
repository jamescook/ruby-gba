# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Directional sprite animation: `facing:` given a LIST of frames per direction runs a
# per-direction animation — a character with its own walk cycle each way it faces, or
# Pac chomping in whichever direction he moves. The pose the sprite shows composes the
# two selectors: pose = direction * frames_per_direction + frame. These prove, on the
# interpreter oracle and on real hardware, that facing picks the right ROW and the
# frame animates WITHIN it.
class TestDirectionalAnimation < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  SOLID8 = (["########"] * 8).join("\n")

  # A hero at (40, 40) facing +face+, with a two-frame walk cycle per direction over a
  # gray field: right cycles red -> green, down cycles blue -> white. Each direction is
  # its own pair of colors, so the pixel at the hero says both which way it faces and
  # which frame is up. It halts after +run+ frames, so the screen is deterministic.
  def walker(mode:, face:, run:, rate: 2)
    builder = Builder.new
    builder.instance_eval do
      screen mode
      if mode == :tiled
        image(:field, "#" => :gray) { SOLID8 }
        tiles :ground, "#" => :field
        background :bg, tiles: :ground, map: Array.new(20, "#" * 30)
      else
        clear_screen :gray
      end
      image(:rt0, "#" => :red)   { SOLID8 }
      image(:rt1, "#" => :green) { SOLID8 }
      image(:dn0, "#" => :blue)  { SOLID8 }
      image(:dn1, "#" => :white) { SOLID8 }
      hero = sprite :hero, at: [40, 40],
                          facing: { right: %i[rt0 rt1], down: %i[dn0 dn1] }, rate: rate
      hero.face face # face once, at setup — it holds while the frame animates
      f = var :f, 0
      game_loop do
        wait_vblank
        f.add 1
        (f >= run).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def spot(program)
    Ruby.new.run(program).screen.pixel(44, 44)
  end

  # --- the interpreter oracle: facing picks the row, the frame animates within it ---

  def test_facing_right_shows_the_right_walk_cycle
    assert_equal Color.resolve(:red),   spot(walker(mode: :bitmap, face: :right, run: 2)), "right, first frame"
    assert_equal Color.resolve(:green), spot(walker(mode: :bitmap, face: :right, run: 4)), "right, next frame"
  end

  def test_facing_down_shows_the_down_walk_cycle
    assert_equal Color.resolve(:blue),  spot(walker(mode: :bitmap, face: :down, run: 2)), "down, first frame"
    assert_equal Color.resolve(:white), spot(walker(mode: :bitmap, face: :down, run: 4)), "down, next frame"
  end

  # The whole point: turning does NOT reset to some other direction's frame. Facing down
  # shows a down color (blue/white), never a right color (red/green).
  def test_turning_switches_the_whole_cycle
    down = spot(walker(mode: :bitmap, face: :down, run: 2))
    refute_equal Color.resolve(:red),   down, "facing down must not show a right-facing frame"
    refute_equal Color.resolve(:green), down, "facing down must not show a right-facing frame"
  end

  # Same behavior on a hardware (tiled) sprite: the console composites the composed pose.
  def test_a_hardware_sprite_animates_per_direction
    assert_equal Color.resolve(:red),   spot(walker(mode: :tiled, face: :right, run: 2)), "right, first frame"
    assert_equal Color.resolve(:green), spot(walker(mode: :tiled, face: :right, run: 4)), "right, next frame"
    assert_equal Color.resolve(:blue),  spot(walker(mode: :tiled, face: :down,  run: 2)), "down, first frame"
  end

  # --- real hardware: the composed pose renders on the console ---

  def test_on_console_the_faced_direction_composites
    rom = ROM.assemble(GBA.new.lower(walker(mode: :tiled, face: :down, run: 3)),
                       title: "DIRANIM", code: "BDIR", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 3)
    assert v.blue?(44, 44), "facing down, the console should composite a down-facing frame (blue), got #{v.pixel_gba(44, 44).to_s(16)}"
  end

  # --- friendly errors ---

  def sprite_error(&block)
    b = Builder.new
    assert_raises(ArgumentError) { b.instance_eval(&block) }
  end

  def test_uneven_frame_counts_per_direction_are_a_friendly_error
    err = sprite_error do
      screen :bitmap
      sprite :h, at: [0, 0], facing: { right: %i[a b], down: %i[c] }, rate: 2
    end
    assert_match(/same number of frames/, err.message)
  end

  def test_one_frame_per_direction_points_to_plain_facing
    err = sprite_error do
      screen :bitmap
      sprite :h, at: [0, 0], facing: { right: %i[a], down: %i[b] }, rate: 2
    end
    assert_match(/not an animation/, err.message)
  end

  def test_a_directional_animation_needs_a_rate
    err = sprite_error do
      screen :bitmap
      sprite :h, at: [0, 0], facing: { right: %i[a b], down: %i[c d] }
    end
    assert_match(/rate:/, err.message)
  end

  def test_mixed_shapes_across_directions_are_a_friendly_error
    err = sprite_error do
      screen :bitmap
      sprite :h, at: [0, 0], facing: { right: %i[a b], down: :c }, rate: 2
    end
    assert_match(/same shape/, err.message)
  end
end
