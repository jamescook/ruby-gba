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
        #   QUIET_AT      the group a stopped tune plays: every voice a song plays on let go, and
        #                 [:stop_music] logged
        #   the songs     a word for each song, numbered in the order declared: where its record is
        #   a record      its length in frames, the frame it comes round from, 1 if it plays once,
        #                 how many parts; and for each part where its first time round's notes are
        #                 and how many, and the same for every time after (IR::Tunes.loop_passes)
        #   a note        its frame, and where its group is
        #   a group       [command, first number, second number] each, nought after the last
        class Music
          # What the songs are to the author, for a cartridge too full for them.
          SONGS = W65816::Holding.new(what: "the game's songs", fix: "make its songs shorter, or use fewer of them")

          QUIET_AT = 2
          RECORD_WORDS = 4
          PART_WORDS = 4
          NOTE_WORDS = 2

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

          # Each square part's width, by [the song's name, its channel] (DSPWrites::Voicing).
          def duties
            @songs.each_with_object({}) do |song, held|
              channels_of(song).each { |part, channel| held[[song.name, channel]] = part.duty }
            end
          end

          # The table, as words. +voicing+ is the game's (DSPWrites::Voicing), and the block gives
          # the number the cartridge's sound log keeps an entry as.
          def words(voicing)
            @songs.each { |song| refuse_parts!(song) }
            groups = {} # the log entries a group is -> its commands, in the order first met
            group = lambda do |entries|
              groups[entries] ||= entries.flat_map do |entry|
                DSPWrites.for_entry(entry, voicing).map { |write| Runtime::Sound.command_for(write) } +
                  [[GROUP_LOG, yield(entry), 0]]
              end
              entries
            end
            group.call(QUIET)
            songs = @songs.map { |song| [song, parts_notes(song, group)] }

            table = [0]
            places = {}
            groups.each do |entries, commands|
              places[entries] = table.size * 2
              table.concat(commands.flatten, [GROUP_END])
            end
            songs_at = table.size
            table[0] = songs_at * 2
            table.concat(Array.new(songs.size, 0))
            songs.each_with_index do |(song, parts), i|
              table[songs_at + i] = table.size * 2
              table.concat([song.total_frames, IR::Tunes.loop_frame(song), IR::Tunes.plays_once?(song) ? 1 : 0, parts.size])
              lists = parts.flatten(1)
              at = table.size + (parts.size * PART_WORDS)
              lists.each do |notes|
                table.concat([at * 2, notes.size])
                at += notes.size * NOTE_WORDS
              end
              lists.each { |notes| notes.each { |frame, entries| table.concat([frame, places.fetch(entries)]) } }
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
          # frame, the log entries it is], its group made by +group+.
          def parts_notes(song, group)
            passes = IR::Tunes.loop_passes(song)
            channels_of(song).map do |part, channel|
              pass = passes.fetch(song.voices.index(part))
              [pass.first, pass.again].map do |events|
                events.map do |frame, frequency, _, volume|
                  [frame, group.call([[:note, song.name, frequency],
                                      [:voice, channel, song.name, frequency, volume || part.volume]])]
                end
              end
            end
          end

          # Each part with the channel the interpreter names its voice by (Reference::Player#console_channel).
          def channels_of(song) = song.voices.each_with_index.map { |part, i| [part, i + 1] }

          def refuse_parts!(song)
            squares = song.voices.count { |part| IR::Tunes.part_kind(part) == :square }
            unless squares == song.voices.size
              raise Lowering::NotMadeYet.new(
                "The song #{song.name.inspect} has a part on the wave or noise voice, or one that plays a recording. " \
                "The Super Nintendo build does not make that yet. To fix this, build the game for the Game Boy " \
                "Advance alone for now (`consoles: %i[gba]`).", part: "the sound"
              )
            end
            return if squares <= 2

            raise LoweringError, "The song #{song.name.inspect} has #{squares} parts on the square voices, and there are " \
                                 "two. To fix this, write it for two square parts."
          end
        end
      end
    end
  end
end
