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

    # Play the sample from the start. By default it plays once; `loop: true` replays it
    # on a seamless loop — how you'd play a piece of background music that keeps going
    # until you `stop` it. Returns self so it chains.
    #
    #   music.play(loop: true)   # a looping background track
    #   boom.play                # a one-shot sound effect
    def play(loop: false)
      @builder.record_statement(IR::Build.play_sample(@name, loop: loop))
      self
    end

    # Stop this sample — cut off any of its voices that are still sounding. Returns self.
    def stop
      @builder.record_statement(IR::Build.stop_sample(@name))
      self
    end
  end
end
