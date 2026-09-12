# frozen_string_literal: true

module RubyGBA
  # HOW MANY SOUNDS DID NOT PLAY? Counted, on a real run.
  #
  # THE FOOTGUN THIS IS ABOUT. `play` on a sample fills one of the mixer's voices. With every
  # voice already busy the play is DROPPED — on purpose, because the alternative is cutting off
  # a sound that is already sounding, which is worse and is never what anybody meant. So the
  # game carries on, correct in every other way, one sound quieter than the author wrote. There
  # is no error, nothing on screen, and nothing in the build: whether it happens depends
  # entirely on play — a burst of explosions, a chord of music underneath them — so a build
  # that has never run the game cannot know. This puts the number in front of somebody.
  #
  # WHY THE SPLIT IS THE INTERESTING HALF. A drop means every voice was busy, so counting how
  # many were sounding says nothing: it is all of them, every time. What the author cannot know
  # without measuring is WHOSE they were. The music and the game's sounds share the voices, each
  # taking one only while it sounds, and a song with many recorded parts can be holding most of
  # them at the moment an explosion asks for one. That is a decision the author can revisit — a
  # part moved onto the square wave, a shorter chord, fewer sounds at once — and the number is
  # the only way to see it.
  #
  # == WHY THIS REPORTS A NUMBER AND DOES NOT WARN ==
  #
  # Because a dropped sound is not necessarily a fault. A game that fires twenty shots in one
  # frame and hears sixteen of them sounds right; the four it dropped were going to be inaudible
  # under the sixteen. Whether the loss matters is a question about the game's sound, and
  # nothing in a count can answer it. So the count is reported and the judgement is left where
  # it belongs. What is said alongside it is the SPLIT, because that is the fact the author
  # cannot get any other way.
  module SoundDrops
    # WHAT A RUN SAW. +dropped+ is how many plays found no free voice, +music_held+ the most
    # voices a song held at one of those moments, +voices+ how many there are in all. A run
    # that could not be read says so with #measured? false, so "we could not tell" never reads
    # as "nothing was wrong".
    Reading = Data.define(:dropped, :music_held, :voices) do
      def self.unmeasured = new(dropped: nil, music_held: nil, voices: nil)

      def measured? = !dropped.nil?

      # Worth putting in front of somebody: a sound the author asked for did not play.
      def any? = measured? && dropped.positive?

      # How many of the voices the game's own sounds had at the worst moment — the other side
      # of the split, worked out rather than counted, since a drop means every voice was busy.
      def game_held = any? ? voices - music_held : 0
    end
  end
end
