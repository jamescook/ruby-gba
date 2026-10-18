# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        # THE SOUND, said for a Game Boy Color. Mixed into Lowering, over Native's sound.
        #
        # The Advance's square, wave and noise voices are the Game Boy's own, kept when the
        # Advance was made, so the Color plays a beep, a hit on the noise voice and a tone on the
        # wave voice from the same numbers the cartridge for the Advance writes. Those numbers are
        # worked out once, by Audio::Sound::Registers, as writes to the Advance's sound registers;
        # here each is said again as the Color's (#color_writes), and the runtime writes them in a
        # row where the game says the word (Runtime::Sound).
        module Sound
          C = Native::C
          A = Console::Hardware
          H = Console::GBCHardware

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

          # The writes as a table of the Color's (each a register's low byte and the byte for it,
          # nought after the last) and the call that writes them.
          def sound_writes(writes)
            bytes = writes.flat_map { |register, value| color_writes(register, value) }.flatten
            [eval_call("rg_gbc_sound_writes", drawing_array("sound_writes", "uint8_t", [*bytes, 0]))]
          end

          # One write to the Advance's sound registers, as the writes to the Color's that do the
          # same: the Advance keeps two of the Color's byte-wide registers in each of its 16-bit
          # ones, and a few bits the Color does not have (the second bank of wave memory, the
          # recordings' routing), which are left out.
          def color_writes(register, value)
            low = value & 0xFF
            high = value >> 8
            case register
            when A::REG_SOUND1CNT_L then [[H::NR10, low & 0x7F]]
            when A::REG_SOUND1CNT_H then [[H::NR11, low], [H::NR12, high]]
            when A::REG_SOUND1CNT_X then [[H::NR13, low], [H::NR14, high & 0xC7]]
            when A::REG_SOUND2CNT_L then [[H::NR21, low], [H::NR22, high]]
            when A::REG_SOUND2CNT_H then [[H::NR23, low], [H::NR24, high & 0xC7]]
            when A::REG_SOUND3CNT_L then [[H::NR30, low & 0x80]]
            when A::REG_SOUND3CNT_H then [[H::NR31, low], [H::NR32, wave_level(value)]]
            when A::REG_SOUND3CNT_X then [[H::NR33, low], [H::NR34, high & 0xC7]]
            when A::REG_SOUND4CNT_L then [[H::NR41, low & 0x3F], [H::NR42, high]]
            when A::REG_SOUND4CNT_H then [[H::NR43, low], [H::NR44, high & 0xC0]]
            when A::REG_SOUNDCNT_L then [[H::NR50, low & 0x77], [H::NR51, high]]
            when A::REG_SOUNDCNT_X then [[H::NR52, low & 0x80]]
            when A::REG_SOUNDCNT_H then []
            when A::REG_WAVE_RAM...(A::REG_WAVE_RAM + 16)
              at = H::WAVE_RAM + (register - A::REG_WAVE_RAM)
              [[at, low], [at + 1, high]]
            else raise LoweringError, "a sound register #{format('%#x', register)} the Game Boy Color does not have"
            end.map { |at, byte| [at & 0xFF, byte] }
          end

          # The wave voice's loudness: full, a half and a quarter are the Color's own; the
          # Advance's three-quarters, which the Color does not have, plays at full.
          def wave_level(value)
            return 1 << 5 if value[15] == 1

            ((value >> 13) & 3) << 5
          end
        end
      end
    end
  end
end
