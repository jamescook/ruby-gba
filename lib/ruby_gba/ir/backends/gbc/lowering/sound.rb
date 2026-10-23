# frozen_string_literal: true

module RubyGBA
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
                                                 play_from_list: :emit_play_from_list
                                               })

            # The game's songs, as the player reads them.
            attr_reader :music

            # What each table of writes plays, by its label, as the interpreter logs it
            # (Reference#audio): what a run of the cartridge reads back its sounds by (GBC::SoundLog).
            attr_reader :sound_tables

            # Where the game keeps how loud its music is, or nil for a game that never says.
            def music_level = @variables[Tunes::LEVEL]

            private

            def prepare_sound
              @defined_sounds = @program.walk.select { |node| node.kind == :define_sound }.to_h { |node| [node.name, node.effect] }
              @music = Music.new(@program)
              @sound_tables = {}
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

            def song_list(name)
              @song_lists ||= @program.walk.select { |node| node.kind == :song_list }.to_h { |node| [node.name, node] }
              @song_lists.fetch(name) { raise LoweringError, "play_from_list of undefined list #{name.inspect}" }
            end

            def emit_stop_music(_node) = @asm.call("rt_music_stop")

            def emit_enable_sound(_node) = sound_writes(RubyGBA::Audio::Sound::Registers.enable, [:enabled])

            def emit_beep(node)
              effect = RubyGBA::Audio::Sound.resolve_effect(node.tone, duty: node.duty, decay: node.decay,
                                                            volume: node.volume, defined: @defined_sounds)
              sound_writes(RubyGBA::Audio::Sound::Registers.beep_writes(**effect.to_h), [:beep, effect])
            end

            def emit_noise(node)
              hit = RubyGBA::Audio::Sound.resolve_noise(node.preset, pitch: node.pitch, decay: node.decay,
                                                        volume: node.volume, metallic: node.metallic)
              sound_writes(RubyGBA::Audio::Sound::Registers.noise_hit_writes(**hit), [:noise, hit])
            end

            def emit_wave(node)
              samples = RubyGBA::Audio::Sound.wavetable(node.shape)
              sound_writes(RubyGBA::Audio::Sound::Registers.wave_start_writes(samples, frequency: node.frequency,
                                                                                        volume: node.volume),
                           [:wave, { shape: node.shape, frequency: node.frequency, volume: node.volume }])
            end

            def emit_stop_wave(_node) = sound_writes(RubyGBA::Audio::Sound::Registers.wave_stop, [:stop_wave])

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
