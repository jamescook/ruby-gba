# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_frames_since_power_on"

# `frames_since_power_on` on the interpreter told how long a pass took, or how long setting up
# took with the screen off — which only the interpreter can be told. What every run reads is in
# test/all/vblank/builder/test_frames_since_power_on.rb.
class TestFramesSincePowerOnInterpreter < Minitest::Test
  include FramesSincePowerOnGames

  # The interpreter has no clock, so a test says how long a pass took; a pass worth three frames
  # moves the reading on by three, as it does on the console. (What it says for the first frame
  # is what setting up took, which here is one.)
  def test_a_pass_that_takes_three_frames_reads_three_more
    run = Reference.new.frames_each_pass { |frame| frame == 1 ? 1 : 3 }.run(counting_game, frames: 4)

    assert_equal 1, run[:first], "the first pass comes after the first frame"
    assert_equal 1 + (3 * 3), run[:now], "and each pass after it took three"
  end

  # A console whose screen is off while it sets up says how many frames that took, and the
  # reading counts them at the first frame — nothing else moves on for them.
  def test_frames_set_up_with_the_screen_off_are_counted_at_the_first_frame
    run = Reference.new.frames_setting_up(6).run(counting_game, frames: 3)

    assert_equal 7, run[:first], "six frames setting up, then the first frame shown"
    assert_equal 7 + 2, run[:now], "and each pass after it one more"
    assert_equal 3, run[:passes]
  end
end
