# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # THE SOUND: the console's own voices, told what to play by writing their registers.
          #
          # rt_sound_writes(table) writes a table the build made (GBC::Sound): each entry a
          # register's place among the console's registers at 0xFF00 and the byte to write there,
          # nought after the last.
          #
          # THE WAVE VOICE BESIDE A RECORDING. In a game that plays one (Runtime::Clips) the
          # recording has the wave voice while it plays, so a table for the wave voice — a `wave` or
          # a `stop_wave`, whose first write is to NR30 — is kept rather than written then, and the
          # recording's end writes it (Clips#emit_game_wave_back). The last such table is kept
          # whenever one is said, so a wave the game was sounding as the recording started is
          # sounded again at its end too, as the Advance, which mixes the two, goes on playing it.
          module Sound
            GAME_WAVE = "rt sound game wave" # 16 bits: the last table for the wave voice, or nought

            module_function

            def reserve(memory) = memory.reserve(GAME_WAVE, 2)

            def keeps_game_wave?(memory) = memory.reserved?(GAME_WAVE)

            def emit(asm, memory)
              asm.label("rt_sound_writes")
              asm.load_hl_sp(2)
              asm.load(:a, [:hli])
              asm.load(:h, [:hl])
              asm.load(:l, :a)
              emit_keep_game_wave(asm, memory) if keeps_game_wave?(memory)
              asm.label("rt_sound_writes_next")
              asm.load(:a, [:hli])
              asm.and_a(:a)
              asm.ret(:z)
              asm.load(:c, :a)
              asm.load(:a, [:hli])
              asm.load_high([:c], :a)
              asm.jump_relative("rt_sound_writes_next")
            end

            # HL = the table: one for the wave voice is kept, and not written while a recording plays.
            def emit_keep_game_wave(asm, memory)
              asm.load(:a, [:hl])
              asm.cp_a(Console::GBCHardware::NR30 & 0xFF)
              asm.jump_relative(:nz, "rt_sound_writes_next")
              asm.load(:a, :l)
              asm.load([memory[GAME_WAVE]], :a)
              asm.load(:a, :h)
              asm.load([memory[GAME_WAVE] + 1], :a)
              Clips.emit_return_while_recording_plays(asm)
            end
          end
        end
      end
    end
  end
end
