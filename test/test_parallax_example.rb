# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"
require_relative "test_helper"
require_relative "../examples/parallax"

# The Parallax example (examples/parallax.rb): two tiled background layers — far sky
# with clouds, near ground with trees — that scroll at different speeds to fake depth.
# Proves the layers composite (the near layer is see-through above so the sky shows),
# and that scrolling slides the near layer. The rigorous "near moves twice as fast as
# far" is pinned in test_background_layers.rb; this confirms the example itself renders
# and scrolls, on the interpreter oracle and on real hardware.
class TestParallaxExample < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Reference = RubyGBA::IR::Backends::Reference
  Color = RubyGBA::Color

  SKY   = Color.rgb(11, 17, 28) # the far layer's sky
  GRASS = Color.rgb(4, 18, 4)   # the near layer's grass line
  LEAF  = Color.rgb(2, 18, 4)   # a near-layer tree's leaves

  # Any tree leaf in the tree row (py 136..143) within the given screen-x span — the
  # trees move with the near layer, so this is how we spot where they've slid to.
  def leaf_in_row?(xs)
    xs.any? { |x| (136..143).any? { |y| yield(x, y) } }
  end

  def test_the_example_builds_clean
    rom = Parallax.build_rom(err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # At rest the two layers stack: sky up top (the near layer is see-through there),
  # grass along the bottom, a tree standing on it — and the tree's transparent corner
  # lets the sky show right beside its leaves.
  def test_the_layers_compose_at_rest
    s = Reference.new.run(Parallax.program, max_steps: 300).screen
    assert_equal SKY,   s.pixel(4, 4),     "the far sky shows at the top, through the see-through near layer"
    assert_equal GRASS, s.pixel(4, 148),   "the near layer's grass shows along the bottom"
    assert_equal LEAF,  s.pixel(10, 138),  "a near-layer tree stands on the grass"
    assert_equal SKY,   s.pixel(8, 136),   "the tree's transparent corner lets the far sky show beside its leaves"
  end

  # Hold right and the near layer slides (2px/frame): after 8 frames its trees have
  # moved 16px, so a tree now stands where sky was, while the sky still fills the top.
  def test_scrolling_slides_the_near_layer
    s = Reference.new.input_each_frame { |f| f <= 8 ? [:right] : [] }.run(Parallax.program, max_steps: 400).screen
    refute_equal LEAF, Reference.new.run(Parallax.program, max_steps: 300).screen.pixel(34, 138),
                 "sanity: at rest there's no tree leaf at x34"
    assert_equal LEAF, s.pixel(34, 138), "a tree has slid over to x34 as the near layer scrolled"
    assert_equal SKY,  s.pixel(4, 4),    "the sky still fills the top"
  end

  # --- Hardware (gemba): the two layers render and the near one scrolls ---

  def test_the_layers_render_on_the_console
    v = assert_gemba_loads_rom(Parallax.build_rom(err: StringIO.new), frames: 3)
    assert v.pixel_is?(4, 148, GRASS), "the grass renders along the bottom, got 0x#{format('%04X', v.pixel_gba(4, 148))}"
    assert leaf_in_row?(0..40) { |x, y| v.pixel_is?(x, y, LEAF) }, "trees render on the near layer"
  end

  def test_scrolling_slides_the_near_layer_on_the_console
    rest = assert_gemba_loads_rom(Parallax.build_rom(err: StringIO.new), frames: 3)
    refute leaf_in_row?(28..40) { |x, y| rest.pixel_is?(x, y, LEAF) }, "at rest no tree sits at x28..40"

    moved = assert_gemba_loads_rom(Parallax.build_rom(err: StringIO.new), frames: 16,
                                   keys: ->(f) { f <= 8 ? KEY_RIGHT : 0 })
    assert leaf_in_row?(28..40) { |x, y| moved.pixel_is?(x, y, LEAF) },
           "after scrolling right a tree has slid into x28..40 — the near layer moved"
  end
end
