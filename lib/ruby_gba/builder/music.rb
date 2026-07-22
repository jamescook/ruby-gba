# frozen_string_literal: true

module RubyGBA
  class Builder
    # The music verbs: define a tune with the note/rest DSL, advance it a frame at
    # a time, and silence it. Songs play on channel 1 (with sweep) so they don't
    # clash with beep/SFX on channel 2; they share the @sound_enabled flag with
    # {Sound}.
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
        raise ArgumentError, "song :#{name} already defined" if @songs.key?(name)

        # Fully qualified: RubyGBA::Music is the note/tempo DSL the block is written
        # in — a bare `Music` here would mean this Builder::Music concern instead.
        ctx = RubyGBA::Music::SongContext.new
        ctx.instance_eval(&block)
        @songs[name] = ctx

        # In the IR a song carries its already-resolved score (frame/frequency
        # pairs) and length, so every backend replays the same tune.
        record(Build.song(name, events: ctx.events, total_frames: ctx.total_frames,
                                duty: ctx.duty, volume: ctx.volume))
      end

      # Advance a previously defined song by one frame. Call once per frame inside
      # the game loop. Uses channel 1 (square wave with sweep) so it doesn't
      # conflict with channel 2 beep/SFX sounds.
      #
      # @param name [Symbol] song name (defined with `song`)
      #
      # @example
      #   play_song :gameplay
      def play_song(name)
        raise ArgumentError, "call enable_sound before play_song" unless @sound_enabled
        unless @songs.key?(name)
          raise ArgumentError, "unknown song :#{name}. Define it with `song :#{name} do ... end`"
        end

        record(Build.play_song(name))
      end

      # Silence the music channel (channel 1).
      # Call this when transitioning to a scene that shouldn't have music.
      def stop_music
        record(Build.stop_music)
      end
    end
  end
end
