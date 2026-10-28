# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # WHAT A SOUND IS, IN THE S-DSP'S REGISTERS. The Super Nintendo's sound unit mixes eight
        # voices, and everything one of them does is a handful of registers: which recording it plays
        # (its source number, an entry in the sample table), how fast it reads through it (its
        # pitch), how loud it is on the left and on the right, how its loudness rises and falls (its
        # envelope), and the key-on register that starts it from the top. The console plays a sound
        # by writing those (Runtime::Sound's rt_sound_write); this module says which writes each of
        # the interpreter's sound-log entries means.
        #
        # The lowering writes them, and the checked run reads the emulator's registers after every
        # pass and holds them to the writes the interpreter's log up to then says (#after) — so a
        # write that never arrived, arrived late or arrived wrong shows up, in the sound unit itself.
        #
        # THE SQUARE VOICES. The Advance has two voices that play a square wave of their own, in four
        # widths. The S-DSP has none: it only plays recordings. So the four widths are four short
        # recordings of one wave each (Samples), looped, and a beep picks one by its source number.
        # Each is 32 samples a wave, so its pitch register, where $1000 reads 32000 samples a second
        # (fullsnes, "SNES APU DSP BRR Pitch"), is the note's frequency * 32 * $1000 / 32000.
        #
        # THE FADE. The Advance fades a beep a volume step at a time, a step every 1, 3 or 5 64ths of
        # a second (Audio::Sound::FADE_STEP_SIXTY_FOURTHS): volume 15 fading :fast is gone in 15/64
        # of a second. The S-DSP's envelope instead starts each note at the top (the fastest attack,
        # ADSR1 $8F) and takes it down a 256th of where it is at every step (its sustain mode), at a
        # rate picked so a note at full falls to almost nothing in about the Advance's time at
        # volume 15: some 1240 steps, of 6, 16 or 32 of the DSP's samples. :none holds (rate nought).
        # How loud the note is stays in its volume registers, eight steps a volume.
        module DSPWrites
          # The voice beeps play on, as the Advance plays them on its second square voice.
          BEEP_VOICE = 1

          # The source number of each square width's recording (Samples::SQUARE_HIGH_EIGHTHS's order).
          SHAPES = { eighth: 0, quarter: 1, half: 2, square: 2, three_quarter: 3 }.freeze

          # A voice's registers, counted from its first ($x0).
          VOLUME_LEFT = 0x0
          VOLUME_RIGHT = 0x1
          PITCH_LOW = 0x2
          PITCH_HIGH = 0x3
          SOURCE = 0x4
          ADSR1 = 0x5
          ADSR2 = 0x6

          # The registers for every voice at once (fullsnes, "SNES APU DSP Control Registers" and
          # "Volume Registers").
          MAIN_LEFT = 0x0C
          MAIN_RIGHT = 0x1C
          ECHO_LEFT = 0x2C
          ECHO_RIGHT = 0x3C
          PITCH_MODULATION = 0x2D
          NOISE_ON = 0x3D
          ECHO_ON = 0x4D
          KEY_ON = 0x4C
          KEY_OFF = 0x5C
          SAMPLE_TABLE = 0x5D
          FLAGS = 0x6C

          # FLG: not muted, not held in reset, and the echo never writing — its buffer would be
          # written over the sound unit's own memory, where the program is.
          SOUND_ON = 0x20
          # ...and as the sound unit starts: muted and every voice held off, said outright, since
          # what FLG reads before anything writes it is not to be relied on (fullsnes).
          SOUND_OFF = 0xE0
          # Main volume, near the top (127 of 127, on both sides).
          MAIN_VOLUME = 0x7F

          # Fastest attack, ADSR on (ADSR1); the sustain level at the top (ADSR2's high three bits),
          # so the note goes straight to its sustain, whose rate below is its fade.
          ATTACK = 0x8F
          SUSTAIN_AT_TOP = 0xE0
          FADE_RATES = { fast: 0x1A, medium: 0x16, slow: 0x13, none: 0x00 }.freeze

          # Eight steps of the voice's volume register (0..127) a step of the game's (0..15).
          VOLUME_STEP = 8

          # Samples a wave of each square recording, and the pitch register's scale.
          WAVE_SAMPLES = 32
          PITCH_ONE = 0x1000
          DSP_RATE = 32_000
          PITCH_TOP = 0x3FFF

          module_function

          # What the sound unit is told once its program has been sent, before the game runs: where
          # the sample table is, and every voice quiet with no echo, noise or pitch modulation. FLG
          # is left as the sound unit starts it (muted and every voice held off) until enable_sound.
          def at_power_on(table_page)
            [[FLAGS, SOUND_OFF], [SAMPLE_TABLE, table_page], [ECHO_LEFT, 0], [ECHO_RIGHT, 0], [ECHO_ON, 0],
             [NOISE_ON, 0], [PITCH_MODULATION, 0], [KEY_OFF, 0]]
          end

          # The writes one sound-log entry means: [:enabled] or [:beep, effect].
          def for_entry(entry)
            case entry.first
            when :enabled then [[FLAGS, SOUND_ON], [MAIN_LEFT, MAIN_VOLUME], [MAIN_RIGHT, MAIN_VOLUME]]
            when :beep then beep(entry.last)
            else raise ArgumentError, "the Super Nintendo build does not play #{entry.first.inspect} yet"
            end
          end

          # A beep: its voice's registers, and key-on last, which starts it from the top.
          def beep(effect)
            base = BEEP_VOICE << 4
            pitch = pitch_for(effect.frequency)
            volume = effect.volume * VOLUME_STEP
            [[base + VOLUME_LEFT, volume], [base + VOLUME_RIGHT, volume], [base + PITCH_LOW, pitch & 0xFF],
             [base + PITCH_HIGH, pitch >> 8], [base + SOURCE, SHAPES.fetch(effect.duty)], [base + ADSR1, ATTACK],
             [base + ADSR2, SUSTAIN_AT_TOP | FADE_RATES.fetch(effect.decay)], [KEY_ON, 1 << BEEP_VOICE]]
          end

          # The pitch register for a +frequency+ Hz note on a square recording, held to the most the
          # register has.
          def pitch_for(frequency) = ((frequency * WAVE_SAMPLES * PITCH_ONE) / DSP_RATE.to_f).round.clamp(1, PITCH_TOP)

          # What the registers hold after the sound log +entries+, by register, for each one written.
          def after(entries)
            entries.each_with_object({}) { |entry, held| for_entry(entry).each { |register, value| held[register] = value } }
          end
        end
      end
    end
  end
end
