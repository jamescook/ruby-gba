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

    assert_equal frame, VBlank::Console::ADVANCE.frame_seconds
    assert_equal frame, VBlank::Console::COLOR.frame_seconds
  end

  # The Advance's mix fills whole lots of sixteen samples a frame, at a rate that divides the
  # frame exactly.
  def test_the_advances_sample_clock_fills_whole_lots_each_frame
    clock = VBlank::Console::ADVANCE.sample_clock(8000)

    assert_equal 280_896, clock.period * clock.samples_a_frame
    assert_equal 0, clock.samples_a_frame % 16
  end

  # The Super Nintendo plays each recording on a voice of its sound chip, which reads 32000 samples
  # a second whatever a game's recordings ask for (fullsnes, "SNES APU DSP"). A frame is 357366 of
  # 21477270 cycles a second, 532.45 of those samples, and a mix counts whole samples a frame: 532.
  def test_the_super_nintendos_sample_clock_is_its_sound_chips
    clock = VBlank::Console::SUPER_NINTENDO.sample_clock(8000)

    assert_equal [32_000, 532], [clock.rate, clock.samples_a_frame]
  end

  # The Color plays a recording a sample at a time from its timer, which counts in eights of the
  # frame's cycles and at most 256 of them: the nearest it keeps to 8192 a second is a tick every
  # 528 cycles, 133 to a frame.
  def test_the_colors_sample_clock_is_a_timer_it_can_set
    clock = VBlank::Console::COLOR.sample_clock(8192)

    assert_equal 528, clock.period
    assert_equal 133, clock.samples_a_frame
    assert_equal 7943, clock.rate
  end
end
