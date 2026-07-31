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

    # How loud a voice sits in the mix — from full down to silent. These are the levels
    # `play(volume:)` accepts (the same words the other sound verbs use).
    VOLUME_LEVELS = %i[full three_quarter half quarter mute].freeze

    # Check a note name (a pitch to play at, or a sample's recorded note) is one the framework
    # knows, with a friendly error naming the range. Shared by `sample note:` and `play pitch:`.
    def self.validate_note!(note, label)
      return if RubyGBA::Music::NOTE_FREQUENCIES.key?(note)

      known = RubyGBA::Music::NOTE_FREQUENCIES.keys
      raise ArgumentError,
            "#{label} #{note.inspect} isn't a note — use one like :C4 or :Fs4 (range #{known.first}..#{known.last})"
    end

    # Play the sample from the start. By default it plays once at full volume; `loop: true`
    # replays it on a seamless loop (background music that keeps going until you `stop` it),
    # and `volume:` sets how loud this voice is in the mix (:full, :three_quarter, :half,
    # :quarter, :mute). Returns self so it chains.
    #
    #   music.play(loop: true, volume: :half)  # a quiet looping background track
    #   piano.play(pitch: :E4)                  # the recorded note, shifted to E4
    #   boom.play                               # a one-shot effect at full volume
    #
    # `pitch:` plays the sample at a different note by reading through it faster or slower
    # (so one recorded note covers a whole keyboard); it shifts from the sample's own `note:`.
    def play(loop: false, volume: :full, pitch: nil)
      unless VOLUME_LEVELS.include?(volume)
        raise ArgumentError,
              "play volume #{volume.inspect} isn't a level — use one of #{VOLUME_LEVELS.join(', ')}"
      end
      Sample.validate_note!(pitch, "play pitch:") if pitch

      @builder.record_statement(IR::Build.play_sample(@name, loop: loop, volume: volume, pitch: pitch))
      self
    end

    # Stop this sample — cut off any of its voices that are still sounding. Returns self.
    def stop
      @builder.record_statement(IR::Build.stop_sample(@name))
      self
    end
  end
end
