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
        #   2             where the table of song lists is
        #   the groups    [command, first number, second number] each, nought after the last
        #   the lists     a word for each song list, numbered in the order declared: where it is;
        #                 then each list, how many songs and each one's number
        #   the songs     a word for each song, numbered in the order declared: where its record is
        #   a record      its length in frames, the frame it comes round from, 1 if it plays once,
        #                 how many parts, and where its group for stopping is (the voices its parts
        #                 play on let go, and [:stop_music] logged); then for each part where its
        #                 first time round's notes are and how many, and the same for every time
        #                 after (IR::Tunes.loop_passes), where its loudness groups are and whether
        #                 its voice holds a note (#part_layout)
        #   a note        its frame, where its two groups are, and its volume as written
        class Music
          # What the songs are to the author, for a cartridge too full for them.
          SONGS = W65816::Holding.new(what: "the game's songs", fix: "make its songs shorter, or use fewer of them")

          # Where the table's two first words are: where the table of songs is, and where the table of
          # song lists is (each list how many songs, then each song's number).
          SONGS_AT = 0
          LISTS_AT = 2

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
          LOUDNESS_GROUPS = 8 # where the places of the part's loudness groups are, one for each of VOLUMES
          HOLDS = 10 # 1 when its voice holds a note for a new level to reach
          PART_BYTES = 16
          NOTE_FRAME = 0
          NOTE_HEAD = 2
          NOTE_TAIL = 4
          NOTE_VOLUME = 6
          NOTE_BYTES = 8
          COMMAND_FIRST = 2
          COMMAND_SECOND = 4
          COMMAND_BYTES = 6

          # The most parts a song has: one on each of the voices the Advance plays itself.
          PARTS = 4

          # The volumes a voice the Advance plays itself has, and so the loudnesses a level can take a
          # note to (IR::Tunes.scaled_volume).
          VOLUMES = (0..15).freeze

          # The commands of a group besides the sound unit's own (Runtime::Sound::WRITE_DSP and the
          # rest): the group's end, and an entry into the sound log.
          GROUP_END = 0
          GROUP_LOG = 4

          # What a tune stopping logs (Reference::Player#silence_song).
          QUIET = [[:stop_music]].freeze

          # Whether +program+ sets how loud its music plays (`music_volume`, or a fade), and so logs and
          # writes each note's loudness (Reference::Player#play_song_frame with a level): whether a run
          # can reach its music volume, which is then one of the variables the lowering keeps.
          def self.follows_level?(program) = IR::Reach.variables(program).include?(IR::Tunes::LEVEL)

          def initialize(program)
            @songs = program.walk.select { |node| node.kind == :song }.uniq(&:name)
            @lists = program.walk.select { |node| node.kind == :song_list }.uniq(&:name)
            @follows_level = self.class.follows_level?(program)
          end

          # The number list +name+ is picked from by, counted from nought.
          def list_number(name)
            @lists.index { |list| list.name == name } or raise LoweringError, "the song list #{name.inspect} is not declared"
          end

          # The number +name+ is played by, counted from 1: nought is no tune.
          def number(name)
            (@songs.index { |song| song.name == name } or raise LoweringError, "the song #{name.inspect} is not declared") + 1
          end

          # Each wave part's waveform at each volume its notes play it at, as a `wave` names them
          # (DSPWrites.wave_steps): a note's own volume, or the part's — and, in a game that follows
          # the music volume, at every one of the wave voice's loudnesses, which a level can take it to.
          def waves
            @songs.flat_map(&:voices).select { |part| IR::Tunes.part_kind(part) == :wave }.flat_map do |part|
              volumes = part.events.map { |_, _, _, volume| volume || part.volume }
              volumes += VBlank::Audio::Sound::WAVE_LEVEL_STEPS if follows_level?
              volumes.uniq.map { |volume| { shape: part.wave, volume: volume } }
            end
          end

          # Each song's parts, by [the song's name, its channel] (DSPWrites::Voicing).
          def parts
            @songs.each_with_object({}) do |song, held|
              channels_of(song).each { |part, channel| held[[song.name, channel]] = part }
            end
          end

          # The table, as words. +voicing+ is the game's (DSPWrites::Voicing), and the block gives
          # the number the cartridge's sound log keeps an entry as.
          def words(voicing, &number_of)
            @songs.each { |song| refuse_parts!(song) }
            @groups = [] # every group's commands, each once, in the order first met
            songs = @songs.map do |song|
              [song, keep_group(entry_commands(QUIET, voicing, song.name, &number_of).flatten(1)),
               channels_of(song).map { |part, channel| part_layout(song, part, channel, voicing, &number_of) }]
            end

            table = [0, 0]
            places = {}
            @groups.each do |commands|
              places[commands] = table.size * 2
              table.concat(commands.flatten, [GROUP_END])
            end
            table[LISTS_AT / 2] = table.size * 2
            lists_at = table.size
            table.concat(Array.new(@lists.size, 0))
            @lists.each_with_index do |list, i|
              table[lists_at + i] = table.size * 2
              table.concat([list.songs.size, *list.songs.map { |name| number(name) }])
            end
            songs_at = table.size
            table[SONGS_AT / 2] = songs_at * 2
            table.concat(Array.new(songs.size, 0))
            songs.each_with_index do |(song, quiet, parts), i|
              table[songs_at + i] = table.size * 2
              table.concat([song.total_frames, IR::Tunes.loop_frame(song), IR::Tunes.plays_once?(song) ? 1 : 0, parts.size,
                            places.fetch(quiet)])
              entries_at = table.size
              table.concat(Array.new(parts.size * PART_BYTES / 2, 0))
              parts.each_with_index do |part, p|
                entry = entries_at + (p * PART_BYTES / 2)
                part[:lists].each_with_index do |notes, which|
                  table[entry + (which * 2)] = table.size * 2
                  table[entry + (which * 2) + 1] = notes.size
                  notes.each { |frame, head, tail, written| table.concat([frame, places.fetch(head), places.fetch(tail), written]) }
                end
                if part[:loudness]
                  table[entry + (LOUDNESS_GROUPS / 2)] = table.size * 2
                  table.concat(part[:loudness].map { |commands| places.fetch(commands) })
                end
                table[entry + (HOLDS / 2)] = part[:holds] ? 1 : 0
              end
            end
            table
          end

          # Whether the game sets its music volume (Music.follows_level?).
          def follows_level? = @follows_level

          # The section the table is kept in, labelled "music_data".
          def section(words)
            asm = W65816.new("music", holds: SONGS)
            asm.label("music_data")
            asm.data_words(words)
            asm.section
          end

          private

          # What the table holds for one part: its two lists of notes, the first time round and every
          # time after, each note [its frame, its head group, its tail group, its volume as written,
          # nought for a rest]; whether its voice holds a note for a new level to reach (a drum hit on
          # the noise voice rings and fades by itself, and is not held: Reference::Player#record_note_volume);
          # and, in a game that follows the music volume, the group that writes and logs its loudness
          # at each of the voices' volumes.
          #
          # A NOTE'S TWO GROUPS. Its head is its [:note ...] and [:voice ...]; its tail the wave or
          # noise voice's own entry, if it is on one. In a game that follows the music volume the
          # player plays its loudness between the two, worked out from the level at the time
          # (Runtime::Music), as the interpreter logs it there — and the tail leaves out what the
          # loudness wrote (DSPWrites.each_entry_writes), which any loudness writes alike.
          def part_layout(song, part, channel, voicing, &number_of)
            passes = IR::Tunes.loop_passes(song).fetch(song.voices.index(part))
            between = follows_level? ? [[:loudness, channel, 0]] : []
            lists = [passes.first, passes.again].map do |events|
              events.map do |frame, frequency, _, volume|
                head = [[:note, song.name, frequency], [:voice, channel, song.name, frequency, volume || part.volume]]
                commands = entry_commands(head + between + wave_or_noise_entries(part, frequency), voicing, song.name,
                                          &number_of)
                [frame, keep_group(commands.take(2).flatten(1)), keep_group(commands.drop(2 + between.size).flatten(1)),
                 frequency.zero? ? 0 : volume || part.volume]
              end
            end
            layout = { lists: lists, holds: IR::Tunes.part_kind(part) != :noise }
            return layout unless follows_level?

            layout.merge(loudness: VOLUMES.map do |volume|
              keep_group(entry_commands([[:loudness, channel, volume]], voicing, song.name, &number_of).flatten(1))
            end)
          end

          # Each of +entries+' commands: its DSP writes, then its entry into the sound log.
          def entry_commands(entries, voicing, song, &number_of)
            DSPWrites.each_entry_writes(entries, voicing, song: song).map do |entry, writes|
              writes.map { |write| Runtime::Sound.command_for(write) } + [[GROUP_LOG, yield(entry), 0]]
            end
          end

          # +commands+ kept as a group of the table, once however often it is asked for.
          def keep_group(commands)
            @groups << commands unless @groups.include?(commands)
            commands
          end

          # What a note on the wave or noise voice also logs, as Reference::Player#log_wave_or_noise
          # says it: that voice's own entry, which is the note's DSP writes.
          def wave_or_noise_entries(part, frequency)
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

            raise LoweringError, "The song #{song.name.inspect} has too many parts for one voice. A song can have two " \
                                 "square parts, one wave part and one noise part. To fix this, remove the extra parts."
          end
        end
      end
    end
  end
end
