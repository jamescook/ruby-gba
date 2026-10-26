# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # THE ADVANCE'S SOUND WRITES, SAID AS THE COLOR'S.
        #
        # The Advance's square, wave and noise voices are the Game Boy's own, kept when the Advance
        # was made, so the Color plays a beep, a hit on the noise voice and a tone on the wave voice
        # from the same numbers the cartridge for the Advance writes. Those numbers are worked out
        # once, by Audio::Sound::Registers, as writes to the Advance's sound registers; here each is
        # said again as the Color's, and the runtime writes them in a row (Runtime::Sound).
        module SoundRegisters
          A = Console::Hardware
          H = Console::GBCHardware

          module_function

          # +writes+ ([register, value] pairs of the Advance's) as a table of the Color's: each a
          # register's low byte and the byte for it, nought after the last.
          def table(writes) = [*writes.flat_map { |register, value| color_writes(register, value) }.flatten, 0]

          # One write to the Advance's sound registers, as the writes to the Color's that do the
          # same: the Advance keeps two of the Color's byte-wide registers in each of its 16-bit ones,
          # and a few bits the Color does not have (the second bank of wave memory, the recordings'
          # routing), which are left out.
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

          # The wave voice's loudness: full, a half and a quarter are the Color's own; the Advance's
          # three-quarters, which the Color does not have, plays at full.
          def wave_level(value)
            return 1 << 5 if value[15] == 1

            ((value >> 13) & 3) << 5
          end
        end
      end
    end
  end
end
