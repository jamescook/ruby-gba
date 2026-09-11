# frozen_string_literal: true

module RubyGBA
  module IR
    # WHICH TUNES A PROGRAM PLAYS, and what they take from the mixer — worked out here, once,
    # for every backend.
    #
    # It lives in one place because the answer is a promise the backends make to each other. A
    # song part that plays a recording keeps a voice of the mixer for itself, and the game's own
    # sounds get the voices that are left. Counted two ways, the interpreter would keep a sound
    # the console drops, and only in the one busy moment that fills the mixer.
    module Tunes
      module_function

      # The songs the program can play, in the order they are declared: every song it names with
      # `play_song`, and every song in a list it picks from by number. A song that is written and
      # never played takes nothing.
      def played(program)
        names = program.walk.filter_map { |node| node.name if node.kind == :play_song }
        names += lists_played(program).values.flatten
        program.walk.select { |node| node.kind == :song && names.include?(node.name) }
      end

      # Each song list the program picks from by number, with its songs in order.
      def lists_played(program)
        picked = program.walk.filter_map { |node| node.name if node.kind == :play_from_list }.uniq
        program.walk.select { |node| node.kind == :song_list && picked.include?(node.name) }
               .to_h { |node| [node.name, node.songs] }
      end

      # Every instrument a song names — for its parts, and for any note that names its own.
      def instruments(song)
        song.voices.flat_map do |part|
          [part[:instrument], *part[:events].map { |event| event[2] }]
        end.compact.uniq
      end

      # How many of a song's parts play a recording rather than a square wave.
      def recorded_parts(song)
        song.voices.count { |part| part[:instrument] }
      end

      # The most recorded parts any one played tune has.
      def most_recorded_parts(program)
        played(program).map { |song| recorded_parts(song) }.max || 0
      end

      # How many of the mixer's voices the music keeps: as many as the most any one played tune
      # has recorded parts, since one tune plays at a time. More than the mixer has cannot be
      # kept by any backend, so none of them is asked to — the build refuses such a song first
      # (Guardrails::Checks::SongTooManyParts), and this is only the backstop behind that.
      def mixer_voices(program)
        wanted = most_recorded_parts(program)
        return wanted if wanted <= Sound::MIXER_VOICES

        raise ArgumentError, "a song has #{wanted} parts that play a recording, and the mixer has " \
                             "#{Sound::MIXER_VOICES} voices"
      end

      # The played song with the most recorded parts — the one that decides how many voices the
      # music keeps — or nil when no played song has any.
      def keeps_the_most(program)
        played(program).select { |song| recorded_parts(song).positive? }.max_by { |song| recorded_parts(song) }
      end
    end
  end
end
