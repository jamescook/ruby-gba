# frozen_string_literal: true

require "test_helper"

# A cartridge's save memory held in Ruby (IR::SaveImage), asked directly: what something that
# plays the game somewhere else — the desktop build, which keeps its save memory in a file —
# needs from it to start from the same bytes and hand the bytes it ended with back.
class TestSaveImage < Minitest::Test
  runs_on :reference

  def test_a_chip_takes_the_bytes_of_a_sav_file_in_place_of_its_own
    left_by_a_run = SaveImage.new(kilobytes: 32)
    left_by_a_run.write(0x10, 0x1234, 2)
    chip = SaveImage.new(kilobytes: 32)
    chip.write(0x10, 0xFFFF_FFFF, 4)
    chip.write(0x200, 9, 1)

    assert_same chip, chip.replace_with_sav(left_by_a_run.to_sav)

    assert_equal left_by_a_run.to_sav, chip.to_sav
    assert_equal({ 0x10 => 0x34, 0x11 => 0x12 }, chip.written, "the byte at 0x200 went with the rest")
  end

  def test_a_sav_file_of_another_size_is_refused
    chip = SaveImage.new(kilobytes: 32)

    error = assert_raises(ArgumentError) { chip.replace_with_sav(SaveImage.new(kilobytes: 64).to_sav, from: "The bytes of door.sav") }

    assert_match(/The bytes of door\.sav are 65536 bytes long/, error.message)
    assert_match(/32K/, error.message)
  end

  # A cut is for one run, and whoever plays that run somewhere else reads how far it is from
  # here.
  def test_a_waiting_cut_says_how_many_steps_it_allows
    chip = SaveImage.new(kilobytes: 32)
    assert_nil chip.power_left

    chip.cut_power_after(3)
    chip.write(0, 0xAB, 1)

    assert_equal 2, chip.power_left
    chip.restore_power
    assert_nil chip.power_left
  end
end
