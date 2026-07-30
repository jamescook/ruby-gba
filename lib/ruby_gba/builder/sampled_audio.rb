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

      # Define a named PCM sample. +pcm+ is the sound as 8-bit signed samples (an Array of
      # -128..127, or a binary String); +rate+ is how many of them play per second.
      #
      #   sfx = sample :zap, pcm: [0, 100, 0, -100] * 20, rate: 8000
      #
      # Returns a {Sample} handle — `play` it, `stop` it.
      #
      # @param name [Symbol] the sample's name
      # @param pcm [Array<Integer>, String] the 8-bit signed PCM samples
      # @param rate [Integer] samples per second (its recording rate)
      # @return [Sample]
      def sample(name, pcm:, rate: DEFAULT_SAMPLE_RATE)
        raise ArgumentError, "a sample needs a name (a Symbol), got #{name.inspect}" unless name.is_a?(Symbol)
        unless rate.is_a?(Integer) && rate.positive?
          raise ArgumentError, "sample :#{name} needs a positive rate (samples a second), got #{rate.inspect}"
        end

        record(IR::Build.sample(name, pack_pcm(name, pcm), rate))
        Sample.new(self, name)
      end

      private

      # Pack the PCM into 8-bit signed bytes, whether it came as a byte string or an
      # array of sample values — with a friendly error for an out-of-range value.
      def pack_pcm(name, pcm)
        case pcm
        when String then pcm.b
        when Array
          bad = pcm.find { |s| !s.is_a?(Integer) || !s.between?(-128, 127) }
          raise ArgumentError, "sample :#{name} has a bad PCM value #{bad.inspect} — each must be -128..127" if bad
          raise ArgumentError, "sample :#{name} has no PCM data" if pcm.empty?

          pcm.pack("c*")
        else
          raise ArgumentError, "sample :#{name} pcm: must be an Array of -128..127 or a byte String, got #{pcm.class}"
        end
      end
    end
  end
end
