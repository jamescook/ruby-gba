# frozen_string_literal: true

require "test_helper"

require "stringio"
require "console/gba/examples/test_parallax_example"

# The Parallax example (examples/parallax.rb) on the Advance's own cartridge: the two layers
# render and the near one scrolls, read off its screen in the emulator. What the example draws
# on every run that plays the Advance is in test/console/gba/examples/test_parallax_example.rb,
# which keeps the colours both files look for in ParallaxColors.
class TestParallaxExampleCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include ParallaxColors

  # --- Hardware (the emulator): the two layers render and the near one scrolls ---

  def test_the_layers_render_on_the_console
    v = assert_emulator_loads_rom(Parallax.build_rom(err: StringIO.new), frames: 3)
    assert v.pixel_is?(4, 148, GRASS), "the grass renders along the bottom, got 0x#{format('%04X', v.pixel_gba(4, 148))}"
    assert leaf_in_row?(0..40) { |x, y| v.pixel_is?(x, y, LEAF) }, "trees render on the near layer"
  end

  def test_scrolling_slides_the_near_layer_on_the_console
    rest = assert_emulator_loads_rom(Parallax.build_rom(err: StringIO.new), frames: 3)
    refute leaf_in_row?(28..40) { |x, y| rest.pixel_is?(x, y, LEAF) }, "at rest no tree sits at x28..40"

    moved = assert_emulator_loads_rom(Parallax.build_rom(err: StringIO.new), frames: 16,
                                   keys: ->(f) { f <= 8 ? KEY_RIGHT : 0 })
    assert leaf_in_row?(28..40) { |x, y| moved.pixel_is?(x, y, LEAF) },
           "after scrolling right a tree has slid into x28..40 — the near layer moved"
  end
end
