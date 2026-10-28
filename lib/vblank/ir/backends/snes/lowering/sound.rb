# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        class Lowering
          # SOUND, lowered for a Super Nintendo: each sound statement the S-DSP register writes its
          # entry of the interpreter's sound log means (DSPWrites), sent one at a time through the
          # sound unit's program (Runtime::Sound's rt_sound_write), and then the entry's number added
          # to the cartridge's own sound log (rt_sound_log), which a run reads back as the
          # interpreter's words (#sound_entries). Mixed into Lowering.
          module Sound
            STATEMENTS = Ractor.make_shareable({ enable_sound: :emit_enable_sound, beep: :emit_beep, noise: :emit_noise,
                                                 wave: :emit_wave, stop_wave: :emit_stop_wave, play_song: :emit_play_song,
                                                 stop_music: :emit_stop_music })

            # The kinds that reach the sound unit: a program with none of them is built without it.
            KINDS = STATEMENTS.keys.freeze

            # Whether +program+ makes any sound.
            def self.sounds?(program) = program.walk.any? { |node| KINDS.include?(node.kind) }

            # Whether +program+ plays songs, and so carries their player (Runtime::Music).
            def self.songs?(program) = program.walk.any? { |node| %i[song play_song stop_music].include?(node.kind) }

            # Every entry of the sound log the cartridge can write, by the number it writes.
            def sound_entries = @sound_entries.dup

            # The wave voice's waveforms this game plays, each at the loudness it plays it, in the
            # order they are recorded beside the sound program (Samples::FIRST_WAVE on).
            def sound_waves = @sound_waves.dup

            # What the DSP writes for this game's sound-log entries are worked out with.
            def sound_voicing = DSPWrites::Voicing.new(waves: @sound_waves, parts: @music.parts)

            # The section of the game's songs (SNES::Music), each note's sound-log entries numbered
            # among the rest.
            def music_section = @music.section(@music.words(sound_voicing) { |entry| sound_entry_number(entry) })

            private

            def prepare_sound
              @sound_entries = []
              @defined_sounds = @program.walk.select { |node| node.kind == :define_sound }.to_h { |node| [node.name, node.effect] }
              @sound_waves = @program.walk.select { |node| node.kind == :wave }
                                     .map { |node| DSPWrites.wave_steps(wave_params(node)) }.uniq
              @music = SNES::Music.new(@program)
            end

            # What the build does not make of a game's music yet: a music volume, and its fades.
            def refuse_unmade_music!
              return unless Reach.variables(@program).include?(IR::Tunes::LEVEL)

              raise NotMadeYet.new("This game uses `music_volume` or a music fade. The Super Nintendo build does not " \
                                   "make that yet. To fix this, build the game for the Game Boy Advance alone for now " \
                                   "(`consoles: %i[gba]`).", part: "the sound")
            end

            # Reference#exec_play_song: the tune named, from the next frame or from here.
            def emit_play_song(node)
              routine = node.this_frame ? "rt_music_play_now" : "rt_music_play"
              runtime_call(routine, [Build.int(@music.number(node.name))])
            end

            def emit_stop_music(_node) = runtime_call("rt_music_stop", [])

            # Reference#exec_wave's entry.
            def wave_params(node) = { shape: node.shape, frequency: node.frequency, volume: node.volume }

            def emit_wave(node) = emit_sound_entry([:wave, wave_params(node)])
            def emit_stop_wave(_node) = emit_sound_entry([:stop_wave])

            # Reference#exec_enable_sound.
            def emit_enable_sound(_node) = emit_sound_entry([:enabled])

            # Reference#exec_beep: the beep resolved as the interpreter resolves it.
            def emit_beep(node)
              effect = VBlank::Audio::Sound.resolve_effect(node.tone, duty: node.duty, decay: node.decay,
                                                                      volume: node.volume, defined: @defined_sounds)
              emit_sound_entry([:beep, effect])
            end

            # Reference#exec_noise: the hit resolved as the interpreter resolves it.
            def emit_noise(node)
              hit = VBlank::Audio::Sound.resolve_noise(node.preset, pitch: node.pitch, decay: node.decay,
                                                                    volume: node.volume, metallic: node.metallic)
              emit_sound_entry([:noise, hit])
            end

            # +entry+'s DSP writes, then its number into the cartridge's sound log.
            def emit_sound_entry(entry)
              DSPWrites.for_entry(entry, sound_voicing).each do |write|
                command, *numbers = Runtime::Sound.command_for(write)
                runtime_call(Runtime::Sound::ROUTINES.fetch(command), numbers.map { |number| Build.int(number) })
              end
              runtime_call("rt_sound_log", [Build.int(sound_entry_number(entry))])
            end

            # The number the cartridge's sound log keeps +entry+ as, the next one the first time.
            def sound_entry_number(entry)
              number = @sound_entries.index(entry) || (@sound_entries << entry).size - 1
              if number >= Runtime::Sound::LOG_LENGTH
                raise LoweringError, "This game makes more than #{Runtime::Sound::LOG_LENGTH} different sounds. The Super " \
                                     "Nintendo build can tell #{Runtime::Sound::LOG_LENGTH} apart. To fix this, make " \
                                     "fewer different sounds."
              end
              number
            end
          end
        end
      end
    end
  end
end
