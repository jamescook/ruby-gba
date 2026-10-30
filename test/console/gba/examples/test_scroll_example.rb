# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/scroll").to_s

# Where the lake is, shared with the cartridge's tests
# (test/lowering/gba/examples/test_scroll_example_cartridge.rb).
module ScrollExampleLake
  # The lake sits at map cols 12-19, rows 10-14 -> pixels x 96..159, y 80..119, all on
  # screen at the starting (0,0) offset.
  private def blue_in_lake?(pixel)
    (100..150).any? { |x| (84..116).any? { |y| pixel.call(x, y) } }
  end
end

# The Scroll example (examples/scroll.rb): pan a camera over a tiled world bigger
# than the screen. This confirms the world renders; the scrolling and wrapping
# themselves are pinned in test_background_scroll.rb. Its cartridge, built and read in the
# emulator, is in test/lowering/gba/examples/test_scroll_example_cartridge.rb.
class TestScrollExample < Minitest::Test
  include ScrollExampleLake

  def test_the_world_renders
    s = game_player.run(Scroll.program, max_steps: 200).screen
    blue = VBlank::Graphics::Color.resolve(:blue)
    assert blue_in_lake?(->(x, y) { s.pixel(x, y) == blue }), "the lake renders in the middle of the world"
  end
end
