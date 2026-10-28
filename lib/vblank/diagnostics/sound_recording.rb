# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHAT A GAME SOUNDS LIKE, RECORDED, so the same moment can be heard and read on each thing
    # that plays it: the cartridge in the emulator, the desktop build (the native runtime) and the
    # game as Ruby. A recording is one speaker's samples, how many a second, and how long one of
    # the console's frames is, so it can be read a frame at a time:
    #
    #   heard = SoundRecording.of(program, on: :native, frames: 120, buttons: { 10 => [:down] })
    #   heard.write_wav("native.wav")             # to listen to
    #   heard.frames.map(&:waves_broken)          # where a voice lost its place in its wave
    #
    # It sits with the readers of a running cartridge because a recording is read the way the
    # cartridge's own sound is, whichever played it: the desktop build and the game as Ruby are
    # each played by their own run with no window, as the tests play them.
    #
    # +only:+ records one of the console's voices alone (:square1, :square2, :wave, :noise), which is
    # how a wave is read: two voices added together have no one wave to follow.
    #
    # WHAT THE EAR HEARS THAT THE OTHER COMPARISONS DO NOT. A square voice is a wave going high and
    # low, the same length every time while it holds a note. The chip keeps its place in that wave
    # when a note is started again; a voice that goes back to the wave's start instead breaks one
    # wave each time, a little short or a little long. Once is nothing. Every frame — a voice whose
    # volume steps a frame at a time is started again every frame — is a buzz sixty times a second
    # under the tone, a rumble. #frames counts those broken waves; the loudness, pitch and tone the
    # desktop build is held to (test/sound_comparison.rb) are read only where a note is held still,
    # so they never see one.
    class SoundRecording
      # What the emulator hands its sound over at.
      CARTRIDGE_RATE = 44_100

      # The console's count of its voices, by the emulator's names for them.
      VOICES = { square1: 1, square2: 2, wave: 3, noise: 4 }.freeze

      # A wave this much longer or shorter than the frame's usual one is broken.
      BROKEN_SHARE = 0.2

      # One of the console's frames, heard: from the lowest sample to the highest (+loudness+), the
      # sample furthest from nought (+loudest+), the biggest step from one sample to the next
      # (+biggest_jump+, where a click shows: a jump far bigger than the tone's own edges), and how
      # many of the waves that ended in it were broken.
      Frame = Data.define(:loudness, :loudest, :biggest_jump, :waves_broken)

      attr_reader :samples, :rate, :frame_seconds

      def initialize(samples:, rate:, frame_seconds:)
        @samples = samples
        @rate = rate
        @frame_seconds = frame_seconds.to_r
      end

      # +program+ played for +frames+ frames on +on+ — :cartridge, the cartridge of the console it is
      # built for, or one of the runtimes written again from the native one (:native, :js, :ruby) —
      # with +buttons+ (a frame number, from 1, to the buttons held through it), heard from the
      # speaker on +side+, :left or :right.
      def self.of(program, on:, frames:, buttons: {}, only: nil, side: :left)
        refuse_unknown_side!(side)
        frame_seconds = program.described_console.frame_seconds
        if on == :cartridge
          return new(samples: cartridge_samples(program, frames, buttons, only, side), rate: CARTRIDGE_RATE,
                     frame_seconds: frame_seconds)
        end

        run = RUNTIMES.fetch(on) do
          raise ArgumentError, "on: must be :cartridge, #{RUNTIMES.keys.map(&:inspect).join(', ')}, not #{on.inspect}"
        end
        new(samples: runtime_samples(IR::Backends.const_get(run)::HeadlessRun.new, program, frames, buttons, only, side),
            rate: IR::Backends::Native::HeadlessRun::SOUND_RATE, frame_seconds: frame_seconds)
      end

      def self.refuse_unknown_side!(side)
        return if %i[left right].include?(side)

        raise ArgumentError, "side: is #{side.inspect}. A recording is of one speaker. To fix this, give " \
                             "`side: :left` or `side: :right`."
      end
      private_class_method :refuse_unknown_side!

      # The lowering whose run with no window plays each runtime, by the name +of+ takes. Named,
      # and looked up when asked, since the lowerings load after the readers (and a test in a
      # Ractor can read a table of names, where it cannot call a block a constant holds).
      RUNTIMES = Ractor.make_shareable({ native: :Native, js: :JS, ruby: :Ruby })

      # A .wav file of one speaker's sixteen-bit samples.
      def self.read_wav(path, frame_seconds:)
        bytes = File.binread(path)
        rate = bytes[24, 4].unpack1("V")
        at = bytes.index("data") or raise ArgumentError, "#{path} has no sound in it"
        size = bytes[at + 4, 4].unpack1("V")
        new(samples: bytes[at + 8, size].unpack("s<*"), rate: rate, frame_seconds: frame_seconds)
      end

      # The recording as a .wav file a person can open and listen to.
      def write_wav(path)
        data = samples.map { |sample| sample.round.clamp(-32_768, 32_767) }.pack("s<*")
        header = ["RIFF", 36 + data.bytesize, "WAVE", "fmt ", 16, 1, 1, rate, rate * 2, 2, 16, "data", data.bytesize]
        File.binwrite(path, header.pack("a4Va4a4VvvVVvva4V") + data)
        path
      end

      # Where +other+ first differs from this recording, as a sample's number, or nil when every
      # sample is the same and so is how many there are. Two recordings made at different rates
      # are different throughout, so they are refused.
      def first_difference(other)
        raise ArgumentError, "a recording at #{other.rate} a second cannot be compared with one at #{rate}" if other.rate != rate

        samples.each_index.find { |at| samples[at] != other.samples[at] } ||
          (samples.length == other.samples.length ? nil : [samples.length, other.samples.length].min)
      end

      # Each of the console's frames the recording covers, heard.
      def frames
        edges = rising_edges
        (0...frame_count).map do |index|
          first, last = frame_start(index), frame_start(index + 1)
          heard = samples[first...last]
          Frame.new(loudness: heard.empty? ? 0 : heard.max - heard.min, loudest: heard.map(&:abs).max || 0,
                    biggest_jump: biggest_jump(first, last), waves_broken: count_broken_waves(edges, first, last))
        end
      end

      private

      def frame_count = (samples.length / (rate * frame_seconds)).floor
      def frame_start(index) = (index * rate * frame_seconds).floor

      # Where the wave goes from below its middle to above it, sample by sample. The middle is the
      # frame's own, halfway between its lowest and highest, since a recording from the emulator
      # sinks slowly back toward nought and is not centred on it.
      def rising_edges
        (0...frame_count).flat_map do |index|
          first, last = frame_start(index), frame_start(index + 1)
          low, high = samples[first...last].minmax
          next [] if low.nil? || low == high

          middle = (low + high) / 2.0
          (first...last).select { |at| at.positive? && samples[at - 1] < middle && samples[at] >= middle }
        end
      end

      # The biggest step between two samples in a frame, counting the step into its first sample
      # from the frame before, since a click at a frame's start is one too.
      def biggest_jump(first, last)
        ([first, 1].max...last).map { |at| (samples[at] - samples[at - 1]).abs }.max || 0
      end

      # The waves that end in a frame, each from one rising edge to the next, set against the
      # frame's usual one: those much longer or shorter are broken.
      def count_broken_waves(edges, first, last)
        lengths = edges.each_cons(2).select { |_, ended| ended >= first && ended < last }.map { |began, ended| ended - began }
        return 0 if lengths.length < 3

        usual = lengths.sort[lengths.length / 2]
        lengths.count { |length| (length - usual).abs > usual * BROKEN_SHARE }
      end

      class << self
        private

        # The emulator hands both speakers over a moment at a time, the left's first.
        def cartridge_samples(program, frames, buttons, only, side)
          Emulator.load!
          keys = ->(frame) { IR::Buttons.mask(buttons.fetch(frame + 1, [])) }
          cartridge = Console.for(program.described_console.name).builder.cartridge_for(program, title: "HEARD")
          verifier = Verifier.new(cartridge, frames: 0, keys: keys)
          verifier.hearing(only: only) if only
          verifier.step(frames)
          verifier.audio_samples.each_slice(2).map { |left, right| side == :left ? left : right }
        end

        def runtime_samples(run, program, frames, buttons, only, side)
          run.recording_sound(only: only && VOICES.fetch(only))
          played = run.input_each_frame { |frame| buttons.fetch(frame, []) }.run(program, frames: frames)
          side == :left ? played.sound : played.sound_right
        end
      end
    end
  end
end
