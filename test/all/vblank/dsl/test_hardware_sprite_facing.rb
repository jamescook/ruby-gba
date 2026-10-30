# frozen_string_literal: true

require "test_helper"

# The facing game, shared with the Advance cartridge's own test of it
# (test/lowering/gba/vblank/dsl/test_hardware_sprite_facing_cartridge.rb).
module HardwareSpriteFacingGames
  include SharedConstants

  # Shareable, since a test plays in a Ractor and a module's constants are not frozen for it.
  FLOOR_MAP = Ractor.make_shareable(Array.new(20, "#" * 30))

  # A sprite red when facing right, blue when facing left. It slides toward whichever
  # wall you hold and clamps there, so its resting spot AND pose are deterministic:
  # holding left, it ends against the left wall (x=8) showing the blue pose; holding
  # right, against the right wall (x=224) showing the red pose.
  private def facing_program(frames: 40)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor,      "#" => :white) { SOLID_TILE }
      image(:look_right, "#" => :red)   { SOLID_TILE }
      image(:look_left,  "#" => :blue)  { SOLID_TILE }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: FLOOR_MAP
      pac = sprite :pac, at: [100, 40], facing: { right: :look_right, left: :look_left }
      f = var :f, 0
      game_loop do
        wait_vblank
        held(:left).then  { pac.move :left,  by: 4 } # move AND face left  -> blue pose
        held(:right).then { pac.move :right, by: 4 } # move AND face right -> red pose
        pac.x.clamp! 8, 136 # inside both consoles' screens
        f.add! 1
        (f >= frames).then { halt }
      end
    end
    builder.finalize_program
    builder.program
  end
end

# Facing / poses for hardware sprites (OAM slice 3): a `screen :tiled` sprite given
# `facing:` poses turns to face the way it moves — the console swaps which of the
# sprite's uploaded pictures it draws, with the tile data managed for the player.
# Same `facing:` / `face` / `move` handle as the software sprite. The poses here are
# deliberately different colors so the swap is observable in a pixel. Asserted on
# every run, and on the Advance's cartridge in the file named above — the same pose-swap
# the (timer-driven) flipbook animation verb builds on.
class TestHardwareSpriteFacing < Minitest::Test
  include VBlank::Console::Hardware
  include HardwareSpriteFacingGames

  def test_a_sprite_faces_the_way_it_moves
    left = game_player.input_each_frame { [:left] }.run(facing_program, frames: 45).screen
    assert_equal Color.resolve(:blue), left.pixel(10, 43), "moving left shows the left-facing (blue) pose"

    right = game_player.input_each_frame { [:right] }.run(facing_program, frames: 45).screen
    assert_equal Color.resolve(:red), right.pixel(138, 43), "moving right shows the right-facing (red) pose"
  end

  # --- friendly guardrails ---

  def test_facing_a_direction_the_sprite_lacks_is_a_friendly_error
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:look_right, "#" => :red)  { SOLID_TILE }
      image(:look_left,  "#" => :blue) { SOLID_TILE }
    end
    pac = b.instance_eval { sprite :pac, at: [0, 0], facing: { right: :look_right, left: :look_left } }
    err = assert_raises(ArgumentError) { pac.face(:up) }
    assert_match(/cannot face/, err.message)
  end

  def test_poses_of_different_sizes_are_a_friendly_error
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:small, "#" => :red)  { SOLID_TILE }                 # 8x8
      image(:big,   "#" => :blue) { (["################"] * 16).join("\n") } # 16x16
    end
    err = assert_raises(ArgumentError) do
      b.instance_eval { sprite :pac, at: [0, 0], facing: { right: :small, left: :big } }
    end
    assert_match(/same size/, err.message)
  end
end
