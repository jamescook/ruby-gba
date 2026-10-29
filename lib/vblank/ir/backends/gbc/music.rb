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

          # A PART'S ENTRY IN A SONG (#emit_song): its voice, its tone, how many notes each of its two
          # lists holds and where each is — and in a game whose songs are kept in banks, at ENTRY_BANK,
          # the bank they are in.
          ENTRY_BANK = 10

          def self.part_entry_bytes(banked) = ENTRY_BANK + (banked ? 1 : 0)

          # How many bytes a note takes in a part's list: when it starts, its tuning, its volume.
          NOTE_BYTES = 5

          # ...and in a game where a note slides its pitch, one more after them: the first square
          # voice's sweep register as the note sets it (Audio::PitchSlide#bits), 0 for a note that
          # holds its pitch. Its seven bits have nowhere else to go — the tuning and the volume have
          # five spare between them, and music converted from another game says a few dozen
          # different slides — so the byte is paid for by every note of such a game, and by no
          # other game's.
          #
          # In a game where a note plays from one speaker, one more after those: the speaker
          # (Audio::Pan.bits_of, nought for both). The volume's spare four bits could hold it, but
          # every reader of the volume would then have to take it out first.
          #
          # In a game where a square note says its shapes, one more after that: a square note's shapes
          # (Audio::Duty#bits) — its own, or its part's one — which the player writes the first of as
          # the note starts and steps through after.
          #
          # In a game where a note wobbles, two more after those: the note's vibrato
          # (Audio::Vibrato#bits, nought for a note that holds still), its depth and speed in the
          # first and its wait in the second, which the player keeps for the frames after.
          def self.note_bytes(slides, pans, shapes, wobbles)
            NOTE_BYTES + (slides ? 1 : 0) + (pans ? 1 : 0) + (shapes ? 1 : 0) + (wobbles ? 2 : 0)
          end

          # Whether any note of these lists (#notes) slides its pitch, whether any plays from one
          # speaker, whether any says its shapes, and whether any wobbles.
          def self.slides_in?(notes) = notes.each_value.any? { |list| list.any? { |note| VBlank::Audio::PitchSlide.moves?(note.slide) } }
          def self.pans_in?(notes) = notes.each_value.any? { |list| list.any?(&:side) }
          def self.shapes_in?(notes) = notes.each_value.any? { |list| list.any?(&:duty) }
          def self.wobbles_in?(notes) = notes.each_value.any? { |list| list.any? { |note| VBlank::Audio::Vibrato.moves?(note.vibrato) } }

          # One note of a part as the music table holds it, with what it is to the interpreter: the
          # song's name, the part, the voice it plays on, its pitch (0 for a rest), its volume, and
          # how it fades or swells, how it slides its pitch and how it wobbles when the note or its
          # part said so (IR::Tunes.said_fade, IR::Tunes.said_slide, IR::Tunes.said_vibrato), and
          # the speaker it plays from when it is one (IR::Tunes.note_side), and the shapes a square
          # note said (IR::Tunes.said_duty).
          Note = Data.define(:song, :part, :voice, :pitch, :volume, :fade, :slide, :vibrato, :side, :duty)

          # A NOTE'S FADE RIDES IN ITS TUNING'S TOP FOUR BITS, which a square or noise note never
          # uses: a square voice's period is eleven bits and the hiss's clock eight. The player
          # takes them out and puts them under the note's volume, where the voice's register keeps
          # them. A noise note that says a fade also sets NOISE_SAID_FADE, since a drum that says nothing
          # rings out as its part says and a fade of nothing — a hit that holds — would read the
          # same. A song that says nothing of fading has nothing there, and is the bytes it was.
          FADE_SHIFT = 12
          NOISE_SAID_FADE = 0x0800

          # A SOUND EFFECT as the Color's player reads it (Runtime::Effects): its name, its number
          # among the game's effects in the order declared, its rank as a number of a byte (#rank),
          # its group and priority, how many frames it lasts, and its parts.
          Effect = Data.define(:name, :number, :rank, :group, :priority, :total_frames, :parts)

          # A part of a sound effect: the voice it plays on, what the voice sounds like (as a song's
          # part has it, #tone_of), and the label of its notes and how many there are.
          EffectPart = Data.define(:voice, :tone, :label, :count)

          # +banked+ keeps each song's notes in the cartridge's banks rather than the part always in
          # view (#sections).
          def initialize(program, banked: false)
            @songs = program.walk.select { |node| node.kind == :song }.uniq(&:name)
            @effect_names = Tunes.effects(program).uniq
            @banked = banked
          end

          def banked? = @banked

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
          #
          # SONGS KEPT IN BANKS. The part of the cartridge always in view holds 16384 bytes, the
          # framework's own code among them, so a game with much music cannot keep every note there.
          # One whose songs do not fit (GBC#build) keeps each part's notes in a bank of the cartridge
          # instead, a section a part, and its entry says which bank; the player puts that bank in
          # view while it reads the part (Runtime::Music). What a song is — how long, its parts —
          # and the sound effects' notes stay in view.
          def sections
            asm = SM83.new("music", home: :fixed, holds: SONGS)
            asm.label("music_songs")
            @songs.each_index { |i| asm.data_words("music_song_#{i}") }
            parts = @songs.each_with_index.map { |song, i| emit_song(asm, song, i) }
            asm.label("music_waves")
            waveforms.each { |shape| asm.data_bytes(packed_waveform(shape)) }
            asm.data_bytes(0) # a label has to be somewhere
            emit_effects(asm) unless effects.empty?
            [asm.section, *parts.flatten]
          end

          # Every list of notes in the section, by its label: each note, in the order the list holds
          # them, NOTE_BYTES apart.
          def notes
            lists = @songs.each_with_index.each_with_object({}) do |(song, i), held_lists|
              passes = Tunes.loop_passes(song)
              voices_of(song).each_with_index do |(part, voice), p|
                pass = passes.fetch(song.voices.index(part))
                Music.lists_kept(pass).each do |which, held|
                  held_lists["music_notes_#{i}_#{p}_#{which}"] = held.map { |event| note_of(song, part, voice, event) }
                end
              end
            end
            effects.each do |effect|
              song = song_named(effect.name)
              voices_of(song).zip(effect.parts) do |(part, voice), played|
                lists[played.label] = part.events.map { |event| note_of(song, part, voice, event) }
              end
            end
            lists
          end

          # Whether any song or sound effect says how a note fades or swells: the player takes a
          # note's fade out of its tuning only in a game that has one to take.
          def fades?
            @songs.any? { |song| song.voices.any? { |part| part.events.any? { |event| Tunes.said_fade(part, event) } } }
          end

          # Whether any song or sound effect has a note that slides its pitch: only then does a note
          # carry a byte for it (.note_bytes), and the player write it.
          def slides?
            @slides = Music.slides_in?(notes) unless defined?(@slides)
            @slides
          end

          # ...and one that wobbles: only then does a note carry two bytes for it, and the player
          # move a voice's pitch a frame at a time.
          def wobbles?
            @wobbles = Music.wobbles_in?(notes) unless defined?(@wobbles)
            @wobbles
          end

          # ...and one that plays from one speaker: only then does a note carry a byte for it, and
          # the player set the speakers its voice plays from.
          def pans?
            @pans = Music.pans_in?(notes) unless defined?(@pans)
            @pans
          end

          # ...and one where a square note says its shapes: only then does a note carry a byte for
          # them, and the player step a square voice's shape a frame at a time.
          def shapes?
            @shapes = Music.shapes_in?(notes) unless defined?(@shapes)
            @shapes
          end

          # How many bytes a note of this game's takes (.note_bytes).
          def note_bytes = Music.note_bytes(slides?, pans?, shapes?, wobbles?)

          private

          def note_of(song, part, voice, event)
            _, pitch, _, volume = event
            Note.new(song: song.name, part: part, voice: voice, pitch: pitch, volume: volume || part.volume,
                     fade: (Tunes.said_fade(part, event) unless pitch.zero?),
                     slide: (Tunes.said_slide(part, event) unless pitch.zero?),
                     vibrato: (Tunes.said_vibrato(part, event) unless pitch.zero?),
                     side: (Tunes.note_side(part, event) unless pitch.zero?),
                     duty: (Tunes.said_duty(part, event) unless pitch.zero?))
          end

          # A note as the table holds it: when it starts, its tuning with its fade in the top bits
          # (FADE_SHIFT), and its volume — and in a game where a note slides, its slide, where one
          # plays from one speaker, its speaker, and where one wobbles, its vibrato (.note_bytes).
          def emit_note(asm, voice, part, event)
            at, pitch, _, volume = event
            asm.data_words(at, note_tuning(voice, part, event))
            asm.data_bytes(volume || part.volume)
            asm.data_bytes(pitch.zero? ? 0 : Tunes.said_slide(part, event)&.bits || 0) if slides?
            asm.data_bytes(pitch.zero? ? 0 : VBlank::Audio::Pan.bits_of(Tunes.note_side(part, event))) if pans?
            asm.data_bytes(note_shapes(part, event)) if shapes?
            return unless wobbles?

            wobble = Tunes.said_vibrato(part, event) unless pitch.zero?
            asm.data_words(VBlank::Audio::Vibrato.moves?(wobble) ? wobble.bits : 0)
          end

          # A note's shapes as its byte holds them: the ones it or its part said, or else its part's one.
          # A rest's, and every other voice's, are never read, so they are nought.
          def note_shapes(part, event)
            return 0 if event[1].zero? || Tunes.part_kind(part) != :square

            (Tunes.said_duty(part, event) || VBlank::Audio::Duty.one(part.duty)).bits
          end

          def note_tuning(voice, part, event)
            pitch = event[1]
            fade = Tunes.said_fade(part, event) unless pitch.zero?
            return tuning(voice, pitch) unless fade

            tuning(voice, pitch) | (fade.bits << FADE_SHIFT) | (voice == NOISE_VOICE ? NOISE_SAID_FADE : 0)
          end

          # Every rank the game's songs and sound effects can have, and nobody's, lowest first.
          def ranks
            @ranks ||= Tunes.ranks_in_order(@songs, @effect_names.map { |name| song_named(name) }).tap do |all|
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
                part.events.each { |event| emit_note(asm, voice, part, event) }
              end
            end
          end

          # Song number +i+ into +asm+: its entry, and its parts' notes after it — or, for songs kept
          # in banks, a section of each part's notes, handed back.
          def emit_song(asm, song, i)
            parts = voices_of(song)
            passes = Tunes.loop_passes(song)
            asm.label("music_song_#{i}")
            asm.data_words(song.total_frames, Tunes.loop_frame(song))
            asm.data_bytes(Tunes.plays_once?(song) ? 1 : 0, parts.length)
            parts.each_with_index do |(part, voice), p|
              pass = passes.fetch(song.voices.index(part))
              asm.data_bytes(voice, tone_of(part, voice))
              again = Music.again_shared?(pass) ? "first" : "again"
              asm.data_words(pass.first.length, pass.again.length, "music_notes_#{i}_#{p}_first", "music_notes_#{i}_#{p}_#{again}")
              asm.data_bank_of("music_notes_#{i}_#{p}_first") if banked?
            end
            parts.each_with_index.filter_map do |(part, voice), p|
              notes_asm = banked? ? SM83.new("music notes #{i} #{p}", home: :banked, holds: SONGS) : asm
              pass = passes.fetch(song.voices.index(part))
              Music.lists_kept(pass).each do |which, notes|
                notes_asm.label("music_notes_#{i}_#{p}_#{which}")
                notes.each { |event| emit_note(notes_asm, voice, part, event) }
              end
              next unless banked?

              notes_asm.data_bytes(0) if notes_asm.here.zero? # a label has to be somewhere
              notes_asm.section
            end
          end

          # A SONG THAT COMES ROUND FROM ITS START plays the same notes every time, so its list for
          # the times after the first is the first list, kept once (IR::Tunes.loop_passes).
          def self.again_shared?(pass) = pass.again == pass.first

          # The lists of notes a part's passes keep, by which pass they are: both, or the first alone
          # when the two are the same.
          def self.lists_kept(pass)
            again_shared?(pass) ? { "first" => pass.first } : { "first" => pass.first, "again" => pass.again }
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
            when NOISE_VOICE then sound.fade_step(part.decay) | (part.metallic ? 0x80 : 0)
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
