# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Native
        # THE GAME'S SOUND, written as calls into runtime/rg_sound.h — mixed into Lowering the way
        # Picture is.
        #
        # What is played is what the console's own four voices play: a song's parts on the two
        # square-wave voices, the wave voice and the noise voice, as the interpreter's music
        # player walks them, whether the game names the song or picks it from a list by number,
        # and the beeps, `wave`, `stop_wave`, `noise` and `enable_sound` the game says itself.
        # Each goes into the sound log a test reads, in the interpreter's words (see SoundLog).
        # The game's own recordings play through the mixer (runtime/rg_mix.h). The rest — sound
        # effect lists, and a song with a part that plays a recording — is refused by name
        # (NOT_LOWERED_YET, and #refuse_unplayable_songs!), rather than left out of what the game
        # plays.
        #
        # THE RULES OF THE VOICES are written into the game from Audio::Sound and IR::Tunes, as
        # numbers the runtime reads, rather than copied into the C: how fast each voice's clock
        # ticks, how many ticks a note lasts, how loud the wave voice is at each volume. So the
        # desktop build and the cartridge can never drift apart on what a note is.
        module Sound
          # The kinds of part the runtime plays, by the number it knows each as.
          PART_KINDS = { square: 0, wave: 1, noise: 2 }.freeze

          private

          def prepare_sound
            @sound_log = SoundLog.new(@program)
          end

          def lower_enable_sound(_node) = [eval_call("rg_sound_enabled")]
          def lower_beep(node) = [eval_call("rg_sound_beep", C::Int.new(@sound_log.beep_number(node)))]
          def lower_wave(node) = [eval_call("rg_sound_wave", C::Int.new(@sound_log.wave_number(node)))]
          def lower_stop_wave(_node) = [eval_call("rg_sound_stop_wave")]
          def lower_noise(node) = [eval_call("rg_sound_noise", C::Int.new(@sound_log.noise_number(node)))]
          def lower_play_song(node) = [eval_call("rg_music_request", C::Int.new(@sound_log.song_number(node.name)))]
          def lower_stop_music(_node) = [eval_call("rg_music_stop")]

          # A song picked from a list by a number the game works out: the list is written as the
          # numbers of its songs, and the runtime picks one, or leaves the music alone for a
          # number naming none.
          def lower_play_from_list(node)
            [eval_call("rg_music_request_one_of", song_list_name(node.name),
                       C::Int.new(song_lists.fetch(node.name).songs.size), value(node.which))]
          end

          def song_lists = @song_lists ||= @program.walk.select { |node| node.kind == :song_list }.to_h { |node| [node.name, node] }
          def song_list_name(name) = @names.of(:song_list, name)

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
                       C::Int.new(levels.fetch(node.volume, levels[:full])), C::Int.new(back))]
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

          # Every recording the game declares, seven numbers each, and then all their samples.
          def recordings_table
            recordings = @sound_log.recordings
            at = 1 + (7 * recordings.size)
            heads = recordings.map do |sample|
              info = Assets::Sample.of(sample)
              shape = info.envelope && !info.envelope.plain? ? info.envelope : nil
              head = [at, info.length, shape ? 1 : 0,
                      *(shape ? [shape.attack, shape.decay, shape.sustain, shape.release] : [0, 0, 0, 0])]
              at += info.length
              head
            end
            sound_table("recordings", [recordings.size, *heads.flatten, *recordings.flat_map { |sample| sample.bytes.unpack("c*") }])
          end

          # Each song list a run can pick from, as the numbers of its songs.
          def song_list_tables
            picked = @reachable.filter_map { |node| node.name if node.kind == :play_from_list }.uniq
            picked.map do |name|
              C::ConstArray.new(name: song_list_name(name), type: "int32_t",
                                values: song_lists.fetch(name).songs.map { |song| @sound_log.song_number(song) })
            end
          end

          # A song the game plays with a part that plays a recording: the desktop build cannot
          # play that part yet, and playing the rest without it would be a different tune. A song
          # in a list the game picks from is one it can play.
          def refuse_unplayable_songs!
            played = @reachable.flat_map do |node|
              case node.kind
              when :play_song then [node.name]
              when :play_from_list then song_lists.fetch(node.name).songs
              else []
              end
            end
            @sound_log.songs.select { |song| played.include?(song.name) }.each do |song|
              next unless Tunes.recorded_parts(song).positive?

              raise LoweringError,
                    "song #{song.name.inspect} has a part that plays a recording, which the desktop build " \
                    "cannot play yet. It plays parts on the square wave, the wave voice and the noise voice. " \
                    "The cartridge build can play it."
            end
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
            [sound_rules_table, waveform_table, music_table, beep_table, wave_table, hit_table, mix_table,
             recordings_table, *song_list_tables]
          end

          def sound_table(name, values)
            C::ConstArray.new(name: @names.own(name), type: "int32_t", values: values, exported: true)
          end

          # The rules every voice keeps: how fast each one's clock ticks, how often the console
          # hands its voices on to the speaker, the music volume a part sounds at in full and how
          # far to shift back down by it, and the wave voice's loudness for each written volume.
          def sound_rules_table
            sound = RubyGBA::Audio::Sound
            quarters = (0..15).map { |volume| sound.wave_level_quarters(sound.wave_level(volume)) }
            sound_table("sound_rules", [sound::SQUARE_CLOCK_HZ, sound::WAVE_CLOCK_HZ, sound::NOISE_CLOCK_HZ,
                                        sound::VOICE_OUTPUT_HZ, Tunes::FULL_LEVEL, Tunes::LEVEL_SHIFT, *quarters])
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
            songs = @sound_log.songs.map { |song| encoded_song(song) }
            starts = []
            at = 1 + songs.size # past the count and the starts themselves
            songs.each do |numbers|
              starts << at
              at += numbers.size
            end
            sound_table("music", [songs.size, *starts, *songs.flatten])
          end

          # One song as numbers: its length, where it loops from, whether it plays once and ends,
          # and each part the console's own voices play, with its notes the first time through
          # and every time after. Every song the game declares is written, played or not, so the
          # numbering is the one SoundLog gives; a song nothing plays is never refused for its
          # voices, and a part of it that plays a recording is left out.
          def encoded_song(song)
            parts = song.voices.each_with_index.zip(Tunes.loop_passes(song))
                        .reject { |(part, _), _| Tunes.part_kind(part) == :recorded }
            [song.total_frames, Tunes.loop_frame(song), Tunes.plays_once?(song) ? 1 : 0, parts.size,
             *parts.flat_map { |(part, number), pass| encoded_part(part, number, pass) }]
          end

          # A part: which kind of voice it plays on, which of its song's parts it is, the two
          # things that say what its voice sounds like, and its notes.
          def encoded_part(part, number, pass)
            kind = Tunes.part_kind(part)
            [PART_KINDS.fetch(kind), number, *part_tone(kind, part), pass.first.size, pass.again.size,
             *(pass.first + pass.again).flat_map { |note| encoded_note(note, part, kind) }]
          end

          # What a part's voice sounds like, as two numbers. A square part: how many eighths of
          # its wave are high. A wave part: which waveform. A noise part: how many bits its hiss
          # comes out of, and how long a hit holds each step of volume as it fades.
          def part_tone(kind, part)
            sound = RubyGBA::Audio::Sound
            case kind
            when :square then [sound::SQUARE_HIGH_EIGHTHS.fetch(part.duty), 0]
            when :wave then [waveform_number(part.wave), 0]
            when :noise then [sound.noise_register_bits(part.metallic), sound::FADE_STEP_SIXTY_FOURTHS.fetch(part.decay)]
            end
          end

          # A note as the runtime reads it: when it starts, which of the songs' pitches it is (0 is
          # a rest; see SoundLog#pitch_number), its volume, and how many ticks of its voice's
          # clock it lasts — one wave of it on a square voice or the wave voice, one step of the
          # hiss on the noise voice.
          def encoded_note(note, part, kind)
            at, pitch, _, volume = note
            [at, @sound_log.pitch_number(pitch), volume || part.volume, pitch.zero? ? 0 : note_ticks(kind, pitch)]
          end

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
