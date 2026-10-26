# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # A GAME'S SONGS, AS THE COLOR'S PLAYER READS THEM (Runtime::Music), worked out while the
        # program is built.
        #
        # Each part of a song plays on one of the console's own voices: the first two square-wave
        # parts on the two square voices, a part on the wave voice there, and a part on the hiss
        # on the noise voice. A note is when it starts, the numbers its voice is tuned by — worked
        # out by Audio::Sound, the same that tunes the Advance's voices, which are these — and how
        # loud it is. A song comes round from its loop point the way IR::Tunes says every backend
        # does: each part's notes the first time, and every time after.
        #
        # Every song the game declares is kept, played or not, and numbered in the order declared.
        class Music
          # Which voice a part plays on, by its kind: the square voices are 1 and 2.
          WAVE_VOICE = 3
          NOISE_VOICE = 4

          # A note's tuning that says the part rests there.
          REST = 0xFFFF

          # What the songs are to the author, for a cartridge too full for them (see Linker::TooBig).
          SONGS = SM83::Holding.new(what: "the game's songs", fix: "make its songs shorter, or use fewer of them")

          # How many bytes a note takes in a part's list: when it starts, its tuning, its volume.
          NOTE_BYTES = 5

          # One note of a part as the music table holds it, with what it is to the interpreter: the
          # song's name, the part, the voice it plays on, its pitch (0 for a rest) and its volume.
          Note = Data.define(:song, :part, :voice, :pitch, :volume)

          # A SOUND EFFECT as the Color's player reads it (Runtime::Effects): its name, its number
          # among the game's effects in the order declared, its rank as a number of a byte (#rank),
          # its group and priority, how many frames it lasts, and its parts.
          Effect = Data.define(:name, :number, :rank, :group, :priority, :total_frames, :parts)

          # A part of a sound effect: the voice it plays on, what the voice sounds like (as a song's
          # part has it, #tone_of), and the label of its notes and how many there are.
          EffectPart = Data.define(:voice, :tone, :label, :count)

          def initialize(program)
            @songs = program.walk.select { |node| node.kind == :song }.uniq(&:name)
            @effect_names = Tunes.effects(program).uniq
          end

          # The number +name+ is played by.
          def number(name)
            @songs.index { |song| song.name == name } or raise LoweringError, "the song #{name.inspect} is not declared"
          end

          def any? = !@songs.empty?

          # The game's sound effects, in the order declared.
          def effects
            @effects ||= @effect_names.each_with_index.map do |name, number|
              song = song_named(name)
              parts = voices_of(song).each_with_index.map do |(part, voice), p|
                EffectPart.new(voice: voice, tone: tone_of(part, voice), label: "sfx_notes_#{number}_#{p}",
                               count: part.events.length)
              end
              Effect.new(name: name, number: number, rank: rank(Tunes.effect_rank(song, number)), group: song.group,
                         priority: song.priority || 0, total_frames: song.total_frames, parts: parts)
            end
          end

          # The effects in the order a frame plays them, highest rank first (IR::Tunes.effects_by_rank).
          def effects_by_rank = effects.sort_by { |effect| -effect.rank }

          # WHO HOLDS A VOICE, as one byte. The interpreter settles who sounds on a voice two players
          # want by a rank of 24 bits (IR::Tunes.song_rank, IR::Tunes.effect_rank); the Color keeps
          # instead each rank's place among every rank the game can have, the lowest first. The
          # order is the same, so every comparison comes out the same, and rank 0 — nobody, or a
          # song of no priority — is place 0.
          def rank(full)
            ranks.index(full) or raise LoweringError, "the rank #{full} is not among the game's"
          end

          # The section the songs are kept in: a table of where each song is, then each song —
          # how long it is, where it comes round from, whether it ends, how many parts, and for
          # each part its voice, what the voice sounds like, and its two lists of notes. Then each
          # song's rank (#rank), and for each rank whether it is a sound effect's; and each sound
          # effect's notes, as it plays them once.
          def section
            asm = SM83.new("music", home: :fixed, holds: SONGS)
            asm.label("music_songs")
            @songs.each_index { |i| asm.data_words("music_song_#{i}") }
            @songs.each_with_index { |song, i| emit_song(asm, song, i) }
            asm.label("music_waves")
            waveforms.each { |shape| asm.data_bytes(packed_waveform(shape)) }
            asm.data_bytes(0) # a label has to be somewhere
            emit_effects(asm) unless effects.empty?
            asm.section
          end

          # Every list of notes in the section, by its label: each note, in the order the list holds
          # them, NOTE_BYTES apart.
          def notes
            lists = @songs.each_with_index.each_with_object({}) do |(song, i), held_lists|
              passes = Tunes.loop_passes(song)
              voices_of(song).each_with_index do |(part, voice), p|
                pass = passes.fetch(song.voices.index(part))
                { "first" => pass.first, "again" => pass.again }.each do |which, held|
                  held_lists["music_notes_#{i}_#{p}_#{which}"] = held.map do |_, pitch, _, volume|
                    Note.new(song: song.name, part: part, voice: voice, pitch: pitch, volume: volume || part.volume)
                  end
                end
              end
            end
            effects.each do |effect|
              song = song_named(effect.name)
              voices_of(song).zip(effect.parts) do |(part, voice), played|
                lists[played.label] = part.events.map do |_, pitch, _, volume|
                  Note.new(song: effect.name, part: part, voice: voice, pitch: pitch, volume: volume || part.volume)
                end
              end
            end
            lists
          end

          private

          # Every rank the game's songs and sound effects can have, and nobody's, lowest first.
          def ranks
            @ranks ||= ([0] + @songs.map { |song| Tunes.song_rank(song) } +
                        @effect_names.each_with_index.map { |name, i| Tunes.effect_rank(song_named(name), i) })
                       .uniq.sort.tap do |all|
              if all.length > 256
                raise LoweringError, "this game's songs and sound effects have #{all.length} different ranks, and a " \
                                     "Game Boy Color build keeps 256. To fix this, use fewer sound effects."
              end
            end
          end

          def song_named(name) = @songs.find { |song| song.name == name } || raise(LoweringError, "the song #{name.inspect} is not declared")

          def emit_effects(asm)
            asm.label("music_ranks")
            asm.data_bytes(@songs.map { |song| rank(Tunes.song_rank(song)) })
            asm.label("music_rank_effects")
            asm.data_bytes(ranks.map { |full| (full & Tunes::ORDER_MASK).zero? ? 0 : 1 })
            effects.each do |effect|
              song = song_named(effect.name)
              voices_of(song).zip(effect.parts) do |(part, voice), played|
                asm.label(played.label)
                part.events.each do |at, pitch, _, volume|
                  asm.data_words(at, tuning(voice, pitch))
                  asm.data_bytes(volume || part.volume)
                end
              end
            end
          end

          def emit_song(asm, song, i)
            parts = voices_of(song)
            passes = Tunes.loop_passes(song)
            asm.label("music_song_#{i}")
            asm.data_words(song.total_frames, Tunes.loop_frame(song))
            asm.data_bytes(Tunes.plays_once?(song) ? 1 : 0, parts.length)
            parts.each_with_index do |(part, voice), p|
              pass = passes.fetch(song.voices.index(part))
              asm.data_bytes(voice, tone_of(part, voice))
              asm.data_words(pass.first.length, pass.again.length, "music_notes_#{i}_#{p}_first", "music_notes_#{i}_#{p}_again")
            end
            parts.each_with_index do |(part, voice), p|
              pass = passes.fetch(song.voices.index(part))
              { "first" => pass.first, "again" => pass.again }.each do |which, notes|
                asm.label("music_notes_#{i}_#{p}_#{which}")
                notes.each do |at, pitch, _, volume|
                  asm.data_words(at, tuning(voice, pitch))
                  asm.data_bytes(volume || part.volume)
                end
              end
            end
          end

          # Each part of the song, with the voice it plays on.
          def voices_of(song)
            squares = 0
            song.voices.map do |part|
              voice = case Tunes.part_kind(part)
                      when :square then (squares += 1)
                      when :wave then WAVE_VOICE
                      when :noise then NOISE_VOICE
                      else refuse_part!(song, "plays a recording (`voice ..., plays:`), which a Game Boy Color cannot play")
                      end
              refuse_part!(song, "has more than two parts on the square voices") if voice == 3 && squares == 3
              [part, voice]
            end.tap do |parts|
              voices = parts.map(&:last)
              refuse_part!(song, "has two parts on one voice") unless voices.uniq.length == voices.length
            end
          end

          def refuse_part!(song, what)
            raise LoweringError, "the song #{song.name.inspect} #{what}. To fix this, write it for the square, wave and " \
                                 "noise voices, one part each (two on the square voices)."
          end

          # What a part's voice sounds like, as the player writes it: a square part's duty, as
          # its voice's register has it; a wave part's waveform, by number; a noise part's fade.
          def tone_of(part, voice)
            sound = VBlank::Audio::Sound
            case voice
            when WAVE_VOICE then waveforms.index(part.wave)
            when NOISE_VOICE then sound::FADE_STEP_SIXTY_FOURTHS.fetch(part.decay) | (part.metallic ? 0x80 : 0)
            else sound::Registers.duty_bits(part.duty) << 6
            end
          end

          # The numbers a note's voice is tuned by, as its registers take them: the period of a
          # square or wave note, and the hiss's clock (and whether it is the metallic one) for a
          # noise note. REST for a rest.
          def tuning(voice, pitch)
            return REST if pitch.zero?

            sound = VBlank::Audio::Sound
            case voice
            when WAVE_VOICE then sound::Registers.wave_rate(pitch)
            when NOISE_VOICE
              divisor, shift = sound.noise_rung(pitch)
              (shift << 4) | divisor
            else sound::Registers.frequency_value(pitch)
            end
          end

          def waveforms
            @waveforms ||= @songs.flat_map(&:voices).filter_map { |part| part.wave if Tunes.part_kind(part) == :wave }.uniq
          end

          # A waveform's 32 steps as the wave voice keeps them: two to a byte, the first in the
          # high four bits.
          def packed_waveform(shape)
            VBlank::Audio::Sound.wavetable(shape).each_slice(2).map { |high, low| ((high & 0xF) << 4) | (low & 0xF) }
          end
        end
      end
    end
  end
end
