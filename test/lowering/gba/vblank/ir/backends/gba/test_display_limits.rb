# frozen_string_literal: true

require "test_helper"

# What a fade and a pixelate mean is written once for every backend (Backends::FadeSteps,
# Backends::Blocks). The Advance's display has to count the same steps for its cartridge to draw
# what the interpreter does, so its registers' limits are checked against them here.
class TestDisplayLimits < Minitest::Test
  Hardware = VBlank::Console::Hardware

  def test_the_display_blends_in_the_sixteenths_a_fade_counts_in
    assert_equal VBlank::IR::Backends::FadeSteps::DISPLAY, Hardware::BLD_MAX
  end

  # A game that asks for no fraction walks its colours in the levels a channel has, and those
  # are whole numbers of the 256ths a walk means, so the coarse walk lands on the same colours.
  def test_the_coarse_colour_walk_counts_the_levels_a_colour_channel_has
    assert_equal Hardware::CHANNEL_LEVELS, VBlank::IR::Backends::GBA::PaletteTint::COARSE_WALK
    assert_equal 0, VBlank::IR::Backends::FadeSteps::WALK % Hardware::CHANNEL_LEVELS
  end

  def test_the_display_keeps_the_biggest_block_a_pixelate_reaches
    assert_equal VBlank::IR::Backends::Blocks::LARGEST, Hardware::MOSAIC_LARGEST
  end
end
