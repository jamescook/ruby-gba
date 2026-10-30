# frozen_string_literal: true

require "test_helper"
require "all/vblank/ir/test_layer_allocation"

# Two backgrounds sharing a level, drawn: four backgrounds at once, which the Advance shows and
# the Color does not. The Advance's cartridge of the same game is in
# test/lowering/gba/vblank/ir/test_layer_allocation_cartridge.rb.
class TestLayerAllocationOnTheAdvance < Minitest::Test
  include LayerAllocationGames

  GREEN = VBlank::Graphics::Color.resolve(:green)
  BLUE = VBlank::Graphics::Color.resolve(:blue)

  private def screen_of(prog, frames: 3)
    game_player.run(prog, max_steps: 400_000, frames: frames).screen
  end

  # The sprite is behind the back one of the two, and so behind both.
  def test_a_sprite_behind_a_shared_level_is_behind_both_backgrounds
    assert_equal GREEN, screen_of(shared_level_stack).pixel(184, 24)
  end

  # The two keep the order the list gives them: the second is in front.
  def test_the_later_background_of_a_shared_level_is_in_front
    assert_equal BLUE, screen_of(shared_level_stack).pixel(24, 24)
  end
end
