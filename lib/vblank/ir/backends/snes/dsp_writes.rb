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
        # widths. The S-DSP has none: it only plays recordings. So each width is a short looped
        # recording of a square wave (Samples), and a beep picks one by its source number: the one
        # whose wave is 32 samples long when the note is low enough, and the one of 8 samples above
        # that. Its pitch register, where $1000 reads 32000 samples a second (fullsnes, "SNES APU DSP
        # BRR Pitch"), is then the note's frequency * the wave's samples * $1000 / 32000.
        #
        # THE FADE. The Advance fades a beep a volume step at a time, a step every 1, 3 or 5 64ths of
        # a second (Audio::Sound::FADE_STEP_SIXTY_FOURTHS), so volume v fading :fast is gone in v/64
        # of a second, and a quiet beep sooner than a loud one. The S-DSP's envelope instead starts
        # each note at the top (the fastest attack, ADSR1 $8F) and, in its sustain mode, takes it
        # down a 256th of where it is, and one more, at every step (fullsnes, "SNES APU DSP ADSR/Gain
        # Envelope"); how loud the note is stays in its volume registers, eight steps a volume. So the
        # fade is chosen per beep: the step rate (fullsnes's table of them, RATE_SAMPLES) whose steps,
        # as many as it takes the envelope to fall from the top to where its top seven bits read
        # nought (#steps_to_silence), come nearest to the Advance's time for that volume and speed.
        # :none holds (rate nought).
        module DSPWrites
          # The voice beeps play on, as the Advance plays them on its second square voice, and the one
          # noise plays on, as the Advance's noise is its fourth voice.
          BEEP_VOICE = 1
          NOISE_VOICE = 3

          # THE WAVE VOICE, the Advance's third, plays the game's own 32-step waveforms (Samples.wave).
          # The Advance makes its four quieter loudnesses by cutting every step down, so each
          # loudness is a waveform of its own (#wave_steps), recorded at the loudness of a beep at
          # 15; the voice has no fade, so its envelope is a fixed gain at the top (ADSR1 bit 7 nought
          # and GAIN $7F) until stop_wave keys it off. A key-off holds until it is cleared, and a
          # key-on under it plays nothing (fullsnes, "KON/KOFF Notes"), so each wave clears it first.
          WAVE_VOICE = 2
          ADSR_OFF = 0x00 # ADSR1 with bit 7 nought: the envelope is GAIN's
          FIXED_TOP = 0x7F # GAIN with bit 7 nought: a fixed level, the most there is

          # NOISE. A hiss is the S-DSP's own noise generator, a register of fifteen random bits, as
          # the Advance's is: the noise voice's bit in NON switches it from its recording to the
          # generator, and the generator's clock is FLG's low five bits, one of the 32 rates (a rate
          # steps it 32000 / RATE_SAMPLES[rate] times a second, so 32000 at the most). A metallic
          # rattle is a recording instead (Samples::METALLIC), read one sample for each of the
          # Advance's steps. Both are clocked as the Advance clocks a hit: Audio::Sound's
          # NOISE_HIT_HALVINGS. The Advance clocks a :high hiss eight times as fast as a :mid one,
          # past the DSP's fastest; there the two come out only twice as far apart.
          #
          # THE GENERATOR IS LOUDER than a recording at the same volume: its output swings the whole
          # of $4000 either way (fullsnes, "NON"), and the recordings Samples makes swing 7 * 2^11 / 2.
          # The Advance's noise and square voices swing alike, so a hiss's volume registers are scaled
          # down by the two swings (HISS_SCALE), and a hiss is as loud as a beep at the same volume.
          #
          # FLG IS SHARED. Its top three bits mute the sound unit, hold every voice off and stop the
          # echo writing; its low five are the noise clock. So neither enable_sound nor a noise hit
          # writes all of FLG: each changes only its own bits, which the sound unit's program does
          # with the DSP's register in hand (Runtime::Sound's "set some bits" commands), written here
          # as [SET_BITS, FLAGS, mask, bits]. A hit before enable_sound sets the clock and leaves the
          # sound unit muted, as the Advance makes no sound before it either.
          #
          # KEY-OFF IS SHARED TOO, a bit a voice, and a voice's bit holds until something clears it: a
          # key-on under it plays nothing (fullsnes, "KON/KOFF Notes"). So a voice is let go by
          # setting its bit alone, and every key-on clears its own bit first (#key_on); writing all
          # of KOFF would let go of, or take back, another voice's note.
          SET_BITS = :set_bits
          SWITCHES = 0xE0
          NOISE_CLOCK = 0x1F
          GENERATOR_SWING = 0x4000
          HISS_SCALE = Rational(Samples::HIGH << Samples::SHIFT, 2 * GENERATOR_SWING)

          # A voice's registers, counted from its first ($x0).
          VOLUME_LEFT = 0x0
          VOLUME_RIGHT = 0x1
          PITCH_LOW = 0x2
          PITCH_HIGH = 0x3
          SOURCE = 0x4
          ADSR1 = 0x5
          ADSR2 = 0x6
          GAIN = 0x7

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
          # Main volume, the most there is (127, on both sides).
          MAIN_VOLUME = 0x7F

          # Fastest attack, ADSR on (ADSR1); the sustain level at the top (ADSR2's high three bits),
          # so the note goes straight to its sustain, whose rate (ADSR2's low five bits) is its fade.
          ATTACK = 0x8F
          SUSTAIN_AT_TOP = 0xE0

          # How many of the DSP's samples each of the 32 envelope rates waits between steps, by rate:
          # nought never steps (fullsnes, "ADSR/Gain (and Noise) Rates").
          RATE_SAMPLES = [nil, 2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192, 160, 128, 96, 80, 64, 48, 40,
                          32, 24, 20, 16, 12, 10, 8, 6, 5, 4, 3, 2, 1].freeze

          # The envelope's top, and the level below which its top seven bits (ENVX) read nought.
          ENVELOPE_TOP = 0x7FF
          ENVELOPE_SILENT = 0x10

          # Eight steps of the voice's volume register (0..127) a step of the game's (0..15).
          VOLUME_STEP = 8

          # The pitch register's scale, and the most it holds.
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

          # A SONG'S SQUARE PARTS play on the voices the Advance's square voices are: the first part on
          # voice 0, the second on voice 1, which beeps share as they share the Advance's second. A
          # note holds at a fixed gain, as the Advance's song notes hold their volume, and a rest lets
          # the voice go. stop_music lets go of every voice a song plays on, as the Color's player
          # quiets all four.
          SQUARE_VOICES = { 1 => 0, 2 => 1 }.freeze
          SONG_VOICES = 0x0F

          # WHAT A LOG ENTRY DOES NOT SAY. The interpreter logs a song's note as the voice set to a
          # frequency and volume, which is all the Advance's player writes; the square's width is the
          # part's, written once. So the writes are worked out with the game's +waves+ (its wave
          # voice's waveforms, in the order its build recorded them, Samples::FIRST_WAVE on) and
          # +duties+, each song's square parts' widths by [the song's name, its channel].
          Voicing = Data.define(:waves, :duties) do
            def initialize(waves: [], duties: {}) = super
          end

          NO_VOICING = Voicing.new

          # The writes one sound-log entry means: [:enabled], [:beep, effect], [:noise, hit], [:wave,
          # params], [:stop_wave], a song's [:note, ...] (nothing: the [:voice, ...] after it is the
          # note) and [:voice, channel, song, frequency, volume], and [:stop_music]. Each is [register,
          # value], or [SET_BITS, register, mask, bits].
          def for_entry(entry, voicing = NO_VOICING)
            case entry.first
            when :enabled then [[SET_BITS, FLAGS, SWITCHES, SOUND_ON], [MAIN_LEFT, MAIN_VOLUME], [MAIN_RIGHT, MAIN_VOLUME]]
            when :beep then beep(entry.last)
            when :noise then noise(entry.last)
            when :wave then wave(entry.last, voicing.waves)
            when :stop_wave then key_off(1 << WAVE_VOICE)
            when :note then []
            when :voice then song_note(*entry.drop(1), voicing.duties)
            when :stop_music then key_off(SONG_VOICES)
            else raise ArgumentError, "the Super Nintendo build does not play #{entry.first.inspect} yet"
            end
          end

          # A song's note on channel +channel+: on a square voice, the note held at a fixed gain, or
          # the voice let go for a rest or a note at volume nought.
          def song_note(channel, song, frequency, volume, duties)
            voice = SQUARE_VOICES.fetch(channel) do
              raise ArgumentError, "the Super Nintendo build does not play a song's part on channel #{channel} yet"
            end
            return key_off(1 << voice) if frequency.zero? || volume.zero?

            duty = duties.fetch([song, channel]) { raise ArgumentError, "no square part of #{song.inspect} on #{channel}" }
            base = voice << 4
            wave = wave_for(frequency)
            pitch = pitch_for(frequency, wave)
            level = volume * VOLUME_STEP
            [[base + VOLUME_LEFT, level], [base + VOLUME_RIGHT, level], [base + PITCH_LOW, pitch & 0xFF],
             [base + PITCH_HIGH, pitch >> 8], [base + SOURCE, Samples.source(duty, wave)], [base + ADSR1, ADSR_OFF],
             [base + GAIN, FIXED_TOP]] + key_on(voice)
          end

          # The wave voice playing +params+ ({shape:, frequency:, volume:}, as the interpreter logs a
          # wave): its recording among +waves+, read at the note's pitch, held at a fixed gain.
          def wave(params, waves)
            base = WAVE_VOICE << 4
            steps = wave_steps(params)
            index = waves.index(steps) or raise ArgumentError, "the waveform #{steps.inspect} was not recorded for this game"
            pitch = pitch_for(params[:frequency], Samples::LONG_WAVE)
            level = VBlank::Audio::Sound::WAVE_STEP_MAX * VOLUME_STEP
            [[base + VOLUME_LEFT, level], [base + VOLUME_RIGHT, level], [base + PITCH_LOW, pitch & 0xFF],
             [base + PITCH_HIGH, pitch >> 8], [base + SOURCE, Samples::FIRST_WAVE + index], [base + ADSR1, ADSR_OFF],
             [base + GAIN, FIXED_TOP]] + key_on(WAVE_VOICE)
          end

          # Voice +voice+ started from the top: its key-off bit cleared, then its key-on.
          def key_on(voice) = [[SET_BITS, KEY_OFF, 1 << voice, 0], [KEY_ON, 1 << voice]]

          # The voices whose bits +voices+ holds let go, every other voice's key-off as it is.
          def key_off(voices) = [[SET_BITS, KEY_OFF, voices, voices]]

          # The 32 steps a wave plays, cut down to its loudness as the Advance cuts them
          # (Audio::Sound.wave_step_at): what its recording holds.
          def wave_steps(params)
            sound = VBlank::Audio::Sound
            volume = params[:volume]
            level = volume.is_a?(Symbol) ? volume : sound.wave_level(volume)
            sound.wavetable(params[:shape]).map { |step| sound.wave_step_at(step, level) }
          end

          # A beep: its voice's registers, and key-on last, which starts it from the top.
          def beep(effect)
            base = BEEP_VOICE << 4
            wave = wave_for(effect.frequency)
            pitch = pitch_for(effect.frequency, wave)
            loudness(base, effect.volume * VOLUME_STEP, effect.volume, effect.decay) +
              [[base + PITCH_LOW, pitch & 0xFF], [base + PITCH_HIGH, pitch >> 8],
               [base + SOURCE, Samples.source(effect.duty, wave)], *key_on(BEEP_VOICE)]
          end

          # A noise hit (Audio::Sound.resolve_noise's hash): the noise voice's loudness and fade, as a
          # beep's; then the generator, its clock set and the voice switched to it, or the metallic
          # recording read at the clock; and key-on last.
          def noise(hit)
            base = NOISE_VOICE << 4
            clock = VBlank::Audio::Sound.noise_rung_hz(0, VBlank::Audio::Sound::NOISE_HIT_HALVINGS.fetch(hit[:pitch]))
            if hit[:metallic]
              pitch = (clock * PITCH_ONE / DSP_RATE.to_f).round.clamp(1, PITCH_TOP)
              loudness(base, hit[:volume] * VOLUME_STEP, hit[:volume], hit[:decay]) +
                [[base + PITCH_LOW, pitch & 0xFF], [base + PITCH_HIGH, pitch >> 8], [base + SOURCE, Samples::METALLIC],
                 [NOISE_ON, 0], *key_on(NOISE_VOICE)]
            else
              # The generator still reads a recording beside it, and one that ends would end the
              # noise (fullsnes, "NON"): a looping one, read at any pitch.
              loudness(base, (hit[:volume] * VOLUME_STEP * HISS_SCALE).round, hit[:volume], hit[:decay]) +
                [[base + PITCH_LOW, 0], [base + PITCH_HIGH, PITCH_ONE >> 8],
                 [base + SOURCE, Samples.source(:half, Samples::LONG_WAVE)],
                 [SET_BITS, FLAGS, NOISE_CLOCK, noise_rate(clock)], [NOISE_ON, 1 << NOISE_VOICE], *key_on(NOISE_VOICE)]
            end
          end

          # A voice's volume registers (+level+, left and right) and its envelope: the fastest attack,
          # and the fade for a note of +volume+ (0..15) at +decay+.
          def loudness(base, level, volume, decay)
            [[base + VOLUME_LEFT, level], [base + VOLUME_RIGHT, level], [base + ADSR1, ATTACK],
             [base + ADSR2, SUSTAIN_AT_TOP | fade_rate(volume, decay)]]
          end

          # The noise generator's rate (1..31) nearest to stepping +clock+ times a second.
          def noise_rate(clock)
            (1...RATE_SAMPLES.size).min_by { |rate| (Math.log(DSP_RATE.to_f / RATE_SAMPLES[rate]) - Math.log(clock)).abs }
          end

          # The length of wave a +frequency+ Hz note is played on: the long one, unless the pitch
          # register cannot read it that fast.
          def wave_for(frequency) = raw_pitch(frequency, Samples::LONG_WAVE) <= PITCH_TOP ? Samples::LONG_WAVE : Samples::SHORT_WAVE

          # The pitch register for a +frequency+ Hz note on a wave of +wave+ samples, held to what the
          # register holds: a note above what the short wave reaches plays at the highest it can.
          def pitch_for(frequency, wave) = raw_pitch(frequency, wave).clamp(1, PITCH_TOP)

          def raw_pitch(frequency, wave) = ((frequency * wave * PITCH_ONE) / DSP_RATE.to_f).round

          # The sustain rate (0..31) that fades a note of +volume+ (0..15) at +decay+ in about the
          # Advance's time for it; nought, which never steps, for :none.
          def fade_rate(volume, decay)
            step = VBlank::Audio::Sound::FADE_STEP_SIXTY_FOURTHS.fetch(decay)
            return 0 if step.zero?

            wanted = volume * step * DSP_RATE / 64.0 / steps_to_silence
            (1...RATE_SAMPLES.size).min_by { |rate| (Math.log(RATE_SAMPLES[rate]) - Math.log([wanted, 1].max)).abs }
          end

          # How many steps the sustain mode takes the envelope from the top to where ENVX reads nought:
          # each step takes off ((level - 1) >> 8) + 1 (fullsnes).
          def steps_to_silence
            level = ENVELOPE_TOP
            steps = 0
            while level >= ENVELOPE_SILENT
              level -= ((level - 1) >> 8) + 1
              steps += 1
            end
            steps
          end

          # What the registers hold after the sound log +entries+, by register, for each one written,
          # and FLG and KOFF, which the sound unit starts as at_power_on says and whose bits an entry
          # changes only some of. +voicing+ as for #for_entry.
          def after(entries, voicing = NO_VOICING)
            held = { FLAGS => SOUND_OFF, KEY_OFF => 0 }
            entries.each do |entry|
              for_entry(entry, voicing).each do |register, *value|
                if register == SET_BITS
                  register, mask, bits = value
                  held[register] = (held[register] & ~mask & 0xFF) | (bits & mask)
                else
                  held[register] = value.first
                end
              end
            end
            held
          end
        end
      end
    end
  end
end
