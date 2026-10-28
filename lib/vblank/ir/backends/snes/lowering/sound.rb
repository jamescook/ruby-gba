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
            STATEMENTS = Ractor.make_shareable({ enable_sound: :emit_enable_sound, beep: :emit_beep })

            # The kinds that reach the sound unit: a program with none of them is built without it.
            KINDS = STATEMENTS.keys.freeze

            # Whether +program+ makes any sound.
            def self.sounds?(program) = program.walk.any? { |node| KINDS.include?(node.kind) }

            # Every entry of the sound log the cartridge can write, by the number it writes.
            def sound_entries = @sound_entries.dup

            private

            def prepare_sound
              @sound_entries = []
              @defined_sounds = @program.walk.select { |node| node.kind == :define_sound }.to_h { |node| [node.name, node.effect] }
            end

            # Reference#exec_enable_sound.
            def emit_enable_sound(_node) = emit_sound_entry([:enabled])

            # Reference#exec_beep: the beep resolved as the interpreter resolves it.
            def emit_beep(node)
              effect = VBlank::Audio::Sound.resolve_effect(node.tone, duty: node.duty, decay: node.decay,
                                                                      volume: node.volume, defined: @defined_sounds)
              emit_sound_entry([:beep, effect])
            end

            # +entry+'s DSP writes, then its number into the cartridge's sound log.
            def emit_sound_entry(entry)
              DSPWrites.for_entry(entry).each do |register, value|
                runtime_call("rt_sound_write", [Build.int(register), Build.int(value)])
              end
              number = @sound_entries.index(entry) || (@sound_entries << entry).size - 1
              if number >= Runtime::Sound::LOG_LENGTH
                raise LoweringError, "This game makes more than #{Runtime::Sound::LOG_LENGTH} different sounds. The Super " \
                                     "Nintendo build can tell #{Runtime::Sound::LOG_LENGTH} apart. To fix this, make " \
                                     "fewer different sounds."
              end
              runtime_call("rt_sound_log", [Build.int(number)])
            end
          end
        end
      end
    end
  end
end
