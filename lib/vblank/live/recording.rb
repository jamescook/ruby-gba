# frozen_string_literal: true

require "delegate"

module VBlank
  module Live
    # A LIVE PLAY RECORDED: a device wrapped so that everything still goes to it, while every frame's
    # sound handed to its speaker is kept, with how much was already waiting there as it came. The
    # sound is to listen to afterwards (#sound, a Diagnostics::SoundRecording, which writes a .wav);
    # the log is how a speaker that ran dry is found.
    #
    #   recording = Recording.new(window, frame_seconds: program.described_console.frame_seconds)
    #   Session.new(program).play(recording)
    #   recording.sound.write_wav("heard.wav")
    #
    # What is kept is what the game made and handed over. The window throws away a frame its
    # speaker is too far behind to play in time (SDL::SOUND_BEHIND_FRAMES), which a play paced by
    # the speaker never is; and a fast forward hands the speaker nothing, so its frames are not here.
    class Recording < SimpleDelegator
      # One frame's sound as it was handed over: when, by the device's clock; the seconds of sound
      # already waiting for the speaker (nil where the device has no speaker yet); and how many
      # samples it was.
      FrameSound = Data.define(:at, :waiting, :samples) do
        # The speaker had nothing left to play when this frame's sound came: a gap was heard.
        def ran_dry? = !waiting.nil? && waiting <= 0
      end

      attr_reader :log

      def initialize(device, frame_seconds:)
        super(device)
        @frame_seconds = frame_seconds
        @samples = []
        @log = []
        @rate = nil
      end

      def play_sound(samples, rate)
        @log << FrameSound.new(at: now, waiting: sound_waiting, samples: samples.length)
        @samples.concat(samples)
        @rate = rate
        super
      end

      # Every sample handed to the speaker so far, one after another, or nil before any was.
      def sound
        return nil unless @rate

        Diagnostics::SoundRecording.new(samples: @samples, rate: @rate, frame_seconds: @frame_seconds)
      end
    end
  end
end
