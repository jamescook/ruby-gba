# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Native
        # THE GAME'S SOUND, written as calls into runtime/rg_sound.h — mixed into Lowering the way
        # Picture is.
        #
        # What is played is a song's parts — on the console's two square-wave voices, its wave
        # voice and its noise voice, and on recordings through the mixer (runtime/rg_mix.h) — as
        # the interpreter's music player walks them, whether the game names the song or picks it
        # from a list by number; the sound effects played over the song; the game's own
        # recordings; and the beeps, `wave`, `stop_wave`, `noise` and `enable_sound` the game says
        # itself. Each goes into the sound log a test reads, in the interpreter's words (see
        # SoundLog).
        #
        # THE RULES OF THE VOICES are written into the game from Audio::Sound and IR::Tunes, as
        # numbers the runtime reads, rather than copied into the C: how fast each voice's clock
        # ticks, how many ticks a note lasts, how loud the wave voice is at each volume. So the
        # desktop build and the cartridge can never drift apart on what a note is.
        module Sound
          # The kinds of part the runtime plays, by the number it knows each as.
          PART_KINDS = { square: 0, wave: 1, noise: 2, recorded: 3 }.freeze

          private

          def prepare_sound
            @sound_log = SoundLog.new(@program)
          end

          def lower_enable_sound(_node) = [eval_call("rg_sound_enabled")]
          def lower_beep(node) = [eval_call("rg_sound_beep", C::Int.new(@sound_log.beep_number(node)))]
          def lower_wave(node) = [eval_call("rg_sound_wave", C::Int.new(@sound_log.wave_number(node)))]
          def lower_stop_wave(_node) = [eval_call("rg_sound_stop_wave")]
          def lower_noise(node) = [eval_call("rg_sound_noise", C::Int.new(@sound_log.noise_number(node)))]
          # Named `this_frame: true`, the tune starts where it is named (rg_music_start_here).
          def lower_play_song(node)
            [eval_call("rg_music_request", C::Int.new(@sound_log.song_number(node.name))),
             *(eval_call("rg_music_start_here") if node.this_frame)]
          end
          def lower_stop_music(_node) = [eval_call("rg_music_stop")]

          # A song picked from a list by a number the game works out: the list is written as the
          # numbers of its songs, and the runtime picks one, or leaves the music alone for a
          # number naming none.
          def lower_play_from_list(node)
            [eval_call(node.this_frame ? "rg_music_start_here_one_of" : "rg_music_request_one_of", song_list_name(node.name),
                       C::Int.new(song_lists.fetch(node.name).songs.size), value(node.which))]
          end

          def song_lists = @song_lists ||= @program.walk.select { |node| node.kind == :song_list }.to_h { |node| [node.name, node] }
          def song_list_name(name) = @names.of(:song_list, name)

          # A sound effect picked from a list by a number the game works out, the same way: the
          # list is written as the numbers of its effects (SoundLog#effect_number).
          def lower_play_sound_effect(node)
            [eval_call(node.this_frame ? "rg_effect_start_here_one_of" : "rg_effect_request_one_of", effect_list_name(node.name),
                       C::Int.new(effect_lists.fetch(node.name).effects.size), value(node.which))]
          end

          def effect_lists
            @effect_lists ||= @program.walk.select { |node| node.kind == :sound_effect_list }.to_h { |node| [node.name, node] }
          end

          def effect_list_name(name) = @names.of(:sound_effect_list, name)

          # --- recordings, through the mixer (runtime/rg_mix.h) ---

          # The game's own `play` of a recording. Everything about it is fixed when the game is
          # built — the pitch it reads at, how loud, how far back it reads at its end — so it is
          # worked out here, the interpreter's way (Reference::Mixer#start), and handed over as
          # numbers.
          def lower_play_sample(node)
            sample = @sound_log.recording(node.name)
            info = Assets::Sample.of(sample)
            frequency = RubyGBA::Audio::Music::NOTE_FREQUENCIES.fetch(node.pitch || info.note || :C4)
            back = node.loop ? (info.loop_length.positive? ? info.loop_length : info.length) : 0
            levels = RubyGBA::Audio::Sound::MIX_LEVELS
            [eval_call("rg_mix_play", C::Int.new(@sound_log.recording_number(node.name)),
                       C::Int.new(Mixing.step(info, frequency, mix_clock.rate)),
                       C::Int.new(levels.fetch(node.volume, levels[:full])), C::Int.new(back),
                       C::Int.new(node.loop ? 1 : 0))]
          end

          # ...and its `stop`, of one recording or, with no name, of every one the game plays.
          def lower_stop_sample(node)
            [eval_call("rg_mix_stop", C::Int.new(node.name ? @sound_log.recording_number(node.name) : -1))]
          end

          # The rate the mix runs at and how many samples a frame holds: the console's own clock
          # for the rate the game's recordings ask for, as the interpreter takes it.
          def mix_clock = @mix_clock ||= GBA::Timers.sample_clock(Mixing.requested_rate(@program))

          # How the mix runs (see the layout atop runtime/rg_mix.c).
          def mix_table
            sound = RubyGBA::Audio::Sound
            envelope = RubyGBA::Audio::Envelope
            mixes = Mixing.mixes?(@program)
            samples = mixes ? mix_clock.samples_a_frame : 0
            sound_table("mix", [mixes ? 1 : 0, samples, Mixing.shapes_any_note?(@program) ? 1 : 0,
                                mixes ? Mixing.slide_share(samples) : 0, sound::MIXER_VOICES, sound::VOL_SHIFT,
                                sound::STEP_SHIFT, sound::GAIN_FRACTION, sound::RAMP_SPLIT, envelope::FULL, envelope::SCALE])
          end

          # Every recording the game declares, seven numbers each; and all their samples, in an
          # array of bytes of their own, since a sample is one and recordings can be most of a
          # game's sound.
          def recordings_tables
            recordings = @sound_log.recordings
            at = 0
            heads = recordings.map do |sample|
              info = Assets::Sample.of(sample)
              shape = info.envelope && !info.envelope.plain? ? info.envelope : nil
              head = [at, info.length, shape ? 1 : 0,
                      *(shape ? [shape.attack, shape.decay, shape.sustain, shape.release] : [0, 0, 0, 0])]
              at += info.length
              head
            end
            samples = recordings.flat_map { |sample| sample.bytes.unpack("c*") }
            [sound_table("recordings", [recordings.size, *heads.flatten]),
             C::ConstArray.new(name: @names.own("recording_samples"), type: "int8_t", values: samples, exported: true)]
          end

          # Each song list a run can pick from, as the numbers of its songs.
          def song_list_tables
            picked = @reachable.filter_map { |node| node.name if node.kind == :play_from_list }.uniq
            picked.map do |name|
              C::ConstArray.new(name: song_list_name(name), type: "int32_t",
                                values: song_lists.fetch(name).songs.map { |song| @sound_log.song_number(song) })
            end
          end

          # Each sound effect list a run can play from, as the numbers of its effects.
          def effect_list_tables
            played = @reachable.filter_map { |node| node.name if node.kind == :play_sound_effect }.uniq
            played.map do |name|
              C::ConstArray.new(name: effect_list_name(name), type: "int32_t",
                                values: effect_lists.fetch(name).effects.map { |effect| @sound_log.effect_number(effect) })
            end
          end

          # Every sound effect, in the order declared, as the player reads it (see the layout atop
          # runtime/rg_sound.c): whether any of them plays the wave voice, which changes how that
          # voice's waveform is put in; then each one's song, where its notes are, rank, group and
          # priority; and then the effects again, highest rank first, which is the order a frame
          # plays them in.
          def effects_table
            songs = @sound_log.sound_effects.map { |name| @sound_log.song(name) }
            groups = songs.filter_map(&:group).uniq
            rows = songs.each_with_index.map do |song, order|
              rank = Tunes.effect_rank(song, order)
              [@sound_log.song_number(song.name), effect_notes_number(song.name), rank,
               song.group ? groups.index(song.group) : -1, Tunes.priority_of(rank)]
            end
            by_rank = Tunes.effects_by_rank(songs).map { |name, _| @sound_log.effect_number(name) }
            plays_wave = songs.any? { |song| Tunes.parts_on(song, :wave).positive? }
            sound_table("effects", [rows.size, plays_wave ? 1 : 0, *rows.flatten, *by_rank])
          end

          # The player reads the music volume the game keeps, when it keeps one: a game that never
          # says `music_volume` plays every part at its written volume with nothing worked out.
          def sound_power_on
            return [] unless variable_names.include?(Tunes::LEVEL)

            [eval_call("rg_music_follow_level", C::AddressOf.new(variable(Tunes::LEVEL)))]
          end

          # Everything about the game's sound that the runtime reads, as arrays of whole numbers
          # (their layouts are atop runtime/rg_sound.c).
          def sound_tables
            # The music is written first: writing it is what finds the rows of note_sounds_table.
            [sound_rules_table, waveform_table, music_table, note_sounds_table, effects_table, beep_table, wave_table,
             hit_table, mix_table, *recordings_tables, *song_list_tables, *effect_list_tables]
          end

          def sound_table(name, values)
            C::ConstArray.new(name: @names.own(name), type: "int32_t", values: values, exported: true)
          end

          # The rules every voice keeps: how fast each one's clock ticks, how often the console
          # hands its voices on to the speaker, the music volume a part sounds at in full and how
          # far to shift back down by it, the wave voice's loudness for each written volume, and
          # the part of a rank that tells a sound effect from the song.
          def sound_rules_table
            sound = RubyGBA::Audio::Sound
            quarters = (0..15).map { |volume| sound.wave_level_quarters(sound.wave_level(volume)) }
            sound_table("sound_rules", [sound::SQUARE_CLOCK_HZ, sound::WAVE_CLOCK_HZ, sound::NOISE_CLOCK_HZ,
                                        sound::VOICE_OUTPUT_HZ, Tunes::FULL_LEVEL, Tunes::LEVEL_SHIFT, *quarters,
                                        Tunes::ORDER_MASK])
          end

          # Every different waveform the game can put on the wave voice, 32 steps each: the ones
          # its `wave`s name and the ones its songs' parts play.
          def waveforms
            @waveforms ||= begin
              said = @sound_log.waves.map { |wave| wave.fetch(:shape) }
              played = @sound_log.songs.flat_map { |song| song.voices.filter_map(&:wave) }
              (said + played).map { |shape| RubyGBA::Audio::Sound.wavetable(shape) }.uniq
            end
          end

          def waveform_number(shape) = waveforms.index(RubyGBA::Audio::Sound.wavetable(shape))

          def waveform_table = sound_table("waveforms", [waveforms.size, *waveforms.flatten])

          # How many beeps the game makes, and each as the runtime reads it: how long one wave
          # lasts, how much of it is high, the volume it starts at, and how long it holds each step
          # of volume as it fades.
          def beep_table
            rows = @sound_log.effects.map do |effect|
              [RubyGBA::Audio::Sound.square_wave_ticks(effect.frequency), RubyGBA::Audio::Sound::SQUARE_HIGH_EIGHTHS.fetch(effect.duty),
               effect.volume, RubyGBA::Audio::Sound::FADE_STEP_SIXTY_FOURTHS.fetch(effect.decay)]
            end
            sound_table("beeps", [rows.size, *rows.flatten])
          end

          # Each different `wave` the game says: which waveform, how long one wave of it lasts,
          # and how many quarters of each step its loudness keeps.
          def wave_table
            sound = RubyGBA::Audio::Sound
            rows = @sound_log.waves.map do |wave|
              [waveform_number(wave.fetch(:shape)), sound.wave_voice_ticks(wave.fetch(:frequency)),
               sound.wave_level_quarters(wave.fetch(:volume))]
            end
            sound_table("waves", [rows.size, *rows.flatten])
          end

          # Each different hit the game makes with `noise`: how long a step of its hiss lasts, how
          # many bits its pattern comes out of, the volume it starts at, and how long it holds
          # each step of volume as it fades.
          def hit_table
            sound = RubyGBA::Audio::Sound
            rows = @sound_log.hits.map do |hit|
              [sound.noise_hit_step_ticks(hit.fetch(:pitch)), sound.noise_register_bits(hit.fetch(:metallic)),
               hit.fetch(:volume), sound::FADE_STEP_SIXTY_FOURTHS.fetch(hit.fetch(:decay))]
            end
            sound_table("hits", [rows.size, *rows.flatten])
          end

          # Every song, as the runtime reads them: how many there are, where each starts, and
          # then the songs.
          def music_table
            songs = @sound_log.songs.map { |song| encoded_song(song, Tunes.loop_passes(song)) }
            effects = @sound_log.sound_effects.map { |name| encoded_effect(@sound_log.song(name)) }
            starts = []
            at = 1 + songs.size + effects.size # past the count and the starts themselves
            (songs + effects).each do |numbers|
              starts << at
              at += numbers.size
            end
            sound_table("music", [songs.size + effects.size, *starts, *songs.flatten, *effects.flatten])
          end

          # A SOUND EFFECT'S NOTES, written again after every song. It plays once and never comes
          # round, so each part is its notes as written, as the interpreter's player walks them —
          # where the same Score played as a tune (a game may name it in `play_song`) is put right
          # for coming round (Tunes.loop_passes), which can add a rest the effect does not have.
          def encoded_effect(song)
            encoded_song(song, song.voices.map { |part| Tunes::Pass.new(first: part.events, again: []) })
          end

          # Where each effect's notes are in the music table: after every song, in the order the
          # effects were declared.
          def effect_notes_number(name) = @sound_log.songs.size + @sound_log.effect_number(name)

          # One song as numbers: its length, where it loops from, whether it plays once and ends,
          # its rank, and each part, with its notes the first time through and every time after
          # (+passes+). Every song the game declares is written, played or not, so the numbering is
          # the one SoundLog gives.
          def encoded_song(song, passes)
            lanes = 0
            parts = song.voices.each_with_index.zip(passes).map do |(part, number), pass|
              lane = Tunes.part_kind(part) == :recorded ? (lanes += 1) - 1 : nil
              encoded_part(part, number, pass, lane)
            end
            [song.total_frames, Tunes.loop_frame(song), Tunes.plays_once?(song) ? 1 : 0, Tunes.song_rank(song),
             parts.size, *parts.flatten]
          end

          # A part: which kind of voice it plays on, which of its song's parts it is, the two
          # things that say what its voice sounds like, and its notes. A recorded part's +lane+ is
          # which of the song's recorded parts it is.
          def encoded_part(part, number, pass, lane)
            kind = Tunes.part_kind(part)
            [PART_KINDS.fetch(kind), number, *part_tone(kind, part, lane), pass.first.size, pass.again.size,
             *(pass.first + pass.again).flat_map { |note| encoded_note(note, part, kind) }]
          end

          # What a part's voice sounds like, as two numbers. A square part: how many eighths of
          # its wave are high. A wave part: which waveform. A noise part: how many bits its hiss
          # comes out of, and how long a hit holds each step of volume as it fades. A recorded
          # part: its lane, since each note says what it sounds like.
          def part_tone(kind, part, lane)
            sound = RubyGBA::Audio::Sound
            case kind
            when :square then [sound::SQUARE_HIGH_EIGHTHS.fetch(part.duty), 0]
            when :wave then [waveform_number(part.wave), 0]
            when :noise then [sound.noise_register_bits(part.metallic), sound::FADE_STEP_SIXTY_FOURTHS.fetch(part.decay)]
            when :recorded then [lane, 0]
            end
          end

          # A note as the runtime reads it: when it starts, which of the songs' pitches it is (0 is
          # a rest; see SoundLog#pitch_number), its volume, and how many ticks of its voice's
          # clock it lasts — one wave of it on a square voice or the wave voice, one step of the
          # hiss on the noise voice — or, on a recorded part, the row of note_sounds_table it
          # sounds. A recorded note's volume is written as its loudness on the mixer, since it can
          # hold a fraction.
          def encoded_note(note, part, kind)
            at, pitch, _, volume = note
            volume ||= part.volume
            heard, last = if kind == :recorded
                            [Tunes.mix_loudness(volume), pitch.zero? ? -1 : note_sound_row(note, part)]
                          else
                            [volume, pitch.zero? ? 0 : note_ticks(kind, pitch)]
                          end
            [at, @sound_log.pitch_number(pitch), heard, last]
          end

          # EVERYTHING A RECORDED NOTE IS BUT HOW LOUD, the interpreter's way
          # (Reference::Player#play_song_frame and Mixer#start_music_note): the recording — the
          # note's own, else its part's — read at the note's pitch, going back as far as it holds,
          # and shaped by the note's own shape, else its part's, else its recording's. Notes alike
          # share a row.
          def note_sound_row(note, part)
            _, pitch, instrument, _, envelope = note
            sample = @sound_log.recording(instrument || part.instrument)
            info = Assets::Sample.of(sample)
            shape = envelope || part.envelope || info.envelope
            shape = nil if shape&.plain?
            row = [@sound_log.recording_number(sample.name), Mixing.step(info, pitch, mix_clock.rate), info.loop_length,
                   shape ? 1 : 0, *(shape ? [shape.attack, shape.decay, shape.sustain, shape.release] : [0, 0, 0, 0])]
            note_sounds.index(row) || (note_sounds << row).size - 1
          end

          def note_sounds = @note_sounds ||= []

          def note_sounds_table = sound_table("note_sounds", [note_sounds.size, *note_sounds.flatten])

          def note_ticks(kind, pitch)
            sound = RubyGBA::Audio::Sound
            case kind
            when :square then sound.square_wave_ticks(pitch)
            when :wave then sound.wave_voice_ticks(pitch)
            when :noise then sound.noise_note_step_ticks(pitch)
            end
          end
        end
      end
    end
  end
end
