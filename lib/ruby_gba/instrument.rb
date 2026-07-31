# frozen_string_literal: true

module RubyGBA
  # A playable instrument built from one recorded sample — a piano, a synth pad, whatever you
  # sampled. You play *notes* on it, and the framework covers the whole keyboard from that one
  # recording by reading it faster or slower for higher or lower notes. Several notes sound at
  # once, so you can play chords. `instrument :piano, from: "piano_c4.wav"` hands one back.
  #
  #   piano = instrument :piano, from: "piano_c4.wav", note: :C4
  #   piano.play(:E4)                 # a single note
  #   piano.play(:C4, :E4, :G4)       # ...or a chord — all three sound together
  #   pressed(:a).then { piano.play(:C4) }   # play it live from a button
  #
  # It's a thin layer over a {Sample}: each note becomes a pitched voice in the mixer, shifted
  # from the sample's own recorded note. No voices, rates, or mixer detail to think about —
  # just notes.
  class Instrument
    # Built by Builder#instrument, wrapping the sample it plays.
    def initialize(builder, sample)
      @builder = builder
      @sample = sample
    end

    # @return [Symbol] the instrument's (and its sample's) name
    def name
      @sample.name
    end

    # Play one or more notes at once — one note is a single tone, several make a chord. Each
    # note is a voice in the mix, so they sound together rather than cutting each other off.
    # `volume:` sets how loud they play (:full, :three_quarter, :half, :quarter, :mute).
    # Returns self so it chains.
    def play(*notes, volume: :full)
      raise ArgumentError, "play a note — e.g. #{name}.play(:C4)" if notes.empty?

      notes.each { |note| @sample.play(pitch: note, volume: volume) }
      self
    end

    # Silence this instrument — stop any of its notes still sounding. Returns self.
    def stop
      @sample.stop
      self
    end
  end
end
