# frozen_string_literal: true

require "test_helper"

# The test of test_pool_sprites.rb that pins an instance to the corner of the Advance's screen,
# so it plays on the Advance's runs alone. clamp_to_screen holds a sprite to the screen of the
# console the game is built for, and this game is built for the Advance: on a Game Boy Color's
# smaller screen that corner is off the picture.
class TestPoolSpritesOnTheAdvance < Minitest::Test
  GREEN = Color.resolve(:green)

  # A tiled program with an :ufo image (8x8 green) and an enemy pool; the block spawns
  # instances and adds per-frame behavior via the pool handle.
  private def enemy_program
    b = Builder.new
    handle = nil
    b.instance_eval do
      screen :tiled
      image(:ufo, "#" => :green) { "########\n" * 8 }
      handle = pool :enemy, x: 0, y: 0, capacity: 8, image: :ufo
      yield(self, handle)
    end
    b.finalize_program
    b.program
  end

  # clamp_to_screen pins an instance on screen using its sprite size — one spawned off
  # the bottom-right corner is pulled back and drawn at the edge.
  def test_clamp_to_screen_works_on_an_instance
    prog = enemy_program do |b, enemies|
      enemies.spawn x: 300, y: 300 # off the bottom-right
      b.game_loop do
        b.wait_vblank
        enemies.each(&:clamp_to_screen)
      end
    end
    i = game_player.run(prog)
    # 8x8 sprite clamps its top-left to (240-8, 160-8) = (232, 152)
    assert_equal GREEN, i.screen.pixel(234, 154), "the instance was pinned to the bottom-right edge"
  end
end
