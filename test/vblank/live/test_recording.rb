# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# A live play recorded: a device wrapped so that everything still goes to it, while every frame's
# sound handed to its speaker is kept, with how much was already waiting there, to be listened to
# or read afterwards. These wrap the device with no screen, whose clock a test moves.
class TestRecording < Minitest::Test
  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless
  Recording = VBlank::Live::Recording

  private def beeping_game
    builder = Builder.new
    builder.instance_eval do
      enable_sound
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 2).then { beep 440, duty: :half, decay: :none, volume: 15 }
      end
    end
    builder.finalize_program
    builder.program
  end

  # The device is shown and handed everything as it would be unwrapped, and the recording keeps
  # the same sound, frame after frame.
  def test_a_recorded_play_keeps_every_frame_the_speaker_was_handed
    program = beeping_game
    device = Headless.new(frames: 6, speaker: true)
    recording = Recording.new(device, frame_seconds: program.described_console.frame_seconds)
    Session.new(program).play(recording)

    assert_equal 6, device.pictures.size
    assert_equal device.sounds.flatten, recording.sound.samples
    assert_equal device.sound_rate, recording.sound.rate
    refute(recording.sound.samples.all?(&:zero?), "the beep should be in the recording")
  end

  # Each frame's sound is logged with how much was waiting for the speaker as it came, which is
  # how a speaker that ran dry is found: here nothing was waiting before the first frame's sound.
  def test_each_frame_is_logged_with_what_was_waiting_for_the_speaker
    program = beeping_game
    recording = Recording.new(Headless.new(frames: 4, speaker: true), frame_seconds: program.described_console.frame_seconds)
    Session.new(program).play(recording)

    assert_equal 4, recording.log.size
    refute recording.log.first.waiting&.positive?, "nothing was waiting before the first frame's sound"
    assert(recording.log.drop(1).none?(&:ran_dry?), "the speaker should never have run dry after the first frame")
  end

  # A pass two frames long, on a machine whose speaker keeps only what each frame hands it, leaves
  # the speaker with nothing: the next frame's sound is logged as coming to a speaker run dry.
  def test_a_speaker_that_ran_dry_is_in_the_log
    program = beeping_game
    frame = program.described_console.frame_seconds
    device = Headless.new(frames: 6, speaker: true, pass_seconds: ->(pass) { pass == 4 ? 30 * frame : 0 })
    recording = Recording.new(device, frame_seconds: frame)
    Session.new(program).play(recording)

    assert(recording.log.drop(1).any?(&:ran_dry?), "a pass far longer than the sound waiting should run the speaker dry")
  end

  # A play that makes no sound has no recording, rather than an empty one at no rate.
  def test_a_play_with_no_sound_has_no_recording
    recording = Recording.new(Headless.new(frames: 2), frame_seconds: 1r / 60)

    assert_nil recording.sound
  end
end
