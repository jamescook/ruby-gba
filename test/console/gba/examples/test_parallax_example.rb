# frozen_string_literal: true

require "test_helper"

require "stringio"
require VBlank.root.join("examples/parallax").to_s

# The Parallax example (examples/parallax.rb): two tiled background layers — far sky
# with clouds, near ground with trees — that scroll at different speeds to fake depth.
# Proves the layers composite (the near layer is see-through above so the sky shows),
# and that scrolling slides the near layer. The rigorous "near moves twice as fast as
# far" is pinned in test_background_layers.rb; this confirms the example itself renders
# and scrolls. The same on the Advance's cartridge, read in the emulator, is in
# test/lowering/gba/examples/test_parallax_example_cartridge.rb, which looks for the colours
# kept here in ParallaxColors.
module ParallaxColors
  SKY   = VBlank::Graphics::Color.rgb(11, 17, 28) # the far layer's sky
  GRASS = VBlank::Graphics::Color.rgb(4, 18, 4)   # the near layer's grass line
  LEAF  = VBlank::Graphics::Color.rgb(2, 18, 4)   # a near-layer tree's leaves

  # Any tree leaf in the tree row (py 136..143) within the given screen-x span — the
  # trees move with the near layer, so this is how we spot where they've slid to.
  private def leaf_in_row?(xs)
    xs.any? { |x| (136..143).any? { |y| yield(x, y) } }
  end
end

class TestParallaxExample < Minitest::Test
  include ParallaxColors

  def test_the_example_builds_clean
    rom = Parallax.build_rom(err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # At rest the two layers stack: sky up top (the near layer is see-through there),
  # grass along the bottom, a tree standing on it — and the tree's transparent corner
  # lets the sky show right beside its leaves.
  def test_the_layers_compose_at_rest
    s = game_player.run(Parallax.program, max_steps: 300).screen
    assert_equal SKY,   s.pixel(4, 4),     "the far sky shows at the top, through the see-through near layer"
    assert_equal GRASS, s.pixel(4, 148),   "the near layer's grass shows along the bottom"
    assert_equal LEAF,  s.pixel(10, 138),  "a near-layer tree stands on the grass"
    assert_equal SKY,   s.pixel(8, 136),   "the tree's transparent corner lets the far sky show beside its leaves"
  end

  # Hold right and the near layer slides (2px/frame): after 8 frames its trees have
  # moved 16px, so a tree now stands where sky was, while the sky still fills the top.
  def test_scrolling_slides_the_near_layer
    s = game_player.input_each_frame { |f| f <= 8 ? [:right] : [] }.run(Parallax.program, max_steps: 400).screen
    refute_equal LEAF, game_player.run(Parallax.program, max_steps: 300).screen.pixel(34, 138),
                 "sanity: at rest there's no tree leaf at x34"
    assert_equal LEAF, s.pixel(34, 138), "a tree has slid over to x34 as the near layer scrolled"
    assert_equal SKY,  s.pixel(4, 4),    "the sky still fills the top"
  end
end
