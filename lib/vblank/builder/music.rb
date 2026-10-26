# frozen_string_literal: true

module VBlank
  class Builder
    # The music verbs: define a tune with the note/rest DSL, name the one playing,
    # and silence it. Songs play on channel 1 (with sweep) so they don't clash with
    # beep/SFX on channel 2; they share the @sound_enabled flag with {Sound}.
    #
    # A concern of {Builder}, mixed in so song/play_song/stop_music are flat DSL
    # verbs. Note this is Builder::Music (the verbs) — distinct from VBlank::Audio::Music
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

        # Fully qualified: VBlank::Audio::Music is the note/tempo DSL the block is written
        # in — a bare `Music` here would mean this Builder::Music concern instead.
        ctx = VBlank::Audio::Music::SongContext.new
        ctx.instance_eval(&block)
        @songs[name] = ctx

        # In the IR a song carries its already-resolved score — one or more parts
        # (each a list of frame/frequency pairs, with its own tone and volume), the
        # song's length, and where it loops from — so every backend replays the same tune.
        record(Build.song(name, voices: ctx.voices, total_frames: ctx.total_frames, loop_frame: ctx.loop_frame))
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
      # A song named here starts on the NEXT frame: the player runs as the screen finishes a
      # picture, which is before the game's pass, so it hears the name a frame on. That is a
      # frame later than a cartridge whose sound engine runs after its game's logic, and a game
      # rebuilt to match one says `this_frame: true` — the song is then taken up and its first
      # frame played right here, and the next frame plays its second.
      #
      # @param name [Symbol] song name (defined with `song`)
      # @param this_frame [Boolean] start it here rather than on the next frame
      #
      # @example
      #   play_song :gameplay
      def play_song(name, this_frame: false)
        raise ArgumentError, "Sound is off. Call enable_sound before play_song." unless @sound_enabled
        unless @songs.key?(name)
          raise ArgumentError, "The song :#{name} is not defined. Define it with `song :#{name} do ... end`."
        end

        refuse_unknown_this_frame!(this_frame)
        record(Build.play_song(name, this_frame: this_frame))
      end

      # No song is playing now. Like `play_song`, it can be said every frame: the
      # song goes quiet once, and saying it again while nothing plays does nothing.
      # Said in the same frame as naming a song, it starts that song over from its
      # first note — `stop_music; play_song :title` is how a tune restarts.
      def stop_music
        record(Build.stop_music)
      end

      # HOW LOUD THE MUSIC PLAYS, from 0 (silent) to 100 (as written). It reaches the song
      # playing now, notes already sounding included, from the next frame — and every song
      # after it, until it is said again. Sound effects are not the music, and keep their own
      # volume.
      #
      #   music_volume 50          # half as loud
      #   music_volume slider      # whatever a settings screen holds
      #
      # `fade_music_out` walks it down to silence over time, and this is what it moves.
      #
      # WITH NO NUMBER IT READS how loud the music is now, 0 to 100 — which is how a game waits
      # for a fade to finish before it switches songs, so the switch is never heard:
      #
      #   (music_volume == 0).then { track.set! next_track; fade_music_in }
      #
      # @param amount [Integer, Value, nil] 0..100; anything outside that is held at the nearer
      #   end. Leave it out to read the volume instead.
      # @return [Value, nil] the volume now, when reading
      def music_volume(amount = nil)
        level = value_handle_for(IR::Tunes::LEVEL)
        unless @music_level_declared
          var IR::Tunes::LEVEL, IR::Tunes::FULL_LEVEL
          @music_level_declared = true
        end
        full = IR::Tunes::FULL_LEVEL
        return level * 100 / full if amount.nil?

        if amount.is_a?(Integer)
          level.set! amount.clamp(0, 100) * full / 100
        else
          # Worked out, held in range, and only then stored: the player reads the level from the
          # screen's interrupt, which can land between any two statements, and a level stored
          # before it was held in range would sound for a frame at whatever came out.
          wanted = value_handle_for(:__music_level_wanted)
          wanted.set! amount * full / 100
          wanted.clamp! 0, full
          level.set! wanted
        end
        nil
      end

      # HAND OVER MUSIC AS DATA, and play it by number.
      #
      #   music = songs :music, [title_theme, file_select, forest]   # VBlank::Audio::Score each
      #   music.play 2            # the forest
      #   music.play track        # ...or whichever one a number the game holds says
      #
      # For a game whose music already exists as numbers — decoded from another cartridge,
      # read from a file — rather than written as `song` blocks. A Hash names them instead:
      # `songs :music, { title: TITLE, forest: FOREST }`, then `music.play :forest`. Returns a
      # {VBlank::DSL::SongList}.
      def songs(name, scores)
        keys, members = record_scores(name: name, scores: scores, verb: :songs, entry: "Song") do |key, score|
          next unless score.group

          raise ArgumentError, "Song #{key.inspect} of :#{name} has `group:`. A group says which sound effects " \
                               "play one at a time. Songs already play one at a time. Remove `group:` " \
                               "from this Score."
        end
        record(Build.song_list(name, members))
        VBlank::DSL::SongList.new(self, name, keys)
      end

      # SOUNDS HANDED OVER AS DATA, each played ONCE over the song that is playing.
      #
      #   sfx = sound_effects :sfx, { hit: HIT, spark: SPARK }   # VBlank::Audio::Score each
      #   sfx.play :hit
      #   sfx.play which          # ...or whichever one a number the game holds says
      #
      # A sword hit, a door, a chest: short runs of notes the way a tune is, decoded from the same
      # place. Asked for again while it is still sounding, one starts again from its first note.
      # When an effect and the song, or two effects, want the same voice at once, the Score with
      # the higher `priority:` sounds on it. Returns a {VBlank::DSL::SoundEffectList}.
      def sound_effects(name, scores)
        keys, members = record_scores(name: name, scores: scores, verb: :sound_effects,
                                      entry: "Sound effect") do |key, score|
          refuse_looping_sound_effect!(effect: "Sound effect #{key.inspect} of :#{name}", score: score)
        end
        record(Build.sound_effect_list(name, members))
        VBlank::DSL::SoundEffectList.new(self, name, keys)
      end

      # The hook behind SoundEffectList#play: record that effect number +which+ of the list starts
      # now — a number already checked against the list when it was written, or a Value.
      def play_sound_effect(name, which, this_frame: false)
        raise ArgumentError, "Sound is off. Call enable_sound before playing :#{name}." unless @sound_enabled

        refuse_unknown_this_frame!(this_frame)
        record(Build.play_sound_effect(name, which: DSL::Value.node_for(which), this_frame: this_frame))
      end

      # The hook behind SongList#play: record that the tune playing now is number +which+ of
      # the list — a number already checked against the list when it was written, or a Value.
      def play_from_list(name, which, this_frame: false)
        raise ArgumentError, "Sound is off. Call enable_sound before playing :#{name}." unless @sound_enabled

        refuse_unknown_this_frame!(this_frame)
        record(Build.play_from_list(name, which: DSL::Value.node_for(which), this_frame: this_frame))
      end

      private

      def refuse_unknown_this_frame!(this_frame)
        return if [true, false].include?(this_frame)

        raise ArgumentError, "`this_frame:` is #{this_frame.inspect}. It must be true or false."
      end

      # A list of Scores handed to `songs` or `sound_effects` (+verb+), each one recorded as a song
      # node named for its place in the list. +entry+ is what one of them is called, for the
      # errors, and the block, when given, is handed each Score to refuse before it is recorded.
      # Returns the keys the list was given, and the names of the songs recorded.
      def record_scores(name:, scores:, verb:, entry:)
        if @songs.key?(name) || @song_lists.key?(name)
          raise ArgumentError, "There is already a song named :#{name}. Use a different name."
        end

        entries = score_entries(name: name, scores: scores, verb: verb)
        members = entries.map do |key, score|
          unless score.is_a?(VBlank::Audio::Score)
            raise ArgumentError, "#{entry} #{key.inspect} of :#{name} is #{score.inspect}, which is not a " \
                                 "VBlank::Audio::Score. Give `#{verb}` a list of Scores, or a Hash of them by name."
          end

          yield key, score if block_given?
          record_score(member: :"#{name}.#{key}", score: score)
        end
        @song_lists[name] = members
        [entries.map(&:first), members]
      end

      def record_score(member:, score:)
        @songs[member] = score
        record(Build.song(member, **score.to_song))
        member
      end

      # Refuse a Score a sound effect cannot play. An effect plays every voice a song does, sharing
      # each with the song by priority, but it plays once, so it has no loop. How many parts it may
      # have on each is checked with a song's, on the finished program
      # (Guardrails::Checks::SongTooManyParts).
      def refuse_looping_sound_effect!(effect:, score:)
        return unless score.loop_from

        raise ArgumentError, "#{effect} has `loop_from:`. A sound effect plays one time, and does not " \
                             "loop. Remove `loop_from:` from this Score."
      end

      def score_entries(name:, scores:, verb:)
        entries =
          case scores
          when Hash then scores.to_a
          when Array then scores.each_with_index.map { |score, number| [number, score] }
          else
            raise ArgumentError, "#{verb} :#{name} takes a list of Scores, or a Hash of them by name. " \
                                 "You gave #{scores.class}."
          end
        raise ArgumentError, "#{verb} :#{name} needs at least one Score." if entries.empty?

        entries
      end
    end
  end
end
