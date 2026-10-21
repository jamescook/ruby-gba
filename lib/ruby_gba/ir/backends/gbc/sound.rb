# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        # THE SOUND, said for a Game Boy Color. Mixed into StatementLowering, over Native's sound.
        #
        # The Advance's square, wave and noise voices are the Game Boy's own, kept when the
        # Advance was made, so the Color plays a beep, a hit on the noise voice and a tone on the
        # wave voice from the same numbers the cartridge for the Advance writes. Those numbers are
        # worked out once, by Audio::Sound::Registers, as writes to the Advance's sound registers;
        # here each is said again as the Color's (#color_writes), and the runtime writes them in a
        # row where the game says the word (Runtime::Sound).
        module Sound
          C = Native::C

          # The game's songs, as the player reads them (GBC::Music).
          def music = @music

          # The name the statements give the variable holding how loud the music is, or nil for a
          # game that never says.
          def music_level_name
            variable_names.include?(Tunes::LEVEL) ? variable(Tunes::LEVEL).text : nil
          end

          private

          def prepare_sound
            @defined_sounds = @program.walk.select { |node| node.kind == :define_sound }.to_h { |node| [node.name, node.effect] }
            @music = Music.new(@program)
          end

          # Reference#exec_play_song: the tune named, from the next frame, unless it is the one
          # named already. Named `this_frame: true` it starts the same way, a frame on.
          def lower_play_song(node) = [eval_call("rg_gbc_music_play", C::Int.new(@music.number(node.name)))]

          def lower_stop_music(_node) = [eval_call("rg_gbc_music_stop")]

          def lower_enable_sound(_node) = sound_writes(RubyGBA::Audio::Sound::Registers.enable)

          def lower_beep(node)
            effect = RubyGBA::Audio::Sound.resolve_effect(node.tone, duty: node.duty, decay: node.decay,
                                                          volume: node.volume, defined: @defined_sounds)
            sound_writes(RubyGBA::Audio::Sound::Registers.beep_writes(**effect.to_h))
          end

          def lower_noise(node)
            hit = RubyGBA::Audio::Sound.resolve_noise(node.preset, pitch: node.pitch, decay: node.decay,
                                                      volume: node.volume, metallic: node.metallic)
            sound_writes(RubyGBA::Audio::Sound::Registers.noise_hit_writes(**hit))
          end

          def lower_wave(node)
            samples = RubyGBA::Audio::Sound.wavetable(node.shape)
            sound_writes(RubyGBA::Audio::Sound::Registers.wave_start_writes(samples, frequency: node.frequency,
                                                                                      volume: node.volume))
          end

          def lower_stop_wave(_node) = sound_writes(RubyGBA::Audio::Sound::Registers.wave_stop)

          # The writes as a table of the Color's (SoundRegisters) and the call that writes them.
          def sound_writes(writes)
            [eval_call("rg_gbc_sound_writes", drawing_array("sound_writes", "uint8_t", SoundRegisters.table(writes)))]
          end
        end
      end
    end
  end
end
