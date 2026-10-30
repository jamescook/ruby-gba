# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # A RECORDING PLAYED A BIT AT A TIME (GBC::Clips), on the wave voice, by the timer.
          #
          # The wave voice plays 32 steps of a wave over and over, each step a height from 0 to 15.
          # Fill every step with 15 and the voice stands still at full height; what it is heard at is
          # then its volume alone — full, half, a quarter, or nothing — and that can be set between
          # any two instructions. So a speaker cone can be pushed out and let back for each sample of a
          # recording by setting that volume, full for a sample's 1 and nothing for its 0. The Color's
          # own games speak this way.
          #
          # THE TIMER SAYS WHEN. It counts up from where it is told, and as it passes 255 it starts
          # over and interrupts the game: told to start each count TIMER_COUNTS short of the top, it
          # interrupts 133 times a frame, which is the sample clock the interpreter mixes at
          # (Console::SampleClock). Each interrupt sets the volume for one sample and goes back to the
          # game — a few dozen instructions, so the game runs on while the clip plays, a little slower.
          #
          # rt_clip_play (A the clip's entry in the table, B the volume for a 1, and D 1 to loop it in a
          # game that loops one) starts a clip, unless one is playing: a Color plays one recording at a
          # time, and a play while one sounds is not heard, as the interpreter drops a play past the
          # voices it has (Description#recordings_at_once). rt_clip_stop (A the recording's number, or
          # ALL) stops it, if it is that recording, at whichever note. A clip that reaches its end
          # stops itself, or goes back to where it holds from if it loops. The timer running is what
          # says a clip is playing.
          #
          # A LOOPING CLIP'S LAPS are counted a frame at a time with the music (rt_clip_lap), in
          # 65536ths of a sample of the recording, the interpreter's own count of where its walk is
          # (GBC::Clips::Laps): what is left to the end goes down by a frame's walk, and each time it
          # falls below nought it goes up by what the loop goes back, and the lap is said at
          # rt_clip_came_round, with the recording's number in A, for the run's log.
          #
          # THE CLIP IS IN A BANK OF THE CARTRIDGE, and the interrupt comes between any two of the
          # game's instructions, with whatever bank the game had in view. The interrupt puts the clip's
          # bank in view for the read and the game's back after it, which it knows because in a game
          # with a clip every bank switch writes the bank down first (SM83#select_rom_bank_unnoted, at
          # SHOWN). Written first, an interrupt between the two puts back the bank about to be shown.
          module Clips
            NUMBER = "rt clip number" # the clip playing
            LEFT = "rt clip left" # 16 bits: the bytes still to read
            PLACE = "rt clip place" # 16 bits: where the next byte is
            BANK = "rt clip bank" # ...and its bank
            SHOWN = "rt clip bank shown" # the bank the game has in view
            # In quick memory, read at every sample: the byte being played, moved up a bit each
            # sample with a 1 below the bits still to play, and the volume a 1 plays at.
            BITS = "rt clip bits"
            LEVEL = "rt clip level"
            # In a game that loops one: 1 while the clip playing loops, where it goes back to (its
            # place, then how many bytes are left from there), and its laps' three numbers, five
            # bytes each, as the table lays them out.
            LOOPING = "rt clip looping"
            HOLD_PLACE = "rt clip hold place"
            HOLD_LEFT = "rt clip hold left"
            TO_END = "rt clip to end"
            A_FRAME = "rt clip a frame"
            BACK = "rt clip back"

            # Stop whichever clip is playing.
            ALL = 0xFF

            # What a 1 plays at, by the volume a game names: the wave voice's own levels, which are
            # full, half and a quarter. There is no three quarters, so that plays at full, as a song's
            # wave part does (Music::WAVE_LEVEL_CODES).
            LEVELS = { full: 0x20, three_quarter: 0x20, half: 0x40, quarter: 0x60, mute: 0x00 }.freeze

            # The timer counting every sixteenth cycle of the processor (TAC), switched on.
            TIMER_ON = 0x05

            module_function

            # +laps+ says the game loops a recording (GBC::Clips#loops?).
            def reserve(memory, laps: false)
              if laps
                memory.reserve(LOOPING, 1)
                memory.reserve(HOLD_PLACE, 2)
                memory.reserve(HOLD_LEFT, 2)
                [TO_END, A_FRAME, BACK].each { |name| memory.reserve(name, GBC::Clips::LAP_BYTES) }
              end
              memory.reserve(NUMBER, 1)
              memory.reserve(LEFT, 2)
              memory.reserve(PLACE, 2)
              memory.reserve(BANK, 1)
              memory.reserve(SHOWN, 1)
              memory.reserve_quick(BITS, 1)
              memory.reserve_quick(LEVEL, 1)
              Sound.reserve(memory)
            end

            def any?(memory) = memory.reserved?(SHOWN)

            # Whether the game loops a recording, and so counts its laps (rt_clip_lap).
            def laps?(memory) = memory.reserved?(LOOPING)

            # +counts+ is how many of the timer's counts a sample lasts (GBC::Clips#timer_counts).
            # +entry_bytes+ is how many bytes an entry of the table takes (GBC::Clips#entry_bytes).
            def emit(asm, memory, counts:, entry_bytes:)
              emit_play(asm, memory, counts, entry_bytes)
              emit_stop(asm, memory)
              emit_tick(asm, memory)
              emit_lap(asm, memory) if laps?(memory)
            end

            # WHILE A RECORDING PLAYS THE WAVE VOICE IS ITS OWN: the music player's writes to it are
            # passed over. When the recording is over the music has it back on its next frame: a wave
            # note held across it is put back, waveform and all (Music#emit_wave_back), and a part
            # that rested is heard at its next note. The timer running is what says one is playing. A
            # and the flags are spent.
            def emit_return_while_recording_plays(asm)
              asm.load_high(:a, Console::GBCHardware::TAC)
              asm.bit(2, :a)
              asm.ret(:nz)
            end

            # ...and the same, going on at +past+ rather than returning.
            def emit_skip_while_recording_plays(asm, past)
              asm.load_high(:a, Console::GBCHardware::TAC)
              asm.bit(2, :a)
              asm.jump_relative(:nz, past)
            end

            def emit_play(asm, memory, counts, entry_bytes)
              h = Console::GBCHardware
              # Held from the screen's interrupt while it is set up: the music player runs there, and
              # until the timer is on it would not stand aside (#emit_return_while_recording_plays), so
              # a note could write its own waveform, or turn the voice off, under the one being set up.
              asm.label("rt_clip_play")
              asm.di
              asm.call("rt_clip_play_held")
              asm.ei
              asm.ret
              asm.label("rt_clip_play_held")
              asm.load(:c, :a)
              asm.load_high(:a, h::TAC)
              asm.bit(2, :a)
              asm.ret(:nz) # one is playing: this one is not heard
              if laps?(memory)
                asm.load(:a, :d)
                asm.load([memory[LOOPING]], :a)
              end
              asm.load(:a, :b)
              asm.load_high(memory[LEVEL], :a)
              # Its entry in the table: +entry_bytes+ a clip, the entry's number times that by its
              # bits, a doubling each and the number added for each 1.
              asm.load(:l, :c)
              asm.load(:h, 0)
              asm.load(:d, :h)
              asm.load(:e, :l)
              entry_bytes.to_s(2).chars.drop(1).each do |bit|
                asm.add_hl(:hl)
                asm.add_hl(:de) if bit == "1"
              end
              asm.load(:de, GBC::Clips::TABLE)
              asm.add_hl(:de)
              places = [memory[PLACE], memory[PLACE] + 1, memory[BANK], memory[LEFT], memory[LEFT] + 1, memory[NUMBER]]
              if laps?(memory)
                places += [memory[HOLD_PLACE], memory[HOLD_PLACE] + 1, memory[HOLD_LEFT], memory[HOLD_LEFT] + 1]
                places += [TO_END, A_FRAME, BACK].flat_map { |name| Array.new(GBC::Clips::LAP_BYTES) { |k| memory[name] + k } }
              end
              places.each do |place|
                asm.load(:a, [:hli])
                asm.load([place], :a)
              end
              # Nothing left to play of the byte before the first, so the first sample reads one.
              asm.load(:a, 0x80)
              asm.load_high(memory[BITS], :a)
              # The wave voice: off while its steps are written, every step full, then on, at nothing,
              # and started. Whatever waveform a song or a sound effect had there is gone, so the
              # next wave note puts its own back (Music.reloads_wave?).
              asm.xor_a(:a)
              asm.load([memory[Music::WAVE_LOADED]], :a) if Music.reloads_wave?(memory)
              asm.load_high(h::NR30, :a)
              asm.load(:a, 0xFF)
              asm.load(:hl, h::WAVE_RAM)
              asm.load(:c, 16)
              asm.label("rt_clip_play_steps")
              asm.load([:hli], :a)
              asm.dec(:c)
              asm.jump_relative(:nz, "rt_clip_play_steps")
              asm.load(:a, 0x80)
              asm.load_high(h::NR30, :a)
              asm.xor_a(:a)
              asm.load_high(h::NR32, :a)
              asm.load(:a, 0x80)
              asm.load_high(h::NR34, :a)
              # The timer, from the top of a count, with no interrupt left waiting from before.
              asm.load(:a, 256 - counts)
              asm.load_high(h::TMA, :a)
              asm.load_high(h::TIMA, :a)
              asm.load_high(:a, h::IF)
              asm.and_a(~h::INT_TIMER & 0xFF)
              asm.load_high(h::IF, :a)
              asm.load(:a, TIMER_ON)
              asm.load_high(h::TAC, :a)
              asm.ret
            end

            # Stopped: the timer off, so no more samples come, and the wave voice off, quiet.
            def emit_stop(asm, memory)
              h = Console::GBCHardware
              asm.label("rt_clip_stop")
              asm.load(:c, :a)
              asm.load_high(:a, h::TAC)
              asm.bit(2, :a)
              asm.ret(:z) # none is playing
              asm.load(:a, :c)
              asm.cp_a(ALL)
              asm.jump_relative(:z, "rt_clip_end")
              asm.load(:a, [memory[NUMBER]])
              asm.cp_a(:c)
              asm.ret(:nz) # another is playing
              asm.label("rt_clip_end")
              asm.xor_a(:a)
              asm.load_high(h::TAC, :a)
              asm.load_high(h::NR30, :a)
              emit_wave_back(asm, memory)
              asm.ret
            end

            # THE VOICE IS THE GAME'S AGAIN as a recording ends: the last `wave` or `stop_wave` the game
            # said is written now (Sound::GAME_WAVE), and a wave note the music is holding is put back
            # on its next frame (Music::WAVE_BACK). A, C and HL are spent.
            def emit_wave_back(asm, memory)
              asm.load(:a, [memory[Sound::GAME_WAVE]])
              asm.load(:l, :a)
              asm.load(:a, [memory[Sound::GAME_WAVE] + 1])
              asm.load(:h, :a)
              asm.or_a(:l)
              asm.call(:nz, "rt_sound_writes_next")
              return unless Music.wave_back?(memory)

              asm.load(:a, 1)
              asm.load([memory[Music::WAVE_BACK]], :a)
            end

            # THE TIMER'S INTERRUPT: one sample. The byte being played moves up a bit, and the bit that
            # leaves its top sets the volume. When only the 1 put below the bits is left, it leaves
            # instead, and the byte is spent: the next is read, with a 1 put below its bits, and its top
            # bit plays. With no byte left, the clip is over, or a looping one goes back to where it
            # holds from and reads on.
            #
            # Nothing on the way changes the carry once the bit is in it: loads leave every flag as
            # it was.
            def emit_tick(asm, memory)
              h = Console::GBCHardware
              asm.label("rt_clip_tick")
              asm.push(:af)
              asm.load_high(:a, memory[BITS])
              asm.add_a(:a)
              asm.jump_relative(:z, "rt_clip_tick_byte")
              asm.load_high(memory[BITS], :a)
              asm.label("rt_clip_tick_sample")
              asm.load(:a, 0)
              asm.jump_relative(:nc, "rt_clip_tick_set")
              asm.load_high(:a, memory[LEVEL])
              asm.label("rt_clip_tick_set")
              asm.load_high(h::NR32, :a)
              asm.pop(:af)
              asm.reti

              asm.label("rt_clip_tick_byte")
              asm.push(:hl)
              asm.load(:a, [memory[LEFT]])
              asm.load(:l, :a)
              asm.load(:a, [memory[LEFT] + 1])
              asm.load(:h, :a)
              asm.or_a(:l)
              asm.jump_relative(:z, "rt_clip_tick_over")
              asm.label("rt_clip_tick_read")
              asm.dec(:hl)
              asm.load(:a, :l)
              asm.load([memory[LEFT]], :a)
              asm.load(:a, :h)
              asm.load([memory[LEFT] + 1], :a)
              asm.load(:a, [memory[BANK]])
              asm.load([h::MBC_ROM_BANK_LOW], :a)
              asm.load(:a, [memory[PLACE]])
              asm.load(:l, :a)
              asm.load(:a, [memory[PLACE] + 1])
              asm.load(:h, :a)
              asm.load(:a, [:hli])
              asm.scf
              asm.rla
              asm.load_high(memory[BITS], :a)
              asm.load(:a, :l)
              asm.load([memory[PLACE]], :a)
              asm.load(:a, :h)
              asm.load([memory[PLACE] + 1], :a)
              asm.load(:a, [memory[SHOWN]])
              asm.load([h::MBC_ROM_BANK_LOW], :a)
              asm.pop(:hl)
              asm.jump_relative("rt_clip_tick_sample")

              asm.label("rt_clip_tick_over")
              if laps?(memory)
                asm.load(:a, [memory[LOOPING]])
                asm.and_a(:a)
                asm.jump_relative(:z, "rt_clip_tick_end")
                asm.load(:a, [memory[HOLD_PLACE]])
                asm.load([memory[PLACE]], :a)
                asm.load(:a, [memory[HOLD_PLACE] + 1])
                asm.load([memory[PLACE] + 1], :a)
                asm.load(:a, [memory[HOLD_LEFT]])
                asm.load(:l, :a)
                asm.load(:a, [memory[HOLD_LEFT] + 1])
                asm.load(:h, :a)
                asm.jump_relative("rt_clip_tick_read")
                asm.label("rt_clip_tick_end")
              end
              asm.xor_a(:a)
              asm.load_high(h::TAC, :a)
              asm.load_high(h::NR30, :a)
              asm.push(:bc)
              emit_wave_back(asm, memory)
              asm.pop(:bc)
              asm.pop(:hl)
              asm.pop(:af)
              asm.reti
            end

            # A FRAME OF A LOOPING CLIP'S LAPS, called with the music's frame and before it, as the
            # interpreter mixes a frame before it moves its tune on (Reference#advance_frame). Nothing
            # while no clip plays or the one playing does not loop. Each sum goes a byte at a time, low
            # byte first, with the carry between: nothing on the way changes it but the sum itself.
            # Every register is spent.
            def emit_lap(asm, memory)
              h = Console::GBCHardware
              asm.label("rt_clip_lap")
              asm.load(:a, [memory[LOOPING]])
              asm.and_a(:a)
              asm.ret(:z)
              asm.load_high(:a, h::TAC)
              asm.bit(2, :a)
              asm.ret(:z)
              emit_lap_sum(asm, memory, A_FRAME, :sbc_a, "rt_clip_lap_frame")
              asm.label("rt_clip_lap_check")
              asm.load(:a, [memory[TO_END] + GBC::Clips::LAP_BYTES - 1])
              asm.bit(7, :a)
              asm.ret(:z)
              emit_lap_sum(asm, memory, BACK, :adc_a, "rt_clip_lap_back")
              # Said with the timer's interrupt held off: one taken just as the processor reaches
              # the label comes back to it, and the run's reader would count the lap twice. Both
              # callers run with interrupts on, so they go back on after it.
              asm.di
              asm.load(:a, [memory[NUMBER]])
              asm.label("rt_clip_came_round")
              asm.ei
              asm.jump_relative("rt_clip_lap_check")
            end

            # TO_END less (+sum+ :sbc_a) or plus (:adc_a) the number at +by+, five bytes.
            def emit_lap_sum(asm, memory, by, sum, label)
              asm.load(:hl, memory[TO_END])
              asm.load(:de, memory[by])
              asm.load(:b, GBC::Clips::LAP_BYTES)
              asm.and_a(:a) # no carry into the lowest byte
              asm.label(label)
              asm.load(:a, [:de])
              asm.load(:c, :a)
              asm.load(:a, [:hl])
              asm.public_send(sum, :c)
              asm.load([:hli], :a)
              asm.inc(:de)
              asm.dec(:b)
              asm.jump_relative(:nz, label)
            end
          end
        end
      end
    end
  end
end
