# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/animate").to_s

# The Animate example (examples/animate.rb): a spinning coin (a flipbook `sprite`
# with frames:/rate:) you can also walk around. This confirms the example itself
# renders; that the flipbook actually cycles over time is pinned in
# test_sprite_animation.rb. Its cartridge, built and read in the emulator, is in
# test/lowering/gba/examples/test_animate_example_cartridge.rb.
class TestAnimateExample < Minitest::Test
  # The coin's centre column is gold on every frame of the spin (only its width
  # changes), so it's a stable point to find it.
  CENTRE = [119, 79].freeze

  def test_the_coin_renders
    s = game_player.run(Animate.program, max_steps: 200).screen
    assert_equal Color.resolve(:yellow), s.pixel(*CENTRE), "the coin renders in the middle"
  end
end
