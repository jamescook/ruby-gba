# frozen_string_literal: true

module RubyGBA
  class Builder
    # The music verbs: define a tune with the note/rest DSL, name the one playing,
    # and silence it. Songs play on channel 1 (with sweep) so they don't clash with
    # beep/SFX on channel 2; they share the @sound_enabled flag with {Sound}.
    #
    # A concern of {Builder}, mixed in so song/play_song/stop_music are flat DSL
    # verbs. Note this is Builder::Music (the verbs) — distinct from RubyGBA::Music
    # (the note/tempo notation the `song` block is written in).
    module Music
      # Define a named song using the note/rest DSL.
      # Songs are collected at build time and played by play_song.
      #
      # @param name [Symbol] song name
      #
      # @example
      #   song :gameplay do
      #     tempo 140
      #     note :C4, :eighth
      #     note :E4, :eighth
      #     note :G4, :quarter
      #     rest :quarter
      #   end
      def song(name, &block)
        raise ArgumentError, "The song :#{name} is already defined. Use a different name." if @songs.key?(name)

        # Fully qualified: RubyGBA::Music is the note/tempo DSL the block is written
        # in — a bare `Music` here would mean this Builder::Music concern instead.
        ctx = RubyGBA::Music::SongContext.new
        ctx.instance_eval(&block)
        @songs[name] = ctx

        # In the IR a song carries its already-resolved score — one or more parts
        # (each a list of frame/frequency pairs, with its own tone and volume) and
        # the song's length — so every backend replays the same tune.
        record(Build.song(name, voices: ctx.voices, total_frames: ctx.total_frames))
      end

      # Say which song is playing now. It plays from its start, loops, and keeps the
      # tempo it was written at whatever the game is doing — the framework moves it on
      # once for every frame the screen shows, so a game too heavy for a frame still
      # hears it at the right speed.
      #
      # Saying the song already playing changes nothing, so this can be written once
      # or every frame, from a branch or a scene. Naming a different song starts that
      # one from its beginning, and `stop_music` silences it.
      #
      # @param name [Symbol] song name (defined with `song`)
      #
      # @example
      #   play_song :gameplay
      def play_song(name)
        raise ArgumentError, "Sound is off. Call enable_sound before play_song." unless @sound_enabled
        unless @songs.key?(name)
          raise ArgumentError, "The song :#{name} is not defined. Define it with `song :#{name} do ... end`."
        end

        record(Build.play_song(name))
      end

      # No song is playing now. Like `play_song`, it can be said every frame: the
      # song goes quiet once, and saying it again while nothing plays does nothing.
      # Said in the same frame as naming a song, it starts that song over from its
      # first note — `stop_music; play_song :title` is how a tune restarts.
      def stop_music
        record(Build.stop_music)
      end

      # HAND OVER MUSIC AS DATA, and play it by number.
      #
      #   music = songs :music, [title_theme, file_select, forest]   # RubyGBA::Score each
      #   music.play 2            # the forest
      #   music.play track        # ...or whichever one a number the game holds says
      #
      # For a game whose music already exists as numbers — decoded from another cartridge,
      # read from a file — rather than written as `song` blocks. A Hash names them instead:
      # `songs :music, { title: TITLE, forest: FOREST }`, then `music.play :forest`. Returns a
      # {RubyGBA::SongList}.
      def songs(name, scores)
        if @songs.key?(name) || @song_lists.key?(name)
          raise ArgumentError, "There is already a song named :#{name}. Use a different name."
        end

        entries = score_entries(name, scores)
        members = entries.map do |key, score|
          unless score.is_a?(RubyGBA::Score)
            raise ArgumentError, "Song #{key.inspect} of :#{name} is #{score.inspect}, which is not a " \
                                 "RubyGBA::Score. Give `songs` a list of Scores, or a Hash of them by name."
          end

          member = :"#{name}.#{key}"
          song = score.to_song
          @songs[member] = score
          record(Build.song(member, voices: song[:voices], total_frames: song[:total_frames]))
          member
        end
        @song_lists[name] = members
        record(Build.song_list(name, members))
        RubyGBA::SongList.new(self, name, entries.map(&:first))
      end

      # The hook behind SongList#play: record that the tune playing now is number +which+ of
      # the list — a number already checked against the list when it was written, or a Value.
      def play_from_list(name, which)
        raise ArgumentError, "Sound is off. Call enable_sound before playing :#{name}." unless @sound_enabled

        record(Build.play_from_list(name, which: Value.node_for(which)))
      end

      private

      def score_entries(name, scores)
        entries =
          case scores
          when Hash then scores.to_a
          when Array then scores.each_with_index.map { |score, number| [number, score] }
          else
            raise ArgumentError, "songs :#{name} takes a list of Scores, or a Hash of them by name. " \
                                 "You gave #{scores.class}."
          end
        raise ArgumentError, "songs :#{name} needs at least one Score." if entries.empty?

        entries
      end
    end
  end
end
