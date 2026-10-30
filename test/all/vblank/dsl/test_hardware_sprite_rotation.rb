# frozen_string_literal: true

require "test_helper"

# Turning a hardware sprite to an arbitrary angle (affine rotation). On a
# `screen :tiled`, `sprite.face_angle(d)` / `sprite.turn(d)` rotate the picture to
# any angle, pivoting on its own center — the thing `face` (a swap between a few
# fixed poses) can't do. These assert the friendly guardrails; where the picture's parts
# end up after it turns, on the Advance's cartridge, is in
# test/lowering/gba/vblank/dsl/test_hardware_sprite_rotation_cartridge.rb. The dev never
# touches the OAM affine matrix, a sine table, or fixed-point math.
class TestHardwareSpriteRotation < Minitest::Test
  # --- friendly guardrails ---

  # A bitmap sprite can't turn to an angle (no hardware rotate/scale) — a friendly
  # error that names the fix, not a NoMethodError.
  def test_a_bitmap_sprite_cannot_turn
    builder = Builder.new
    err = assert_raises(ArgumentError) do
      builder.instance_eval do
        screen :bitmap
        image(:hero, "#" => :red) { (["########"] * 8).join("\n") }
        clear_screen :black
        sprite(:hero, at: [10, 10]).face_angle(45)
      end
    end
    assert_match(/screen :tiled/, err.message)
  end

  # The console has 32 rotation groups, so at most 32 sprites can turn at once. The
  # 33rd is a friendly build error, not a silently-wrong sprite.
  def test_more_than_32_turning_sprites_is_a_friendly_error
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :blue) { (["########"] * 8).join("\n") }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: Array.new(20, "#" * 30)
      33.times do |k|
        image(:"s#{k}", "#" => :red) { (["########"] * 8).join("\n") }
        sprite(:"s#{k}", at: [0, 0]).turn(1)
      end
    end
    builder.finalize_program
    err = assert_raises(GBA::LoweringError) { GBA.new.lower(builder.program) }
    assert_match(/at most 32/, err.message)
  end
end
