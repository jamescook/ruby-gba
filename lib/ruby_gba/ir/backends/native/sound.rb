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
        # list by number — is written as nothing for now: silent, and absent from the log, so a
        # test that reads it on a native run sees the difference rather than a guess.
        module Sound
          private

          def prepare_sound
            @sound_log = SoundLog.new(@program)
          end

          def lower_enable_sound(_node) = [eval_call("rg_sound_enabled")]
          def lower_beep(node) = [eval_call("rg_sound_beep", C::Int.new(@sound_log.beep_number(node)))]
          def lower_play_song(node) = [eval_call("rg_music_request", C::Int.new(@sound_log.song_number(node.name)))]
          def lower_stop_music(_node) = [eval_call("rg_music_stop")]

          # A sound statement not played yet, written as nothing (see the comment above).
          # (lower_nothing is for declarations, which run nowhere on any backend; this is for
          # statements that will one day be played here.)
          def lower_sound_unplayed(_node) = []

          # The player reads the music volume the game keeps, when it keeps one: a game that never
          # says `music_volume` plays every part at its written volume with nothing worked out.
          def sound_power_on
            return [] unless variable_names.include?(Tunes::LEVEL)

            [eval_call("rg_music_follow_level", C::AddressOf.new(variable(Tunes::LEVEL)))]
          end

          # Every song as the runtime reads it (the layout is atop runtime/rg_sound.c): its length,
          # where it loops from, and each square-wave part's notes the first time through and every
          # time after.
          def music_table
            songs = @sound_log.songs.map { |song| song_numbers(song) }
            starts = []
            at = 1 + songs.size # past the count and the starts themselves
            songs.each do |numbers|
              starts << at
              at += numbers.size
            end
            C::ConstArray.new(name: @names.own("music"), type: "int32_t",
                              values: [songs.size, *starts, *songs.flatten], exported: true)
          end

          def song_numbers(song)
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
