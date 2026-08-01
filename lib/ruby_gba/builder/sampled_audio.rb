# frozen_string_literal: true

module RubyGBA
  class Builder
    # The sampled-audio verb: `sample` — define a recorded sound (8-bit PCM) and hand
    # back a {Sample} handle to play and stop it. A concern of {Builder}, mixed in so
    # `sample` stays a flat DSL verb.
    module SampledAudio
      # A sensible default rate for a hand-authored clip — how many samples play per
      # second when the caller doesn't say.
      DEFAULT_SAMPLE_RATE = 8192

      # Define a named PCM sample, either from a `.wav` file or from raw samples:
      #
      #   sfx  = sample :zap,  from: "zap.wav"                    # a recorded clip (found beside your script)
      #   tone = sample :tone, pcm: [0, 100, 0, -100] * 20, rate: 8000  # hand-authored samples
      #
      # With `from:`, the file's own sample rate is used (any 8-/16-bit, mono/stereo PCM
      # WAV is converted for you); pass `rate:` only to override it. With `pcm:`, give the
      # samples as an Array of -128..127 (or a binary String) and the `rate:` they play at.
      # Returns a {Sample} handle — `play` it, `stop` it.
      #
      # @param name [Symbol] the sample's name
      # @param pcm [Array<Integer>, String, nil] the 8-bit signed PCM samples (or use from:)
      # @param from [String, nil] a .wav file to load (or use pcm:)
      # @param rate [Integer, nil] samples per second — defaults to the WAV's rate, or 8192 for pcm:
      # @return [Sample]
      def sample(name, pcm: nil, from: nil, rate: nil, note: :C4)
        raise ArgumentError, "A sample name must be a Symbol. You gave #{name.inspect}." unless name.is_a?(Symbol)

        bytes, rate = sample_data(name, pcm, from, rate)
        unless rate.is_a?(Integer) && rate.positive?
          raise ArgumentError, "sample :#{name} must have a positive rate. The rate is how many samples play in one second. You gave #{rate.inspect}."
        end
        raise ArgumentError, "sample :#{name} has no sound data. The samples or the .wav file are empty." if bytes.empty?
        Sample.validate_note!(note, "sample :#{name} note:")

        record(IR::Build.sample(name, bytes, rate, note: note))
        Sample.new(self, name)
      end

      # Define a playable instrument from a recorded sample — the same `pcm:`/`from:`/`rate:`
      # as `sample`, plus the note it was recorded at (`note:`, default :C4). You play notes
      # on the returned {Instrument}, and one recording covers the whole keyboard:
      #
      #   piano = instrument :piano, from: "piano_c4.wav", note: :C4
      #   piano.play(:E4)             # a note
      #   piano.play(:C4, :E4, :G4)   # ...or a chord
      #
      # @return [Instrument]
      def instrument(name, pcm: nil, from: nil, rate: nil, note: :C4)
        Instrument.new(self, sample(name, pcm: pcm, from: from, rate: rate, note: note))
      end

      private

      # Resolve the sample's [bytes, rate] from whichever source was given — a WAV file
      # (its own rate, unless overridden) or raw pcm: samples — insisting on exactly one.
      def sample_data(name, pcm, from, rate)
        if from
          raise ArgumentError, "You gave both pcm: and from: to sample :#{name}. Give pcm: or from:, not both." if pcm

          loaded = Wav.load(resolve_asset_path(from))
          [loaded[:bytes], rate || loaded[:rate]]
        elsif pcm
          [pack_pcm(name, pcm), rate || DEFAULT_SAMPLE_RATE]
        else
          raise ArgumentError, "sample :#{name} needs sound data. Give pcm: (raw samples) or from: (a .wav file)."
        end
      end

      # Pack the PCM into 8-bit signed bytes, whether it came as a byte string or an
      # array of sample values — with a friendly error for an out-of-range value.
      def pack_pcm(name, pcm)
        case pcm
        when String then pcm.b
        when Array
          bad = pcm.find { |s| !s.is_a?(Integer) || !s.between?(-128, 127) }
          raise ArgumentError, "sample :#{name} has a bad PCM value #{bad.inspect}. Each value must be -128..127." if bad
          raise ArgumentError, "sample :#{name} has no PCM data. Give it one or more samples." if pcm.empty?

          pcm.pack("c*")
        else
          raise ArgumentError, "sample :#{name} pcm: must be an Array of -128..127 or a byte String. You gave #{pcm.class}."
        end
      end
    end
  end
end
