# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        class Lowering
          # THE SOUND, lowered for a Game Boy Color: a beep, a hit on the noise voice and a tone on
          # the wave voice as a row of writes to the Color's sound registers, which the runtime makes
          # where the game says the word (Runtime::Sound, GBC::SoundRegisters); and the songs, which
          # the music player walks each frame (GBC::Music, Runtime::Music). Mixed into Lowering.
          module Sound
            STATEMENTS = Ractor.make_shareable({
                                                 enable_sound: :emit_enable_sound, beep: :emit_beep,
                                                 noise: :emit_noise, wave: :emit_wave, stop_wave: :emit_stop_wave,
                                                 play_song: :emit_play_song, stop_music: :emit_stop_music,
                                                 play_from_list: :emit_play_from_list,
                                                 play_sound_effect: :emit_play_sound_effect,
                                                 play_sample: :emit_play_sample, stop_sample: :emit_stop_sample,
                                                 rumble: :emit_rumble
                                               })

            # The game's songs, as the player reads them; and its recordings, as a bit a sample.
            attr_reader :music, :clips

            # What each table of writes plays, by its label, as the interpreter logs it
            # (Reference#audio): what a run of the cartridge reads back its sounds by (GBC::SoundLog).
            attr_reader :sound_tables

            # Where the game keeps how loud its music is, or nil for a game that never says.
            def music_level = @variables[Tunes::LEVEL]

            # Does a song's square note swell by itself in a game that moves the music volume? Asked
            # before the variables have places, so the player can keep room to hold one there
            # (Runtime::Music#emit_swells).
            def holds_swells?
              @program.walk.any? { |node| node.kind == :set && node.var == Tunes::LEVEL } &&
                Tunes.swelling_square_notes?(@program)
            end

            # Does the game run the cartridge's motor? Then its cartridge says it carries one.
            def rumbles? = @reachable.any? { |node| node.kind == :rumble }

            private

            def prepare_sound
              @defined_sounds = @program.walk.select { |node| node.kind == :define_sound }.to_h { |node| [node.name, node.effect] }
              @music = Music.new(@program, banked: @banked_songs)
              @clips = Clips.new(@program)
              @sound_tables = {}
            end

            # Reference::Mixer#start: the recording's clip at the note named from its start, unless one
            # is playing (Runtime::Clips), at the wave voice's level for the volume named, looping or
            # not. Logged either way, as the interpreter logs a play it drops; the log goes through a
            # table of no writes, which is how every sound the game makes reaches the run's log
            # (GBC::SoundLog).
            def emit_play_sample(node)
              sound_writes([], [:sample, node.name])
              @asm.load(:a, @clips.entry(node.name, node.pitch))
              @asm.load(:b, Runtime::Clips::LEVELS.fetch(node.volume))
              @asm.load(:d, node.loop ? 1 : 0) if @clips.loops?
              @asm.call("rt_clip_play")
            end

            # Reference::Mixer#stop: the recording named, or whichever is playing for none, stopped.
            # One the game never plays is never playing, so nothing is stopped for it.
            def emit_stop_sample(node)
              sound_writes([], [:stop_sample])
              return if node.name && !@clips.plays?(node.name)

              @asm.load(:a, node.name ? @clips.recording(node.name) : Runtime::Clips::ALL)
              @asm.call("rt_clip_stop")
            end

            # Reference#exec_play_song: the tune named, from the next frame, unless it is the one
            # named already. Named `this_frame: true` it takes its first frame where it is named.
            def emit_play_song(node)
              runtime_call(node.this_frame ? "rt_music_play_now" : "rt_music_play", [Build.int(@music.number(node.name))])
            end

            # Reference::Player#request_song_at: one of a list's songs by a number the game works out —
            # a table of the songs' numbers, read at the number when it names one of them, and nothing
            # played when it names none.
            def emit_play_from_list(node)
              songs = song_list(node.name).songs
              table = drawing_table("song_list", 1, songs.map { |song| @music.number(song) })
              past = fresh("past_the_song")
              value(node.which)
              @asm.load(:a, :b)
              @asm.or_a(:c)
              @asm.or_a(:d)
              @asm.jump(:nz, past) # below nought, or far past the list
              @asm.load(:a, :e)
              @asm.cp_a(songs.length)
              @asm.jump(:nc, past)
              @asm.load(:hl, table)
              @asm.load(:d, 0)
              @asm.add_hl(:de)
              @asm.load(:a, [:hl])
              @asm.load(:e, :a)
              2.times { @asm.push(:de) } # the song's number, as a four-byte argument
              @asm.call(node.this_frame ? "rt_music_play_now" : "rt_music_play")
              @asm.add_sp(4)
              @asm.label(past)
            end

            # Reference::Player#request_effect: one of a list's sound effects by a number the game
            # works out, asked for at the next frame — or at once, `this_frame: true` — and nothing
            # played for a number naming none. Each effect has its own routine to ask for it with
            # (Runtime::Effects#emit_ask), so the number picks the routine.
            def emit_play_sound_effect(node)
              list = effect_list(node.name)
              numbers = @music.effects.to_h { |effect| [effect.name, effect.number] }
              past = fresh("past_the_effect")
              value(node.which)
              @asm.load(:a, :b)
              @asm.or_a(:c)
              @asm.or_a(:d)
              @asm.jump(:nz, past) # below nought, or far past the list
              list.effects.each_with_index do |name, i|
                other = fresh("not_effect_#{i}")
                @asm.load(:a, :e)
                @asm.cp_a(i)
                @asm.jump(:nz, other)
                @asm.call("rt_sfx_#{node.this_frame ? 'now' : 'ask'}_#{numbers.fetch(name)}")
                @asm.jump(past)
                @asm.label(other)
              end
              @asm.label(past)
            end

            def effect_list(name)
              @effect_lists ||= @program.walk.select { |node| node.kind == :sound_effect_list }.to_h { |node| [node.name, node] }
              @effect_lists.fetch(name) { raise LoweringError, "play_sound_effect of undefined list #{name.inspect}" }
            end

            def song_list(name)
              @song_lists ||= @program.walk.select { |node| node.kind == :song_list }.to_h { |node| [node.name, node] }
              @song_lists.fetch(name) { raise LoweringError, "play_from_list of undefined list #{name.inspect}" }
            end

            def emit_stop_music(_node) = @asm.call("rt_music_stop")

            def emit_enable_sound(_node) = sound_writes(VBlank::Audio::Sound::Registers.enable, [:enabled])

            # Reference#exec_rumble: the cartridge's motor, a frame at a time (Runtime::Rumble).
            def emit_rumble(node) = runtime_call("rt_rumble", [node.frames, node.pattern])

            # A CARTRIDGE WITH A CLOCK HAS NO MOTOR: the Color's cartridges with a clock chip carry
            # an MBC3 (Lowering::Clock), and its rumble cartridges an MBC5, and none was made with both.
            def refuse_rumble_beside_clock!
              return unless rumbles? && clock?

              raise LoweringError, "this game uses `clock` and `rumble`. A Game Boy Color cartridge with a clock " \
                                   "has no rumble motor. To fix this, remove `rumble`, or remove `clock`."
            end

            def emit_beep(node)
              effect = VBlank::Audio::Sound.resolve_effect(node.tone, duty: node.duty, decay: node.decay,
                                                            volume: node.volume, defined: @defined_sounds)
              emit_stop_wobble(BEEP_VOICE)
              Runtime::Music.emit_end_shapes(@asm, @memory, BEEP_VOICE)
              Runtime::Music.emit_end_swell(@asm, @memory, BEEP_VOICE)
              emit_speakers_both(BEEP_VOICE)
              sound_writes(VBlank::Audio::Sound::Registers.beep_writes(**effect.to_h), [:beep, effect])
            end

            # The game's own sound on +voice+ plays from both speakers, whichever a song's note left
            # its voice at (Runtime::Music#emit_set_speakers). The screen's interrupt, where the player
            # sets a voice's speakers, is held off while they are read and written, so it cannot set
            # one between the two and have it undone. Nothing in a game where every note plays from
            # both.
            def emit_speakers_both(voice)
              return unless @music.pans?

              @asm.di
              @asm.load_high(:a, Console::GBCHardware::NR51)
              @asm.or_a(0x11 << (voice - 1))
              @asm.load_high(Console::GBCHardware::NR51, :a)
              @asm.ei
            end

            # The square voice a `beep` plays on, the song's second square part's.
            BEEP_VOICE = 2

            # THE GAME'S OWN SOUND TAKES +voice+, so it wobbles no song's note (Runtime::Music#emit_wobbles)
            # — said before the sound is written, so a frame of the player in between writes the song's
            # pitch under the game's sound and not over it. Nothing in a game where no note wobbles.
            def emit_stop_wobble(voice)
              return unless Runtime::Music.wobbles?(@memory)

              @asm.xor_a(:a)
              @asm.load([@memory[Runtime::Music::WOBBLES] + ((voice - 1) * Runtime::Music::WOBBLE_BYTES)], :a)
            end

            def emit_noise(node)
              hit = VBlank::Audio::Sound.resolve_noise(node.preset, pitch: node.pitch, decay: node.decay,
                                                        volume: node.volume, metallic: node.metallic)
              emit_speakers_both(GBC::Music::NOISE_VOICE)
              sound_writes(VBlank::Audio::Sound::Registers.noise_hit_writes(**hit), [:noise, hit])
            end

            def emit_wave(node)
              samples = VBlank::Audio::Sound.wavetable(node.shape)
              emit_stop_wobble(GBC::Music::WAVE_VOICE)
              emit_speakers_both(GBC::Music::WAVE_VOICE)
              sound_writes(VBlank::Audio::Sound::Registers.wave_start_writes(samples, frequency: node.frequency,
                                                                                        volume: node.volume),
                           [:wave, { shape: node.shape, frequency: node.frequency, volume: node.volume }])
            end

            def emit_stop_wave(_node)
              emit_stop_wobble(GBC::Music::WAVE_VOICE)
              sound_writes(VBlank::Audio::Sound::Registers.wave_stop, [:stop_wave])
            end

            # The writes as a table of the Color's (SoundRegisters), made where the game says the word;
            # +logged+ is what the interpreter logs for the word.
            def sound_writes(writes, logged)
              label = drawing_table("sound_writes", 1, SoundRegisters.table(writes))
              @sound_tables[label] = logged unless @measuring # a measured routine's tables are thrown away
              runtime_call("rt_sound_writes", [Address.new(label)])
            end
          end
        end
      end
    end
  end
end
