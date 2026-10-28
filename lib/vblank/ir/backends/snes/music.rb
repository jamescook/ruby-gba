# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # A GAME'S SONGS AND SOUND EFFECTS, AS THE SUPER NINTENDO'S PLAYER READS THEM
        # (Runtime::Music), worked out while the program is built.
        #
        # Everything a note does is worked out here, in Ruby: the S-DSP writes it means and the
        # entries of the interpreter's sound log it is (Reference::Player#play_song_frame and
        # #play_effect_frame), as GROUPS of commands — a DSP write, a few of FLG's or KOFF's bits set,
        # or an entry into the cartridge's sound log. The player on the console only walks each
        # part's notes a frame at a time, settles who sounds on a voice two players want, and hands
        # each note's groups to the sound unit, so it plays a note exactly as the lowering plays a
        # beep, through the same DSP writes (DSPWrites).
        #
        # WHO SOUNDS ON A VOICE. The interpreter settles it by a rank of 24 bits (IR::Tunes.song_rank,
        # IR::Tunes.effect_rank); the player keeps instead each rank's place among every rank the game
        # can have, the lowest first (#rank_place), as the Color's does. The order is the same, so
        # every comparison comes out the same, and rank 0 — nobody, or a song of no priority — is
        # place 0.
        #
        # THE TABLE, all of it 16-bit words, every place in it counted from its start:
        #
        #   0..10         where the songs, the song lists, the effects, the effects in the order a
        #                 frame plays them, which ranks are an effect's, and the effect lists are
        #   the groups    [command, first number, second number] each, nought after the last
        #   the lists     for each song list where it is; each how many songs and each one's number
        #   the songs     a word for each song, numbered in the order declared: where its record is
        #   a record      its length in frames, the frame it comes round from, 1 if it plays once,
        #                 how many parts, where its group logging [:stop_music] is, the voices its
        #                 parts play on (a bit each), and its rank's place; then for each part where
        #                 its first time round's notes are and how many, and the same for every time
        #                 after (IR::Tunes.loop_passes), where its loudness groups are, whether its
        #                 voice holds a note, and its channel (#part_layout)
        #   a note        its frame, where its two groups are, its volume as written, and whether it
        #                 makes a sound (Reference::Player#sounds?)
        #   the effects   a word for each, numbered in the order declared: where its record is;
        #                 then the numbers in rank order; then a word for each rank's place, 1 when
        #                 it is an effect's; then for each effect list where it is, and each how many
        #                 effects and each one's number
        #   an effect     its rank's place, its group (counted from 1, nought for none), its
        #                 priority, its length in frames, how many parts, where its group logging
        #                 [:sound_effect ...] is; then for each part where its notes are, how many,
        #                 where its group letting the voice go at its end is, and its channel
        class Music
          # What the songs are to the author, for a cartridge too full for them.
          SONGS = W65816::Holding.new(what: "the game's songs and sound effects",
                                      fix: "make its songs shorter, or use fewer of them")

          # Where the table's first words are.
          SONGS_AT = 0
          LISTS_AT = 2
          EFFECTS_AT = 4
          BY_RANK_AT = 6
          RANK_KINDS_AT = 8
          EFFECT_LISTS_AT = 10
          HEADER_WORDS = 6

          # Where each number is, in bytes: in a song's record, then in each part's entry after it
          # (where its notes are, and how many), in a note, and how long a group's command is.
          LENGTH = 0
          LOOP_FRAME = 2
          PLAYS_ONCE = 4
          PART_COUNT = 6
          STOP_LOG = 8
          VOICES = 10
          RANK = 12
          RECORD_BYTES = 14
          NOTES_AT = 0
          NOTE_COUNT = 2
          AGAIN = 4 # the same two for every time round after the first
          LOUDNESS_GROUPS = 8 # where the places of the part's loudness groups are, one for each of VOLUMES
          HOLDS = 10 # 1 when its voice holds a note for a new level to reach
          CHANNEL = 12
          PART_BYTES = 16
          NOTE_FRAME = 0
          NOTE_HEAD = 2
          NOTE_TAIL = 4
          NOTE_VOLUME = 6
          NOTE_SOUNDS = 8
          NOTE_BYTES = 16
          COMMAND_FIRST = 2
          COMMAND_SECOND = 4
          COMMAND_BYTES = 6

          # ...and in an effect's record, and each of its parts' entries (where its notes are and how
          # many, and CHANNEL, as a song's part has them).
          EFFECT_RANK = 0
          EFFECT_GROUP = 2
          EFFECT_PRIORITY = 4
          EFFECT_LENGTH = 6
          EFFECT_PART_COUNT = 8
          EFFECT_START_LOG = 10
          EFFECT_RECORD_BYTES = 12
          EFFECT_RELEASE = 4

          # The most parts a song has: one on each of the voices the Advance plays itself.
          PARTS = 4

          # The volumes a voice the Advance plays itself has, and so the loudnesses a level can take a
          # note to (IR::Tunes.scaled_volume).
          VOLUMES = (0..15).freeze

          # The commands of a group besides the sound unit's own (Runtime::Sound::WRITE_DSP and the
          # rest): the group's end, and an entry into the sound log.
          GROUP_END = 0
          GROUP_LOG = 4

          # WHAT A TUNE STOPPING LOGS. The interpreter logs [:stop_music] whichever tune it was
          # (Reference::Player#silence_song), and which voices the stop lets go of depends on the
          # tune. A tune whose every voice an effect holds logs no note to tell it by, so the
          # cartridge logs each tune's stop as an entry of its own, [:stop_music, name], which reads
          # back as the interpreter's [:stop_music] (Music.interpreter_entry, for HeadlessRun's log)
          # and tells the checked run which tune stopped (HeadlessRun#audio_as_logged).
          def self.stop_entry(name) = [:stop_music, name]

          # A cartridge's log entry in the interpreter's words: a stop without its tune.
          def self.interpreter_entry(entry) = entry.first == :stop_music ? [:stop_music] : entry

          # Whether +program+ sets how loud its music plays (`music_volume`, or a fade), and so logs and
          # writes each note's loudness (Reference::Player#play_song_frame with a level): whether a run
          # can reach its music volume, which is then one of the variables the lowering keeps.
          def self.follows_level?(program) = IR::Reach.variables(program).include?(IR::Tunes::LEVEL)

          def initialize(program)
            @songs = program.walk.select { |node| node.kind == :song }.uniq(&:name)
            @lists = program.walk.select { |node| node.kind == :song_list }.uniq(&:name)
            @effect_lists = program.walk.select { |node| node.kind == :sound_effect_list }.uniq(&:name)
            @effect_names = IR::Tunes.effects(program).uniq
            @follows_level = self.class.follows_level?(program)
          end

          # The number list +name+ is picked from by, counted from nought.
          def list_number(name)
            @lists.index { |list| list.name == name } or raise LoweringError, "the song list #{name.inspect} is not declared"
          end

          # The number effect list +name+ is picked from by, counted from nought.
          def effect_list_number(name)
            @effect_lists.index { |list| list.name == name } or
              raise LoweringError, "the sound effect list #{name.inspect} is not declared"
          end

          # The number +name+ is played by, counted from 1: nought is no tune.
          def number(name)
            (@songs.index { |song| song.name == name } or raise LoweringError, "the song #{name.inspect} is not declared") + 1
          end

          # Whether the game has sound effects, whose player shares the voices with the tune's.
          def effects? = !@effect_names.empty?

          # How many sound effects the game has.
          def effect_count = @effect_names.size

          # The sound effects' names (DSPWrites::Voicing).
          def effect_names = @effect_names.dup

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

          # Each song's parts, effects' included, by [the song's name, its channel] (DSPWrites::Voicing).
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
            # A tune stopping logs its own stop (Music.stop_entry); the voices it lets go of are worked
            # out as it stops, since a sound effect may hold some of them (Runtime::Music's rt_music_quiet).
            tunes = @songs.map do |song|
              stop_log = keep_group([[GROUP_LOG, yield(self.class.stop_entry(song.name)), 0]])
              [song, stop_log, channels_of(song).map { |part, channel| part_layout(song, part, channel, voicing, &number_of) }]
            end
            effects = @effect_names.map { |name| effect_layout(song_named(name), voicing, &number_of) }

            table = Array.new(HEADER_WORDS, 0)
            places = {}
            @groups.each do |commands|
              places[commands] = table.size * 2
              table.concat(commands.flatten, [GROUP_END])
            end
            lay_out_lists(table, LISTS_AT, @lists.map { |list| list.songs.map { |name| number(name) } })
            table[SONGS_AT / 2] = table.size * 2
            lay_out_records(table, tunes) { |tune| song_words(tune, places) }
            table[EFFECTS_AT / 2] = table.size * 2
            lay_out_records(table, effects) { |effect| effect_words(effect, places) }
            table[BY_RANK_AT / 2] = table.size * 2
            table.concat([effects.size, *effects.each_index.sort_by { |e| -effects[e][:rank] }])
            table[RANK_KINDS_AT / 2] = table.size * 2
            table.concat(ranks.map { |full| (full & IR::Tunes::ORDER_MASK).zero? ? 0 : 1 })
            lay_out_lists(table, EFFECT_LISTS_AT, @effect_lists.map { |list| list.effects.map { |name| @effect_names.index(name) } })
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

          # A table of +lists+ (each a list of numbers) at the end of +table+, its place in the
          # header's word +at+: a word for each list, where it is; then each, its length and numbers.
          def lay_out_lists(table, at, lists)
            table[at / 2] = table.size * 2
            index = table.size
            table.concat(Array.new(lists.size, 0))
            lists.each_with_index do |numbers, i|
              table[index + i] = table.size * 2
              table.concat([numbers.size, *numbers])
            end
          end

          # A word for each of +records+, where it is, and then each one's words, as the block gives
          # them for a record starting at the place it is given.
          def lay_out_records(table, records)
            index = table.size
            table.concat(Array.new(records.size, 0))
            records.each_with_index do |record, i|
              table[index + i] = table.size * 2
              table.concat(yield(record).call(table.size))
            end
          end

          # A tune's record and what follows it, as a function of the word it starts at.
          def song_words(tune, places)
            song, stop_log, parts = tune
            lambda do |start|
              head = [song.total_frames, IR::Tunes.loop_frame(song), IR::Tunes.plays_once?(song) ? 1 : 0, parts.size,
                      places.fetch(stop_log), parts.sum { |part| 1 << DSPWrites::CHANNEL_VOICES.fetch(part[:channel]) },
                      rank_place(IR::Tunes.song_rank(song))]
              entries = Array.new(parts.size * PART_BYTES / 2, 0)
              tail = []
              at = start + head.size + entries.size
              parts.each_with_index do |part, p|
                entry = p * PART_BYTES / 2
                part[:lists].each_with_index do |notes, which|
                  entries[entry + (which * 2)] = (at + tail.size) * 2
                  entries[entry + (which * 2) + 1] = notes.size
                  notes.each { |note| tail.concat(note_words(note, places)) }
                end
                if part[:loudness]
                  entries[entry + (LOUDNESS_GROUPS / 2)] = (at + tail.size) * 2
                  tail.concat(part[:loudness].map { |commands| places.fetch(commands) })
                end
                entries[entry + (HOLDS / 2)] = part[:holds] ? 1 : 0
                entries[entry + (CHANNEL / 2)] = part[:channel]
              end
              head + entries + tail
            end
          end

          # An effect's record and what follows it, as a function of the word it starts at.
          def effect_words(effect, places)
            lambda do |start|
              parts = effect[:parts]
              head = [rank_place(effect[:rank]), effect[:group], effect[:priority], effect[:length], parts.size,
                      places.fetch(effect[:start_log])]
              entries = Array.new(parts.size * PART_BYTES / 2, 0)
              tail = []
              at = start + head.size + entries.size
              parts.each_with_index do |part, p|
                entry = p * PART_BYTES / 2
                entries[entry + (NOTES_AT / 2)] = (at + tail.size) * 2
                entries[entry + (NOTE_COUNT / 2)] = part[:notes].size
                entries[entry + (EFFECT_RELEASE / 2)] = places.fetch(part[:release])
                entries[entry + (CHANNEL / 2)] = part[:channel]
                part[:notes].each { |note| tail.concat(note_words(note, places)) }
              end
              head + entries + tail
            end
          end

          # A note's words: its frame, its two groups' places, its volume as written, whether it sounds.
          def note_words(note, places)
            frame, head, tail, written, sounds = note
            [frame, places.fetch(head), places.fetch(tail), written, sounds ? 1 : 0] + Array.new((NOTE_BYTES / 2) - 5, 0)
          end

          # What the table holds for one part: its two lists of notes, the first time round and every
          # time after, each note [its frame, its head group, its tail group, its volume as written,
          # nought for a rest, whether it sounds]; whether its voice holds a note for a new level to
          # reach (a drum hit on the noise voice rings and fades by itself, and is not held:
          # Reference::Player#record_note_volume); its channel; and, in a game that follows the music
          # volume, the group that writes and logs its loudness at each of the voices' volumes.
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
              events.map { |event| note_layout(song, part, channel, event, between, voicing, &number_of) }
            end
            layout = { lists: lists, holds: IR::Tunes.part_kind(part) != :noise, channel: channel }
            return layout unless follows_level?

            layout.merge(loudness: VOLUMES.map do |volume|
              keep_group(entry_commands([[:loudness, channel, volume]], voicing, song.name, &number_of).flatten(1))
            end)
          end

          # One note of +song+'s +part+ on +channel+ (an +event+ of its list), with +between+ its head
          # and its tail.
          def note_layout(song, part, channel, event, between, voicing, &number_of)
            frame, frequency, _, volume = event
            volume ||= part.volume
            head = [[:note, song.name, frequency], [:voice, channel, song.name, frequency, volume]]
            commands = entry_commands(head + between + wave_or_noise_entries(part, frequency), voicing, song.name, &number_of)
            [frame, keep_group(commands.take(2).flatten(1)), keep_group(commands.drop(2 + between.size).flatten(1)),
             frequency.zero? ? 0 : volume, DSPWrites.sounds?(channel, frequency, volume)]
          end

          # What the table holds for one sound effect (Reference::Player#play_effect_frame): its rank,
          # group, priority and length; the group logging that it starts; and for each part its notes,
          # played once as written, its channel, and the group letting its voice go at the effect's
          # end (Reference::Player#finish_effect).
          def effect_layout(song, voicing, &number_of)
            order = @effect_names.index(song.name)
            parts = channels_of(song).map do |part, channel|
              release = [[:note, song.name, 0], [:voice, channel, song.name, 0, 0]] + release_entries(channel)
              { notes: part.events.map { |event| note_layout(song, part, channel, event, [], voicing, &number_of) },
                channel: channel,
                release: keep_group(entry_commands(release, voicing, song.name, &number_of).flatten(1)) }
            end
            { rank: IR::Tunes.effect_rank(song, order), group: group_number(song.group), priority: song.priority || 0,
              length: song.total_frames, parts: parts,
              start_log: keep_group([[GROUP_LOG, yield([:sound_effect, song.name]), 0]]) }
          end

          # What letting go of the wave or noise voice also logs at an effect's end.
          def release_entries(channel)
            case channel
            when Reference::Player::NOISE_CHANNEL then [[:noise, nil]]
            when Reference::Player::WAVE_CHANNEL then [[:stop_wave]]
            else []
            end
          end

          # A group's number, counted from 1 in the order the effects first name it; nought for none.
          def group_number(group)
            return 0 unless group

            @effect_names.filter_map { |name| song_named(name).group }.uniq.index(group) + 1
          end

          # Every rank the game's songs and sound effects can have, and nobody's, lowest first.
          def ranks
            @ranks ||= ([0] + @songs.map { |song| IR::Tunes.song_rank(song) } +
                        @effect_names.each_with_index.map { |name, i| IR::Tunes.effect_rank(song_named(name), i) })
                       .uniq.sort
          end

          def rank_place(full) = ranks.index(full) or raise LoweringError, "the rank #{full} is not among the game's"

          def song_named(name) = @songs.find { |song| song.name == name } || raise(LoweringError, "the song #{name.inspect} is not declared")

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
