# frozen_string_literal: true

module RubyGBA
  module IR
    # HOW A PROGRAM'S RECORDINGS ARE ADDED TOGETHER INTO ONE STREAM OF SOUND — the questions
    # about it every backend that mixes asks, answered here once, so two of them mixing the same
    # program make the same bytes. (The numbers the mix is done in are Audio::Sound's.)
    module Mixing
      module_function

      # Does the program mix anything? It does when it plays a recording itself, or plays a tune
      # or a sound effect with a part on a recording. One that only declares a recording has
      # nothing to mix.
      def mixes?(program)
        program.walk.any? { |node| node.kind == :play_sample } ||
          Tunes.playable_songs(program).any? { |song| Tunes.recorded_parts(song).positive? }
      end

      # DOES ANYTHING IN THIS PROGRAM SHAPE A NOTE? Asked once, of the whole program, because the
      # answer decides what the mix reads for EVERY voice: a voice's GAIN, which a shape moves,
      # in a program that shapes something, and its loudness as it stands in one that shapes
      # nothing. Three places can say so: a recording declared with one, a part of a played tune
      # or a sound effect, or one of that part's notes. A tune nobody plays says nothing.
      def shapes_any_note?(program)
        program.walk.any? { |node| node.kind == :sample && node.envelope } ||
          Tunes.playable_songs(program).any? do |song|
            Tunes.soundings(song).any? { |sounding| sounding.envelope }
          end
      end

      # The rate the mix is asked to run at: the rate most of the program's recordings were made
      # at, so a game that records at one rate plays at its own pitch. What it really runs at is
      # the nearest a backend's clock can keep.
      def requested_rate(program)
        rates = program.walk.select { |n| n.kind == :sample }.map(&:rate)
        return RubyGBA::Builder::SampledAudio::DEFAULT_SAMPLE_RATE if rates.empty?

        rates.group_by(&:itself).max_by { |_rate, list| list.size }.first
      end

      # THE STEP that sounds recording +sample+ at +frequency+ Hz in a mix running at +mix_rate+:
      # how many samples of the recording go by for each sample of the mix, in 65536ths (see
      # Sound::STEP_SHIFT). It rolls the recording's own rate against the mix's, so a recording
      # made at another rate still sounds at its pitch, and the note against the one it was
      # recorded at. At least one, so a voice never stands still. The same sum for a note a game
      # plays and one a song plays, so the two are in tune with each other.
      def step(sample, frequency, mix_rate)
        ratio = frequency.to_f / RubyGBA::Audio::Music::NOTE_FREQUENCIES.fetch(sample.note || :C4)
        step = (sample.rate.to_f / mix_rate) * ratio
        [(step * (1 << RubyGBA::Audio::Sound::STEP_SHIFT)).round, 1].max
      end

      # ONE SAMPLE'S SHARE OF A FRAME, out of 1 << (2 * Sound::RAMP_SPLIT): what a shaped note's
      # distance to its next gain is multiplied by to slide it there over +samples_a_frame+
      # samples. A multiply by a number worked out ahead of time, rather than a divide each
      # frame.
      def slide_share(samples_a_frame) = (1 << (2 * RubyGBA::Audio::Sound::RAMP_SPLIT)) / samples_a_frame
    end
  end
end
