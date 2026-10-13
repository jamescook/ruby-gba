# frozen_string_literal: true

require "test_helper"

# THE SOUND OF A RUN, KEPT WITHOUT KEEPING IT ALL IN MEMORY. A run of a few seconds holds its
# sound in memory and that is the end of it. A playthrough of several minutes would hold
# hundreds of megabytes, so past a set number of frames the sound goes to a scratch file, and
# what is read back is the file and the memory put together.
class TestRecordedSound < Minitest::Test
  RecordedSound = RubyGBA::Diagnostics::RecordedSound

  # Ten frames, each a different length and holding different samples, so a frame read back
  # from the wrong place or cut at the wrong byte is a different frame.
  FRAMES = Array.new(10) { |n| Array.new(n + 1) { |sample| (n * 100) + sample }.pack("s<*") }

  def test_sound_past_the_frames_held_in_memory_reads_back_whole
    Dir.mktmpdir("recorded-sound") do |folder|
      sound = RecordedSound.new(frames_in_memory: 2, folder: folder)

      FRAMES.each_slice(3) { |played| sound.keep(played) }

      assert_equal FRAMES, sound.each_frame.to_a, "frame by frame, in the order they were played"
      assert_equal FRAMES.join, sound.bytes, "and as one run"
    end
  end

  # What is out of memory is in the file, so the file says how much is left in memory: the
  # last two frames at most. Three frames at a time is past two every time, so sound is
  # moved to the file three times over.
  def test_sound_past_the_frames_held_in_memory_goes_to_one_scratch_file
    Dir.mktmpdir("recorded-sound") do |folder|
      sound = RecordedSound.new(frames_in_memory: 2, folder: folder)

      FRAMES.each_slice(3) { |played| sound.keep(played) }

      files = Dir.children(folder)
      assert_equal 1, files.size, "one file for the run, however many times sound was moved to it"
      assert_operator File.size(File.join(folder, files.first)), :>=, FRAMES[0...-2].sum(&:bytesize)
    end
  end

  def test_run_no_longer_than_the_frames_held_in_memory_writes_no_file
    Dir.mktmpdir("recorded-sound") do |folder|
      sound = RecordedSound.new(frames_in_memory: 10, folder: folder)

      FRAMES.each_slice(3) { |played| sound.keep(played) }

      assert_empty Dir.children(folder), "ten frames is not past ten"
      assert_equal FRAMES, sound.each_frame.to_a
    end
  end

  def test_run_that_made_no_sound_reads_back_as_nothing
    sound = RecordedSound.new

    assert_empty sound.each_frame.to_a
    assert_equal "", sound.bytes
  end

  def test_frames_held_in_memory_that_are_no_count_are_refused
    [0, -5, 2.5, "60", nil].each do |given|
      error = assert_raises(ArgumentError) { RecordedSound.new(frames_in_memory: given) }

      assert_match(/frames_in_memory/, error.message)
      assert_includes error.message, given.inspect
    end
  end
end
