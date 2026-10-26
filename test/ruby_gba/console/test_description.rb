# frozen_string_literal: true

require "test_helper"

# What a console description says about time and sound, which the interpreter reads for the
# console a game is played as.
class TestDescription < Minitest::Test
  # Neither console shows sixty pictures a second. The Color's clock is a quarter of the
  # Advance's and its frame a quarter as many cycles, so the two frames are the same length:
  # 280896 cycles of 16777216 a second.
  def test_both_consoles_take_the_same_time_over_a_frame
    frame = Rational(280_896, 16_777_216)

    assert_equal frame, RubyGBA::Console::ADVANCE.frame_seconds
    assert_equal frame, RubyGBA::Console::COLOR.frame_seconds
  end

  # The Advance's mix fills whole lots of sixteen samples a frame, at a rate that divides the
  # frame exactly.
  def test_the_advances_sample_clock_fills_whole_lots_each_frame
    clock = RubyGBA::Console::ADVANCE.sample_clock(8000)

    assert_equal 280_896, clock.period * clock.samples_a_frame
    assert_equal 0, clock.samples_a_frame % 16
  end

  def test_a_console_that_mixes_no_recordings_has_no_sample_clock
    error = assert_raises(ArgumentError) { RubyGBA::Console::COLOR.sample_clock(8000) }

    assert_match(/Game Boy Color mixes no recordings/, error.message)
  end
end
