# frozen_string_literal: true

module RubyGBA
  # A handle to a sampled sound — a recorded clip played back through the sampled-audio
  # hardware, rather than a tone synthesized on a PSG voice. `sample :boom, pcm: […]`
  # hands one back. See Builder#sample.
  #
  #   boom = sample :boom, pcm: [0, 80, 120, 80, 0, -80, -120, -80], rate: 8000
  #   pressed(:a).then { boom.play }
  #
  # The framework manages the hardware behind it — the sound FIFO, the DMA that feeds it,
  # and the timer that clocks the playback rate — so playing a real recorded sound is
  # just `boom.play`.
  class Sample
    # Built by Builder#sample, which embeds the sound data.
    def initialize(builder, name)
      @builder = builder
      @name = name
    end

    # @return [Symbol] the sample's name
    attr_reader :name

    # Play the sample once, from the start. Returns self so it chains.
    def play
      @builder.record_statement(IR::Build.play_sample(@name))
      self
    end

    # Stop the sampled-audio channel (cut off whatever is playing). Returns self.
    def stop
      @builder.record_statement(IR::Build.stop_sample)
      self
    end
  end
end
