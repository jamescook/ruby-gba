# frozen_string_literal: true

require "test_helper"

# What a fade and a pixelate mean is written once for every backend (Backends::FadeSteps,
# Backends::Blocks). The Advance's display has to count the same steps for its cartridge to draw
# what the interpreter does, so its registers' limits are checked against them here.
class TestDisplayLimits < Minitest::Test
  Hardware = RubyGBA::Console::Hardware

  def test_the_display_blends_in_the_sixteenths_a_fade_counts_in
    assert_equal RubyGBA::IR::Backends::FadeSteps::DISPLAY, Hardware::BLD_MAX
  end

  def test_a_colour_walk_counts_the_levels_a_colour_channel_has
    assert_equal RubyGBA::IR::Backends::FadeSteps::WALK, Hardware::CHANNEL_LEVELS
  end

  def test_the_display_keeps_the_biggest_block_a_pixelate_reaches
    assert_equal RubyGBA::IR::Backends::Blocks::LARGEST, Hardware::MOSAIC_LARGEST
  end
end
