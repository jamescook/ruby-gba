# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Native
        # THE GAME'S SOUND, written as calls into runtime/rg_sound.h — mixed into Lowering the way
        # Picture is.
        #
        # What is played so far is what the interpreter's music player does with a song's parts
        # on the square-wave voices, and the beeps and `enable_sound` the game says itself: each
        # goes into the sound log a test reads, in the interpreter's words (see SoundLog). The
        # rest — the wave and noise voices, recordings, sound effect lists, a song picked from a
        # list by number — is refused by name (NOT_LOWERED_YET, and #refuse_unplayable_songs! for a
        # song with a part on another voice), rather than left out of what the game plays.
        module Sound
          private

          def prepare_sound
            @sound_log = SoundLog.new(@program)
          end

          def lower_enable_sound(_node) = [eval_call("rg_sound_enabled")]
          def lower_beep(node) = [eval_call("rg_sound_beep", C::Int.new(@sound_log.beep_number(node)))]
          def lower_play_song(node) = [eval_call("rg_music_request", C::Int.new(@sound_log.song_number(node.name)))]
          def lower_stop_music(_node) = [eval_call("rg_music_stop")]

          # A song the game plays with a part off the square-wave voices: the desktop build cannot
          # play that part yet, and playing the rest without it would be a different tune.
          def refuse_unplayable_songs!
            played = @reachable.filter_map { |node| node.name if node.kind == :play_song }
            @sound_log.songs.select { |song| played.include?(song.name) }.each do |song|
              other = song.voices.map { |part| Tunes.part_kind(part) }.find { |kind| kind != :square }
              next unless other

              raise LoweringError,
                    "song #{song.name.inspect} has a part on the #{other} voice, which the desktop build " \
                    "cannot play yet. It plays parts on the square wave. The cartridge build can play it."
            end
          end

          # The player reads the music volume the game keeps, when it keeps one: a game that never
          # says `music_volume` plays every part at its written volume with nothing worked out.
          def sound_power_on
            return [] unless variable_names.include?(Tunes::LEVEL)

            [eval_call("rg_music_follow_level", C::AddressOf.new(variable(Tunes::LEVEL)))]
          end

          # The music volume's rule and every song, as the runtime reads them (the layout is atop
          # runtime/rg_sound.c). The rule is written here, from IR::Tunes, rather than copied into
          # the C, so the two can never drift apart.
          def music_table
            songs = @sound_log.songs.map { |song| encoded_song(song) }
            header = [Tunes::FULL_LEVEL, Tunes::LEVEL_SHIFT, songs.size]
            starts = []
            at = header.size + songs.size # past the header and the starts themselves
            songs.each do |numbers|
              starts << at
              at += numbers.size
            end
            C::ConstArray.new(name: @names.own("music"), type: "int32_t",
                              values: [*header, *starts, *songs.flatten], exported: true)
          end

          # One song as numbers: its length, where it loops from, and each square-wave part's notes
          # the first time through and every time after. Every song the game declares is written,
          # played or not, so the numbering is the one SoundLog gives; a song nothing plays is
          # never refused for its voices, and only its square-wave parts are written.
          def encoded_song(song)
            squares = song.voices.zip(Tunes.loop_passes(song)).select { |part, _| Tunes.part_kind(part) == :square }
            [song.total_frames, Tunes.loop_frame(song), squares.size,
             *squares.flat_map do |part, pass|
               [pass.first.size, pass.again.size, *(pass.first + pass.again).flat_map { |at, pitch, _, volume| [at, pitch, volume || part.volume] }]
             end]
          end
        end
      end
    end
  end
end
