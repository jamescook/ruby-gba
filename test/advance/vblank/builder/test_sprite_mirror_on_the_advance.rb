# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test_sprite_mirror.rb whose games turn a sprite, which a Game Boy Color's hardware
# cannot do, so they play on the Advance's runs alone.
class TestSpriteMirrorOnTheAdvance < Minitest::Test
  include Differential

  CANVAS = 32
  INK = VBlank::Graphics::Color.rgb(31, 20, 0)
  EDGE = VBlank::Graphics::Color.rgb(0, 31, 10)
  CLEAR = VBlank::Graphics::Color.rgb(0, 0, 1)

  # A pose that is deliberately NOT symmetric and NOT centred: a block at (+ox+, +oy+)
  # with its left column a different colour, so a mirror that is drawn in the wrong
  # place — or the right place but the wrong way round — shows up as different pixels.
  private def lopsided(ox, oy, w = 10, h = 12)
    (0...(CANVAS * CANVAS)).map do |i|
      x = i % CANVAS
      y = i / CANVAS
      next CLEAR unless x >= ox && x < ox + w && y >= oy && y < oy + h

      x == ox ? EDGE : INK
    end
  end

  # A SPRITE THAT TURNS IS NOT MIRRORED. The two attribute bits that reverse an object
  # are the ones that name its rotation group once it is turning, so a turning sprite
  # keeps both sets of pixels — and, more to the point, still draws the right picture.
  def test_a_turning_sprite_with_mirrored_poses_still_draws_correctly
    canvas = CANVAS
    clear = CLEAR
    art = lopsided(6, 4)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :hero_right, width: canvas, height: canvas, data: art, transparent: clear
      hero = sprite :hero, at: [60, 60], frames: [:hero_right, mirror(:hero_right)], rate: 3
      hero.face_angle 30
      game_loop {}
    end
    builder.finalize_program

    assert_backends_agree(builder.program, frames: 12)
  end
end
