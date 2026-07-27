# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Facing / poses for hardware sprites (OAM slice 3): a `screen :tiled` sprite given
# `facing:` poses turns to face the way it moves — the console swaps which of the
# sprite's uploaded pictures it draws, with the tile data managed for the player.
# Same `facing:` / `face` / `move` handle as the software sprite. The poses here are
# deliberately different colors so the swap is observable in a pixel. Asserted on
# the interpreter oracle and on real hardware — the same pose-swap the (timer-driven)
# flipbook animation verb builds on.
class TestHardwareSpriteFacing < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  SOLID8 = (["########"] * 8).join("\n")
  FLOOR_MAP = Array.new(20, "#" * 30).freeze

  # A sprite red when facing right, blue when facing left. It slides toward whichever
  # wall you hold and clamps there, so its resting spot AND pose are deterministic:
  # holding left, it ends against the left wall (x=8) showing the blue pose; holding
  # right, against the right wall (x=224) showing the red pose.
  def facing_program(frames: 40)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor,      "#" => :white) { SOLID8 }
      image(:look_right, "#" => :red)   { SOLID8 }
      image(:look_left,  "#" => :blue)  { SOLID8 }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: FLOOR_MAP
      pac = sprite :pac, at: [100, 40], facing: { right: :look_right, left: :look_left }
      f = var :f, 0
      game_loop do
        wait_vblank
        held(:left).then  { pac.move :left,  by: 4 } # move AND face left  -> blue pose
        held(:right).then { pac.move :right, by: 4 } # move AND face right -> red pose
        pac.x.clamp 8, 224
        f.add 1
        (f >= frames).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "FACING", code: "BFAC", maker: "01")
  end

  def test_a_sprite_faces_the_way_it_moves
    left = Ruby.new.input_each_frame { [:left] }.run(facing_program).screen
    assert_equal Color.resolve(:blue), left.pixel(10, 43), "moving left shows the left-facing (blue) pose"

    right = Ruby.new.input_each_frame { [:right] }.run(facing_program).screen
    assert_equal Color.resolve(:red), right.pixel(226, 43), "moving right shows the right-facing (red) pose"
  end

  def test_facing_swaps_the_pose_on_the_console
    vl = assert_gemba_loads_rom(rom_for(facing_program), frames: 42, keys: KEY_LEFT)
    assert vl.blue?(10, 43), "left-facing pose renders blue, got 0x#{format('%04X', vl.pixel_gba(10, 43))}"

    vr = assert_gemba_loads_rom(rom_for(facing_program), frames: 42, keys: KEY_RIGHT)
    assert vr.red?(226, 43), "right-facing pose renders red, got 0x#{format('%04X', vr.pixel_gba(226, 43))}"
  end

  # --- friendly guardrails ---

  def test_facing_a_direction_the_sprite_lacks_is_a_friendly_error
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:look_right, "#" => :red)  { SOLID8 }
      image(:look_left,  "#" => :blue) { SOLID8 }
    end
    pac = b.instance_eval { sprite :pac, at: [0, 0], facing: { right: :look_right, left: :look_left } }
    err = assert_raises(ArgumentError) { pac.face(:up) }
    assert_match(/cannot face/, err.message)
  end

  def test_poses_of_different_sizes_are_a_friendly_error
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:small, "#" => :red)  { SOLID8 }                 # 8x8
      image(:big,   "#" => :blue) { (["################"] * 16).join("\n") } # 16x16
    end
    err = assert_raises(ArgumentError) do
      b.instance_eval { sprite :pac, at: [0, 0], facing: { right: :small, left: :big } }
    end
    assert_match(/same size/, err.message)
  end
end
