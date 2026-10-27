# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A recording of what a game sounds like, from the cartridge in the emulator, the desktop build or
# the Ruby lowering, kept as its samples: to write to a .wav and listen to, and to read frame by
# frame — how loud each frame is, and how many waves in it were broken, a voice jumping back to
# the start of its wave where the chip would carry on, which is heard as a rumble.
class TestSoundRecording < Minitest::Test
  # Recording the desktop build and the Ruby lowering starts their programs, which hangs inside a
  # Ractor.
  runs_on_the_main_ractor!

  SoundRecording = VBlank::Diagnostics::SoundRecording
  RATE = 48_000
  FRAME = RATE / 60

  # A square wave +period+ samples long, starting again from its first sample every +restart+.
  private def square(length, period:, restart: nil)
    Array.new(length) { |n| ((restart ? n % restart : n) % period) < period / 2 ? 1000 : -1000 }
  end

  def test_a_steady_tone_has_no_broken_waves
    recording = SoundRecording.new(samples: square(FRAME * 6, period: 109), rate: RATE, frame_seconds: 1r / 60)

    assert_equal [0] * 6, recording.frames.map(&:waves_broken)
  end

  # Started again at every frame, as a voice whose volume changes each frame is restarted: one
  # wave in each frame after the first is broken.
  def test_a_tone_started_again_every_frame_breaks_a_wave_a_frame
    recording = SoundRecording.new(samples: square(FRAME * 6, period: 109, restart: FRAME), rate: RATE, frame_seconds: 1r / 60)

    assert_equal [0, 1, 1, 1, 1, 1], recording.frames.map(&:waves_broken)
  end

  def test_each_frame_says_how_loud_it_is
    samples = square(FRAME, period: 109) + Array.new(FRAME, 0) + square(FRAME, period: 109).map { |s| s / 2 }
    recording = SoundRecording.new(samples: samples, rate: RATE, frame_seconds: 1r / 60)

    assert_equal [2000, 0, 1000], recording.frames.map(&:loudness)
  end

  # Each frame's loudest sample and biggest jump from one sample to the next: a click is a jump
  # far bigger than the tone's own edges.
  def test_each_frame_says_its_loudest_sample_and_biggest_jump
    samples = square(FRAME, period: 109) + Array.new(FRAME, 0).tap { |quiet| quiet[400] = 5000 }
    frames = SoundRecording.new(samples: samples, rate: RATE, frame_seconds: 1r / 60).frames

    assert_equal [1000, 5000], frames.map(&:loudest)
    assert_equal [2000, 5000], frames.map(&:biggest_jump)
  end

  # A held note recorded on each thing that plays it: heard on all three, the desktop build and the
  # game as Ruby sample for sample alike, and no wave broken on any.
  def test_a_held_note_is_recorded_on_the_cartridge_the_desktop_build_and_as_ruby
    builder = Builder.new
    builder.instance_eval do
      enable_sound
      song(:held) { note :A4, :whole }
      play_song :held
      game_loop {}
    end
    builder.finalize_program
    heard = %i[cartridge native ruby].to_h do |on|
      [on, SoundRecording.of(builder.program, on: on, frames: 20, only: :square1)]
    end

    assert_equal heard[:native].samples, heard[:ruby].samples
    heard.each do |on, recording|
      assert_operator recording.frames.map(&:loudness).max, :>, 0, "nothing was heard on #{on}"
      assert_equal 0, recording.frames.sum(&:waves_broken), "a wave was broken on #{on}"
    end
  end

  # Two recordings say where they first differ: a sample changed, one longer than the other, or
  # nowhere.
  def test_two_recordings_say_where_they_first_differ
    recording = ->(samples) { SoundRecording.new(samples: samples, rate: RATE, frame_seconds: 1r / 60) }

    assert_nil recording.call([1, 2, 3]).first_difference(recording.call([1, 2, 3]))
    assert_equal 1, recording.call([1, 2, 3]).first_difference(recording.call([1, 5, 3]))
    assert_equal 2, recording.call([1, 2]).first_difference(recording.call([1, 2, 3]))
  end

  # A .wav a person can open: one speaker, sixteen-bit samples, read back as they were written.
  def test_a_recording_writes_a_wav_that_reads_back_the_same
    recording = SoundRecording.new(samples: [0, 1000, -1000, 32_767, -32_768], rate: RATE, frame_seconds: 1r / 60)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "heard.wav")
      recording.write_wav(path)

      assert_equal recording.samples, SoundRecording.read_wav(path, frame_seconds: 1r / 60).samples
      assert_equal RATE, SoundRecording.read_wav(path, frame_seconds: 1r / 60).rate
    end
  end
end
