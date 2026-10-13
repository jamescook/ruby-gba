# frozen_string_literal: true

require "test_helper"

# THE SOUND OF A RUN, KEPT WITHOUT KEEPING IT ALL IN MEMORY. A run of a few seconds holds its
# sound in memory and that is the end of it. A playthrough of several minutes would hold
# hundreds of megabytes, so past a set number of frames the sound goes to a scratch file, and
# what is read back is the file and the memory put together.
class TestRecordedSound < Minitest::Test
  runs_on :reference

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

  # --- how loud each frame was ---
  #
  # A frame's loudness is its samples added up with their signs dropped. It is worked out
  # once for each frame and kept, so asking after every frame of a long run costs a frame
  # each time and not the run so far.

  # Frames whose loudness is easy to say: signs, a silent frame, and the two ends of what a
  # sample can hold.
  SIGNED_FRAMES = [[-3, 4], [0], [-32_768, 32_767, -1], [], [5, 5]].map { |samples| samples.pack("s<*") }.freeze
  LOUDNESS = [7, 0, 65_536, 0, 10].freeze

  # The loudness of FRAMES, whose frame n is the samples n * 100 up to n * 100 + n.
  LOUDNESS_OF_FRAMES = [0, 201, 603, 1206, 2010, 3015, 4221, 5628, 7236, 9045].freeze

  def test_how_loud_each_frame_was_is_its_samples_added_up_with_their_signs_dropped
    sound = RecordedSound.new.keep(SIGNED_FRAMES)

    assert_equal LOUDNESS, sound.energy_by_frame
  end

  def test_how_loud_each_frame_was_is_the_same_wherever_the_frame_is_kept
    Dir.mktmpdir("recorded-sound") do |folder|
      in_file = RecordedSound.new(frames_in_memory: 2, folder: folder)
      FRAMES.each_slice(3) { |played| in_file.keep(played) }

      refute_empty Dir.children(folder), "most of these frames are in the file"
      assert_equal LOUDNESS_OF_FRAMES, in_file.energy_by_frame
      assert_equal LOUDNESS_OF_FRAMES, RecordedSound.new.keep(FRAMES).energy_by_frame
    end
  end

  def test_asked_as_the_run_goes_on_it_is_every_frame_so_far
    Dir.mktmpdir("recorded-sound") do |folder|
      sound = RecordedSound.new(frames_in_memory: 2, folder: folder)

      asked = FRAMES.each_slice(3).map do |played|
        sound.keep(played)
        sound.energy_by_frame
      end

      assert_equal [3, 6, 9, 10].map { |frames| LOUDNESS_OF_FRAMES.first(frames) }, asked
    end
  end

  # THE RECORDING IS NOT READ AGAIN FOR A FRAME ALREADY ASKED ABOUT. With the scratch file
  # taken away, the frames in it could not be read a second time: the answer has to be what
  # was kept from the first asking, and frames played since are added to it.
  def test_asking_again_does_not_read_the_recording_again
    Dir.mktmpdir("recorded-sound") do |folder|
      sound = RecordedSound.new(frames_in_memory: 6, folder: folder)
      sound.keep(FRAMES.first(7))
      first = sound.energy_by_frame
      File.delete(File.join(folder, Dir.children(folder).first))
      sound.keep(FRAMES.last(3))

      assert_equal LOUDNESS_OF_FRAMES.first(7), first
      assert_equal LOUDNESS_OF_FRAMES, sound.energy_by_frame
    end
  end

  # ...NOR IS A FRAME STILL IN MEMORY GONE THROUGH AGAIN, which is every frame of a run of a
  # minute or less. Each of these frames notes when its samples are read.
  def test_asking_again_does_not_go_through_a_frame_in_memory_again
    read = Hash.new(0)
    frames = SIGNED_FRAMES.each_with_index.map do |samples, at|
      samples.dup.tap do |frame|
        frame.define_singleton_method(:unpack) do |*how|
          read[at] += 1
          super(*how)
        end
      end
    end
    sound = RecordedSound.new.keep(frames.first(3))

    3.times { sound.energy_by_frame }
    sound.keep(frames.last(2))
    2.times { sound.energy_by_frame }

    assert_equal LOUDNESS, sound.energy_by_frame
    assert_equal({ 0 => 1, 1 => 1, 2 => 1, 3 => 1, 4 => 1 }, read, "each frame's samples were read once")
  end

  def test_what_is_handed_back_can_be_changed_without_changing_what_is_kept
    sound = RecordedSound.new.keep(SIGNED_FRAMES)
    sound.energy_by_frame.shift
    sound.energy_by_frame.map! { 1 }

    assert_equal LOUDNESS, sound.energy_by_frame
  end

  def test_run_that_made_no_sound_was_never_loud
    assert_empty RecordedSound.new.energy_by_frame
  end

  def test_frames_held_in_memory_that_are_no_count_are_refused
    [0, -5, 2.5, "60", nil].each do |given|
      error = assert_raises(ArgumentError) { RecordedSound.new(frames_in_memory: given) }

      assert_match(/frames_in_memory/, error.message)
      assert_includes error.message, given.inspect
    end
  end
end
