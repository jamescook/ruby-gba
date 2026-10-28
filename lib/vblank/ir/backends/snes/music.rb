# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # A GAME'S SONGS, AS THE SUPER NINTENDO'S PLAYER READS THEM (Runtime::Music), worked out while
        # the program is built.
        #
        # Everything a note does is worked out here, in Ruby: the S-DSP writes it means and the
        # entries of the interpreter's sound log it is (Reference::Player#play_song_frame), as one
        # GROUP of commands — a DSP write, a few of FLG's or KOFF's bits set, or an entry into the
        # cartridge's sound log. The player on the console only walks each part's notes a frame at a
        # time and hands each note's group to the sound unit, so it plays a note exactly as the
        # lowering plays a beep, through the same DSP writes (DSPWrites).
        #
        # THE TABLE, all of it 16-bit words, every place in it counted from its start:
        #
        #   0             where the table of songs is
        #   the groups    [command, first number, second number] each, nought after the last
        #   the songs     a word for each song, numbered in the order declared: where its record is
        #   a record      its length in frames, the frame it comes round from, 1 if it plays once,
        #                 how many parts, and where its group for stopping is (the voices its parts
        #                 play on let go, and [:stop_music] logged); then for each part where its
        #                 first time round's notes are and how many, and the same for every time
        #                 after (IR::Tunes.loop_passes)
        #   a note        its frame, and where its group is
        class Music
          # What the songs are to the author, for a cartridge too full for them.
          SONGS = W65816::Holding.new(what: "the game's songs", fix: "make its songs shorter, or use fewer of them")

          # Where each number is, in bytes: in a song's record, then in each part's entry after it
          # (where its notes are, and how many), in a note, and how long a group's command is.
          LENGTH = 0
          LOOP_FRAME = 2
          PLAYS_ONCE = 4
          PART_COUNT = 6
          QUIET_GROUP = 8
          RECORD_BYTES = 10
          NOTES_AT = 0
          NOTE_COUNT = 2
          AGAIN = 4 # the same two for every time round after the first
          PART_BYTES = 8
          NOTE_FRAME = 0
          NOTE_GROUP = 2
          NOTE_BYTES = 4
          COMMAND_FIRST = 2
          COMMAND_SECOND = 4
          COMMAND_BYTES = 6

          # The most parts a song has: one on each of the voices the Advance plays itself.
          PARTS = 4

          # The commands of a group besides the sound unit's own (Runtime::Sound::WRITE_DSP and the
          # rest): the group's end, and an entry into the sound log.
          GROUP_END = 0
          GROUP_LOG = 4

          # What a tune stopping logs (Reference::Player#silence_song).
          QUIET = [[:stop_music]].freeze

          def initialize(program)
            @songs = program.walk.select { |node| node.kind == :song }.uniq(&:name)
          end

          # The number +name+ is played by, counted from 1: nought is no tune.
          def number(name)
            (@songs.index { |song| song.name == name } or raise LoweringError, "the song #{name.inspect} is not declared") + 1
          end

          # Each wave part's waveform and loudness, as a `wave` names them (DSPWrites.wave_steps).
          def waves
            @songs.flat_map(&:voices).select { |part| IR::Tunes.part_kind(part) == :wave }
                  .map { |part| { shape: part.wave, volume: part.volume } }
          end

          # Each song's parts, by [the song's name, its channel] (DSPWrites::Voicing).
          def parts
            @songs.each_with_object({}) do |song, held|
              channels_of(song).each { |part, channel| held[[song.name, channel]] = part }
            end
          end

          # The table, as words. +voicing+ is the game's (DSPWrites::Voicing), and the block gives
          # the number the cartridge's sound log keeps an entry as.
          def words(voicing)
            @songs.each { |song| refuse_parts!(song) }
            groups = [] # every group's commands, each once, in the order first met
            group = lambda do |entries, song = nil|
              commands = entries.flat_map do |entry|
                DSPWrites.for_entry(entry, voicing, song: song).map { |write| Runtime::Sound.command_for(write) } +
                  [[GROUP_LOG, yield(entry), 0]]
              end
              groups << commands unless groups.include?(commands)
              commands
            end
            songs = @songs.map { |song| [song, group.call(QUIET, song.name), parts_notes(song, group)] }

            table = [0]
            places = {}
            groups.each do |commands|
              places[commands] = table.size * 2
              table.concat(commands.flatten, [GROUP_END])
            end
            songs_at = table.size
            table[0] = songs_at * 2
            table.concat(Array.new(songs.size, 0))
            songs.each_with_index do |(song, quiet, parts), i|
              table[songs_at + i] = table.size * 2
              table.concat([song.total_frames, IR::Tunes.loop_frame(song), IR::Tunes.plays_once?(song) ? 1 : 0, parts.size,
                            places.fetch(quiet)])
              lists = parts.flatten(1)
              at = table.size + (parts.size * PART_BYTES / 2)
              lists.each do |notes|
                table.concat([at * 2, notes.size])
                at += notes.size * NOTE_BYTES / 2
              end
              lists.each { |notes| notes.each { |frame, commands| table.concat([frame, places.fetch(commands)]) } }
            end
            table
          end

          # The section the table is kept in, labelled "music_data".
          def section(words)
            asm = W65816.new("music", holds: SONGS)
            asm.label("music_data")
            asm.data_words(words)
            asm.section
          end

          private

          # Each part's two lists of notes, the first time round and every time after, each note [its
          # frame, its group's commands], each group made by +group+.
          def parts_notes(song, group)
            passes = IR::Tunes.loop_passes(song)
            channels_of(song).map do |part, channel|
              pass = passes.fetch(song.voices.index(part))
              [pass.first, pass.again].map do |events|
                events.map do |frame, frequency, _, volume|
                  [frame, group.call([[:note, song.name, frequency],
                                      [:voice, channel, song.name, frequency, volume || part.volume],
                                      *wave_or_noise(part, frequency)])]
                end
              end
            end
          end

          # What a note on the wave or noise voice also logs, as Reference::Player#log_wave_or_noise
          # says it: that voice's own entry, which is the note's DSP writes.
          def wave_or_noise(part, frequency)
            case IR::Tunes.part_kind(part)
            when :wave
              [frequency.zero? ? [:stop_wave] : [:wave, { shape: part.wave, frequency: frequency, volume: part.volume }]]
            when :noise
              [[:noise, frequency.zero? ? nil : { pitch: frequency, decay: part.decay, volume: part.volume,
                                                  metallic: part.metallic }]]
            else []
            end
          end

          # Each part with the channel the interpreter names its voice by (Reference::Player#console_channel):
          # the square parts 1 and 2 in the order written, the wave part 3, the noise part 4.
          def channels_of(song)
            squares = 0
            song.voices.map do |part|
              channel = case IR::Tunes.part_kind(part)
                        when :square then squares += 1
                        when :wave then Reference::Player::WAVE_CHANNEL
                        when :noise then Reference::Player::NOISE_CHANNEL
                        end
              [part, channel]
            end
          end

          def refuse_parts!(song)
            if song.voices.any? { |part| IR::Tunes.part_kind(part) == :recorded }
              raise Lowering::NotMadeYet.new(
                "The song #{song.name.inspect} has a part that plays a recording. The Super Nintendo build does not " \
                "make that yet. To fix this, build the game for the Game Boy Advance alone for now " \
                "(`consoles: %i[gba]`).", part: "the sound"
              )
            end
            kinds = song.voices.map { |part| IR::Tunes.part_kind(part) }
            return if kinds.count(:square) <= 2 && kinds.count(:wave) <= 1 && kinds.count(:noise) <= 1

            raise LoweringError, "The song #{song.name.inspect} has more than one part on one of the voices. To fix " \
                                 "this, write it for the square, wave and noise voices, one part each (two on the " \
                                 "square voices)."
          end
        end
      end
    end
  end
end
