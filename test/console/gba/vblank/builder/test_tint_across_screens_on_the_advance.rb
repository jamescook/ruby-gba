# frozen_string_literal: true

require "test_helper"
require "differential"
require "tinted_handover"

# THE TEST OF vblank/builder/test_tint_across_screens.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY,
# kept apart so that the Game Boy Color's run never loads it (test/console/gba); the rest
# are in that file.
#
# The Advance's plain bitmap screen has the display mix a tint in as it draws, at eight bits a
# channel, and a screen with a colour table has it mixed into the table at five. A Game Boy Color
# has no display mix, so every screen of its mixes at five.
class TestTintAcrossScreensOnTheAdvance < Minitest::Test
  include Differential
  include TintedHandover

  # A gray of 16 half way to yellow is 24 on the one and 23 on the other.
  MID_GRAY = 16 | (16 << 5) | (16 << 10)
  GRAY_TO_YELLOW = { plain: 24 | (24 << 5) | (8 << 10), tiled: 23 | (23 << 5) | (8 << 10) }.freeze

  # A tint kept across the change is mixed the way the screen it is now on mixes it.
  def test_a_tint_kept_across_is_mixed_the_way_the_new_screen_mixes
    %i[plain tiled].permutation.each do |from, to|
      handover = tinted_handover(from, to, ground: MID_GRAY, toward: :yellow)

      assert_backends_agree(handover, frames: 10, console_frames: 12, name: "TROUND")
      assert_equal GRAY_TO_YELLOW.fetch(to), shown_after_handover(handover), "from #{from} to #{to}"
    end
  end
end
