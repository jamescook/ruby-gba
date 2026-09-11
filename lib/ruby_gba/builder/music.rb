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
      def stop_music
        record(Build.stop_music)
      end
    end
  end
end
