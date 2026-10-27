# frozen_string_literal: true

module VBlank
  module Audio
    # The shared meaning of the sound ops — the one place that knows what a "beep"
    # or a note *is*, so every backend agrees on it (the audio counterpart to how
    # Int32 pins arithmetic). It has two layers:
    #
    #   * the musical layer (this module directly): named sound-effect presets, the
    #     rule for resolving a beep's tone + overrides into concrete musical values —
    #     a frequency in Hz, a wave shape, a fade, a volume — and what each kind of
    #     voice can actually do, which every backend has to honour whether or not it
    #     writes a register (SQUARE_LOWEST_HZ, wave_level). This layer is hardware-free,
    #     so a headless interpreter can use it to say "an 880 Hz blip played" without
    #     any notion of registers.
    #
    #   * Registers: the console-specific encoding — turning those musical values
    #     into the exact sound-register writes the hardware needs. A backend that
    #     lowers to a real ROM uses this; the interpreter never does, and a test says
    #     so rather than leaving it to whoever edits next
    #     (test/vblank/audio/test_registers_seam.rb).
    module Sound
      # One resolved beep, purely musical — no hardware in sight. The four parts are fixed
      # here rather than named by a caller, so it is a value object and asking it for anything
      # else says so.
      Effect = Data.define(:frequency, :duty, :decay, :volume)

      # Built-in sound-effect presets, as plain musical values. A game refers to
      # one by name (beep :blip) instead of spelling out the numbers.
      PRESETS = {
        high:  Effect.new(frequency: 880,  duty: :half,    decay: :fast,   volume: 15),
        low:   Effect.new(frequency: 220,  duty: :half,    decay: :fast,   volume: 15),
        blip:  Effect.new(frequency: 1200, duty: :quarter, decay: :fast,   volume: 12),
        thud:  Effect.new(frequency: 110,  duty: :half,    decay: :medium, volume: 15),
        score: Effect.new(frequency: 660,  duty: :half,    decay: :medium, volume: 15),
      }.freeze

      # What a bare-frequency beep uses for the parts the caller didn't specify — a beep with
      # everything settled but its pitch, which is what the caller is about to supply.
      DEFAULTS = Effect.new(frequency: nil, duty: :half, decay: :fast, volume: 15)

      # HOW MANY RECORDED SOUNDS PLAY AT ONCE, and it lives here because it is a promise the
      # backends make to each other rather than a fact about either one. Past this a new play
      # is dropped — safe and quiet — instead of cutting off one already sounding.
      #
      # It was written down twice, once in the lowering and once in the interpreter, each
      # saying in its comment that it matched the other. They did match, by the care of
      # whoever edited them last and nothing else: change one and the console would drop a
      # sound the interpreter still played, which shows up only on the one sound too many and
      # would be read as a mixing bug rather than as two numbers drifting apart.
      #
      # SIXTEEN IS THE FRAMEWORK'S NUMBER, NOT THE CONSOLE'S. The console has no count of
      # recordings at all: the CPU adds them together and the sound hardware plays the one
      # stream. What a voice costs is the mixing, and only while it sounds — an idle slot is a
      # check a frame — so the number is room, and sixteen is what the music being asked of the
      # framework needs: songs of up to twelve recorded parts, with sounds of the game's own
      # beside them.
      MIXER_VOICES = 16

      # THE NUMBERS THE MIX ADDS RECORDINGS TOGETHER WITH, kept here for the same reason: the
      # cartridge's mixer and the interpreter's work out the same bytes of sound, and a number
      # written in each would drift.
      #
      # A play's loudness, out of 512, by the name it was asked at. The mix multiplies by 256ths
      # (VOL_SHIFT divides by them), and a loudness keeps LOUDNESS_FRACTION bit under that: half
      # a 256th. That is the scale a cartridge's own sound engine keeps a voice at. It holds the
      # voice's right and left volumes and mixes by their SUM, so 17 + 16 is 33 512ths, and a
      # note handed over as 17 256ths would be louder than the engine's by the half it dropped.
      # Music decoded off one is given its notes' loudness as that engine had them: its
      # quietest notes are still heard, and its loudest, about half the recording, is that loud
      # here too.
      # A STEP, how far a voice reads through its recording for each sample of the mix, is
      # counted in 65536ths, so STEP_SHIFT bits of it are the part of a sample. What the mix
      # multiplies by is a voice's GAIN, its loudness in 256ths with GAIN_FRACTION bits of
      # fraction under it, which a note with a shape slides: sixteen is as many as fit, since a
      # gain of at most 256 is then 24 bits and a sample of at most 128 is 7 more, which the sign
      # bit has room for. A loudness's half a 256th is the top one of those sixteen. The slide is
      # a distance divided by the samples in a frame, done as a multiply by one sample's share
      # out of 1 << (2 * RAMP_SPLIT), with the distance shifted down RAMP_SPLIT bits before it and
      # the product after, so a whole gain's worth of distance stays inside 32 bits on the way.
      MIX_LEVELS = { full: 512, three_quarter: 384, half: 256, quarter: 128, mute: 0 }.freeze
      VOL_SHIFT = 8
      LOUDNESS_FRACTION = 1
      STEP_SHIFT = 16
      GAIN_FRACTION = 16
      LOUDNESS_TO_GAIN = GAIN_FRACTION - LOUDNESS_FRACTION # a loudness shifted up this far is its gain
      RAMP_SPLIT = 8

      # Resolve a beep into concrete musical values. +tone+ is either a preset name
      # (looked up first among the program's own +defined+ sounds, then the built-in
      # PRESETS) or a raw frequency in Hz. Any non-nil override replaces the base
      # value — which is all #with does, once the ones nobody gave are dropped.
      def self.resolve_effect(tone, duty: nil, decay: nil, volume: nil, defined: {})
        base =
          if tone.is_a?(Symbol)
            defined[tone] || PRESETS[tone] ||
              raise(ArgumentError, "unknown sound preset #{tone.inspect} — " \
                                   "built-in: #{PRESETS.keys.join(', ')}; " \
                                   "define your own with define_sound")
          else
            DEFAULTS.with(frequency: tone)
          end

        base.with(**{ duty: duty, decay: decay, volume: volume }.compact)
      end

      # Built-in noise presets — the percussion voice, as plain intent. A game says
      # `noise :explosion` and gets a rumble; the numbers are the framework's job.
      # +pitch+ is how high the hiss sits (:low rumble … :high hiss), +decay+ how
      # fast it fades, +metallic+ a tighter, more tonal rattle (for a snare/hat).
      NOISE_PRESETS = Ractor.make_shareable({
        hit:       { pitch: :mid,  decay: :fast,   volume: 12, metallic: false },
        kick:      { pitch: :low,  decay: :medium, volume: 15, metallic: false },
        snare:     { pitch: :mid,  decay: :fast,   volume: 13, metallic: true },
        hat:       { pitch: :high, decay: :fast,   volume: 8,  metallic: true },
        explosion: { pitch: :low,  decay: :slow,   volume: 15, metallic: false },
        zap:       { pitch: :high, decay: :medium, volume: 12, metallic: false },
      })

      # What an unnamed noise hit defaults to.
      NOISE_DEFAULT = :hit

      # Resolve a noise hit into concrete musical values. +preset+ names a built-in
      # (or is nil for the default hit); any non-nil override replaces the preset's
      # value. Purely musical — no hardware in sight.
      def self.resolve_noise(preset, pitch: nil, decay: nil, volume: nil, metallic: nil)
        base = NOISE_PRESETS.fetch(preset || NOISE_DEFAULT) do
          raise ArgumentError, "unknown noise preset #{preset.inspect} — " \
                               "built-in: #{NOISE_PRESETS.keys.join(', ')}"
        end

        {
          pitch:    pitch  || base[:pitch],
          decay:    decay  || base[:decay],
          volume:   volume || base[:volume],
          metallic: metallic.nil? ? base[:metallic] : metallic,
        }
      end

      # The wave voice (channel 3) plays a short looping waveform — a wavetable — so
      # it can make richer, non-square timbres than the two square channels. A shape
      # name resolves to 32 four-bit samples (0-15); the same table both backends use,
      # so they agree on the timbre. WAVE_SAMPLES is the table size the hardware loops.
      WAVE_SAMPLES = 32

      # ...and how loud one step can be. Four bits, so 0 is silence and 15 is the top.
      WAVE_STEP_MAX = 15

      # WHAT THE TWO KINDS OF VOICE CAN ACTUALLY DO. These are limits, not encodings, which is
      # why they sit out here with the musical half rather than inside Registers: a backend that
      # never writes a register still has to honour them, or the two backends disagree about
      # what a game sounds like.
      #
      # The wave voice has FIVE loudnesses and not a range — off, and four steps — so a part
      # written at volume 6 of 15 plays at the nearest of them. Every backend rounds the same
      # way, and one that rounded 6 down to silence while another rounded it up would differ on
      # whether a note is heard at all.
      WAVE_LEVEL_STEPS = %i[mute quarter half three_quarter full].freeze

      # Round a 0..15 volume to the level the wave voice really has.
      def self.wave_level(volume)
        WAVE_LEVEL_STEPS[((volume.clamp(0, 15) * (WAVE_LEVEL_STEPS.size - 1)) / 15.0).round]
      end

      # THE LOWEST PITCH A SQUARE VOICE REACHES, 64 Hz — just under C2. The console tunes those
      # voices by a period value that cannot go past its own bottom, so a lower note does not
      # play low, it plays AT 64 Hz: a different note, quietly wrong rather than silent. That is
      # what the guardrail warns about before the cartridge exists, so the number has to be
      # readable without a register in sight. (The wave voice tunes by a sample rate instead and
      # reaches an octave lower, which is most of why a tune puts its bass there.)
      SQUARE_LOWEST_HZ = 131_072 / 2048

      # WHAT A SQUARE VOICE SOUNDS LIKE, for a backend that has to make the sound itself rather
      # than tell a chip to: the pitch it really plays, how thin its tone is, and how fast it
      # fades. A cartridge writes these to the sound chip as bit patterns (Registers, below); a
      # desktop build has no chip and builds the wave from the same three facts.
      #
      # THE PITCH IS A WHOLE NUMBER OF TICKS, not any frequency at all. The voice counts a clock
      # of 131,072 ticks a second and one wave lasts a whole number of them, 1 to 2048 — so 440 Hz
      # is played as 298 ticks a wave, a hair under 440. Every backend has to round the same way
      # or two voices in tune on one are a beat apart on the other.
      SQUARE_CLOCK_HZ = 131_072
      SQUARE_LONGEST_WAVE = 2048

      # How many ticks one wave of a +hz+ note lasts on a square voice.
      def self.square_wave_ticks(hz)
        SQUARE_LONGEST_WAVE - (SQUARE_LONGEST_WAVE - (SQUARE_CLOCK_HZ.to_f / hz)).round.clamp(0, SQUARE_LONGEST_WAVE - 1)
      end

      # How much of each wave is spent high, in eighths: a half wave is the full, hollow tone,
      # and the narrower ones are thinner and brighter.
      SQUARE_HIGH_EIGHTHS = { eighth: 1, quarter: 2, half: 4, square: 4, three_quarter: 6 }.freeze

      # How long a fading note holds each of its volume steps, in 64ths of a second — the pace
      # the voice counts its fade at. A note at volume 15 fading `:fast` is gone in 15/64 of a
      # second; `:none` never fades.
      FADE_STEP_SIXTY_FOURTHS = { fast: 1, medium: 3, slow: 5, none: 0 }.freeze

      # WHAT THE WAVE VOICE SOUNDS LIKE, for the same backend: the pitch it really plays, and how
      # tall each step of its waveform comes out at each of its loudnesses.
      #
      # ITS PITCH IS A WHOLE NUMBER OF TICKS TOO, of a clock half as fast as the square voices':
      # 65,536 ticks a second, and one whole wave — all 32 steps of it — lasts 1 to 2048 of them.
      # A longer wave is a lower note, so this voice bottoms out at 32 Hz where a square voice
      # stops at 64, and a note below that is played AT 32 Hz.
      WAVE_CLOCK_HZ = 65_536
      WAVE_LONGEST_WAVE = 2048

      # How many ticks one whole wave of a +hz+ note lasts on the wave voice.
      def self.wave_voice_ticks(hz)
        WAVE_LONGEST_WAVE - (WAVE_LONGEST_WAVE - (WAVE_CLOCK_HZ.to_f / hz)).round.clamp(0, WAVE_LONGEST_WAVE - 1)
      end

      # ITS LOUDNESS CUTS EACH STEP DOWN, and what does not divide is dropped: the voice makes its
      # four loudnesses by taking so many quarters of a step, in whole numbers. So a step of 15
      # at half is 7 and not seven and a half, and a quiet waveform has fewer different heights
      # in it than a loud one — a quarter-loud triangle is a staircase of four treads.
      def self.wave_step_at(step, level)
        (step * wave_level_quarters(level)) / 4
      end

      # How many quarters of each step a loudness keeps: none for :mute, all four for :full.
      def self.wave_level_quarters(level)
        WAVE_LEVEL_STEPS.index(level) or raise ArgumentError, "unknown wave volume #{level.inspect}"
      end

      # WHAT THE NOISE VOICE SOUNDS LIKE, for the same backend.
      #
      # THE HISS IS A ROW OF BITS SHUFFLED ALONG ONE PLACE AT A TIME. Each step the voice is high
      # or low by the bit that falls off the end, and the bits left behind are stirred so the
      # pattern takes a long time to come round. How fast it steps is the pitch: fast is a thin
      # high hiss, slow a rumble.
      #
      # A STEP IS A WHOLE NUMBER OF TICKS of a clock of 524,288 a second. The voice has no free
      # choice of that number. It picks a divider (0 to 7, where 0 stands for a half) and how
      # many times to halve what the divider leaves (0 to 13), so a step lasts twice the divider,
      # doubled once for each halving — a ladder of rungs rather than a range.
      NOISE_CLOCK_HZ = 524_288
      NOISE_DIVIDERS = (0..7).to_a.freeze
      NOISE_HALVINGS = (0..13).to_a.freeze

      # How many ticks one step of the hiss lasts for a divider and a number of halvings.
      def self.noise_step_ticks(divider, halvings)
        (divider.zero? ? 1 : divider * 2) << halvings
      end

      # How many steps a second that rung of the ladder makes.
      def self.noise_rung_hz(divider, halvings)
        NOISE_CLOCK_HZ / (divider.zero? ? 0.5 : divider) / (2**(halvings + 1))
      end

      # The rung nearest a wanted pitch, as its divider and its halvings — what makes a low note
      # on the noise voice a kick and a high one a hat.
      def self.noise_rung(hz)
        NOISE_DIVIDERS.product(NOISE_HALVINGS).min_by do |divider, halvings|
          (noise_rung_hz(divider, halvings) - hz).abs
        end
      end

      # How long a step lasts for a note of +hz+ on the noise voice.
      def self.noise_note_step_ticks(hz) = noise_step_ticks(*noise_rung(hz))

      # A `noise` hit names its pitch with one of three words, and each is a number of halvings
      # of the fastest step there is.
      NOISE_HIT_HALVINGS = { high: 2, mid: 5, low: 8 }.freeze

      # How long a step lasts for a hit at one of those three pitches.
      def self.noise_hit_step_ticks(pitch)
        halvings = NOISE_HIT_HALVINGS.fetch(pitch) { raise ArgumentError, "unknown noise pitch #{pitch.inspect}" }
        noise_step_ticks(0, halvings)
      end

      # HOW MANY BITS ARE IN THE ROW: fifteen for a plain hiss, whose pattern is 32,767 steps
      # long and never heard to repeat, and seven for a metallic one, which comes round every
      # 127 steps — often enough to be heard as a pitch of its own, the rattle of a snare or a
      # hat.
      def self.noise_register_bits(metallic) = metallic ? 7 : 15

      # WHAT THE WAVE VOICE PLAYS, which is one of two things a game can say.
      #
      # A NAME is the usual answer — `wave :triangle, :C4`, `plays: :sine` — and the samples are
      # the framework's job. Four names cover the timbres most games reach for.
      #
      # THE STEPS THEMSELVES are the other, and they are here because the named shapes are a
      # convenience rather than the truth: the console's wave voice is not a set of timbres, it is
      # 32 steps of four bits that a game writes. A game whose music came from somewhere else —
      # decoded out of another cartridge, drawn in a tracker — arrives holding those 32 numbers,
      # and no name it could be given would be the waveform it actually has. A pulse is the common
      # case and is none of the four: played as a triangle it is a different instrument, which a
      # player hears without being able to name.
      #
      # So a list of 32 steps goes wherever a name goes. Name them in your own program
      # (`PULSE_50 = [15] * 16 + [0] * 16`) and the call site still reads like game code.
      def self.wavetable(shape)
        return wave_steps!(shape) if shape.is_a?(Array)

        case shape
        when :square
          Array.new(WAVE_SAMPLES) { |i| i < WAVE_SAMPLES / 2 ? 15 : 0 }
        when :sawtooth
          Array.new(WAVE_SAMPLES) { |i| (i * 15.0 / (WAVE_SAMPLES - 1)).round }
        when :triangle
          Array.new(WAVE_SAMPLES) do |i|
            up = i < WAVE_SAMPLES / 2
            pos = up ? i : (WAVE_SAMPLES - 1 - i)
            (pos * 15.0 / (WAVE_SAMPLES / 2 - 1)).round.clamp(0, 15)
          end
        when :sine
          Array.new(WAVE_SAMPLES) { |i| (7.5 + 7.5 * Math.sin(2 * Math::PI * i / WAVE_SAMPLES)).round.clamp(0, 15) }
        else
          raise ArgumentError, "The wave shape #{shape.inspect} is not known. Use :sine, :triangle, " \
                               ":sawtooth or :square. Or give #{WAVE_SAMPLES} steps of 0 to 15, to " \
                               "play a waveform of your own."
        end
      end

      # A WAVEFORM GIVEN AS ITS STEPS, checked and handed back. The two rules are the hardware's:
      # the voice loops exactly 32 steps, and each one is four bits. Both are said at the line
      # that wrote the waveform, because a list of numbers is the one thing here a person cannot
      # check by looking at it.
      def self.wave_steps!(steps)
        unless steps.length == WAVE_SAMPLES
          raise ArgumentError, "A waveform is #{WAVE_SAMPLES} steps. This one has #{steps.length}. " \
                               "The wave voice loops #{WAVE_SAMPLES} steps, so give that many."
        end

        bad = steps.find { |step| !step.is_a?(Integer) || !step.between?(0, WAVE_STEP_MAX) }
        return steps if bad.nil?

        raise ArgumentError, "A waveform step is a whole number from 0 to #{WAVE_STEP_MAX}. " \
                             "Step #{steps.index(bad)} is #{bad.inspect}."
      end

      # The console-specific half: encode musical values into sound-register writes.
      # Each method returns a list of [register_address, 16-bit value] pairs in the
      # order they must be written; a backend just stores each one.
      module Registers
        include VBlank::Console::Hardware
        module_function

        # Wave shape → the 2-bit duty field the hardware wants.
        DUTY_CYCLES = {
          eighth: 0, quarter: 1, half: 2, square: 2, three_quarter: 3
        }.freeze

        # Fade speed → the envelope step the hardware counts down by, which is the number of
        # 64ths of a second it holds each volume step for.
        DECAY_PRESETS = FADE_STEP_SIXTY_FOURTHS

        # Noise pitch → the noise generator's shift-clock exponent. The hiss's
        # frequency divides down as the exponent grows, so a bigger number is a
        # lower, rumblier noise and a smaller one a higher hiss.
        NOISE_SHIFTS = NOISE_HIT_HALVINGS

        # The console tunes a channel by a period value, not a frequency:
        # freq_hz = 131072 / (2048 - value). Invert that and keep it in range.
        def frequency_value(freq_hz)
          SQUARE_LONGEST_WAVE - Sound.square_wave_ticks(freq_hz)
        end

        def duty_bits(duty)
          DUTY_CYCLES.fetch(duty) { raise ArgumentError, "unknown duty cycle #{duty.inspect}" }
        end

        def decay_step(decay)
          DECAY_PRESETS.fetch(decay) { raise ArgumentError, "unknown decay #{decay.inspect}" }
        end

        # Power on the sound hardware: master enable, all four PSG channels routed to
        # both speakers at full volume, PSG output at 100%. Routing every channel
        # (0xFF..) rather than just the first two means a music voice on channel 2 or
        # a noise hit on channel 4 is actually heard; a channel stays silent until it
        # is triggered, so routing an unused one costs nothing.
        # +direct_sound+ is the SOUNDCNT_H routing that must SURVIVE being switched on — the bits
        # that send recorded sound to the speakers. They matter because this writes that register
        # whole, and the register is shared: its low bits are the PSG's volume, which is this
        # verb's to set, and its high bits route the recordings, which are the mixer's. Written
        # whole with the PSG bits alone, a program that switches sound on after the mixer came up
        # switches every recording off — silently, since the PSG parts of the same tune keep
        # playing. The caller that knows whether a recording plays hands the bits in
        # (GBA::Audio#emit_enable_sound); a program with no recording hands in nothing.
        def enable(direct_sound: 0)
          [
            [REG_SOUNDCNT_X, SOUND_MASTER_ENABLE],
            [REG_SOUNDCNT_L, 0xFF77],
            [REG_SOUNDCNT_H, PSG_VOLUME_FULL | direct_sound],
          ]
        end

        # A one-off sound effect on channel 2 (the SFX channel): duty + volume +
        # fade, then frequency with the trigger bit that restarts the note.
        def beep_writes(frequency:, duty:, decay:, volume:)
          control = (duty_bits(duty) << 6) | (volume << 12) | (decay_step(decay) << 8)
          trigger = 0x8000 | frequency_value(frequency)
          [[REG_SOUND2CNT_L, control], [REG_SOUND2CNT_H, trigger]]
        end

        # A single music note on one of the two square-wave voices (the music
        # channels): channel 1 or channel 2. Music notes sustain (no fade) until the
        # next note replaces them, so both voices of a layered tune hold their pitch
        # between events. A song's parts map to these in order; +channel+ is chosen by
        # the backend, not the score.
        def channel_note(channel, frequency:, duty:, volume:)
          case channel
          when 1 then channel1_note(frequency: frequency, duty: duty, volume: volume)
          when 2 then channel2_note(frequency: frequency, duty: duty, volume: volume)
          else raise ArgumentError, "no music voice on channel #{channel}"
          end
        end

        # A single music note on channel 1 (the first music voice). A frequency of 0
        # is a rest — silence the voice. Sustains until the next note replaces it.
        def channel1_note(frequency:, duty:, volume:)
          return [[REG_SOUND1CNT_H, 0x0000], [REG_SOUND1CNT_X, 0x8000]] if frequency.zero?

          control = (duty_bits(duty) << 6) | (volume << 12)
          trigger = 0x8000 | frequency_value(frequency)
          [
            [REG_SOUND1CNT_L, 0x0000], # no sweep
            [REG_SOUND1CNT_H, control],
            [REG_SOUND1CNT_X, trigger],
          ]
        end

        # A single music note on channel 2 (the second music voice), for a layered
        # tune's harmony/bass part. Same sustaining behavior as channel 1, but this
        # voice has no sweep register, so it's just control + trigger. A frequency of
        # 0 is a rest. (Channel 2 doubles as the SFX voice; a two-part song and beeps
        # can't both use it at once.)
        def channel2_note(frequency:, duty:, volume:)
          return [[REG_SOUND2CNT_L, 0x0000], [REG_SOUND2CNT_H, 0x8000]] if frequency.zero?

          control = (duty_bits(duty) << 6) | (volume << 12)
          trigger = 0x8000 | frequency_value(frequency)
          [[REG_SOUND2CNT_L, control], [REG_SOUND2CNT_H, trigger]]
        end

        # A SINGLE MUSIC NOTE ON THE WAVE VOICE (channel 3), for a song part that plays it.
        #
        # Two register values, like a square note, and for the same reason: the player copies two
        # halfwords out of the score and the waveform itself is already in wave RAM, uploaded once
        # when the tune started. The level holds the note and the trigger restarts the waveform.
        # A frequency of 0 is a rest, which mutes the voice without disturbing the table.
        #
        # It reaches LOWER than a square voice: this one tunes by a sample rate, so its bottom is
        # 32 Hz against the square voices' 64 — an octave further down, which is most of why a
        # tune puts its bass here.
        # +volume+ is 0..15, the same scale a square part's is written on — the wave voice has
        # four fixed levels and off rather than a range, so it is rounded to the nearest.
        def wave_note(frequency:, volume:)
          return [[REG_SOUND3CNT_H, 0x0000], [REG_SOUND3CNT_X, 0x0000]] if frequency.zero?

          [[REG_SOUND3CNT_H, WAVE_VOLUMES.fetch(Sound.wave_level(volume))],
           [REG_SOUND3CNT_X, 0x8000 | wave_rate(frequency)]]
        end

        # Put a waveform in wave RAM and switch the voice on — the once-per-tune half of the pair
        # above, split out because a note must not pay for it. Answers the eight halfwords the
        # table packs into; which register they go to, and in what order, is the player's to emit
        # (see Audio#emit_upload_wavetable): both banks get the table, so whichever one the voice
        # loops, it loops this waveform.
        def wavetable_halfwords(shape) = pack_wavetable(VBlank::Audio::Sound.wavetable(shape))

        # A SINGLE MUSIC NOTE ON THE NOISE VOICE (channel 4), for a song part that plays it — the
        # drums. Two register values again, so the player copies two halfwords here too.
        #
        # WHAT A NOTE MEANS HERE is the one thing about this voice that has to be decided rather
        # than followed: the noise voice makes a hiss, not a tone, so there is no pitch in the way
        # a melody has one. What it does have is a CLOCK, and a faster clock is a higher, thinner
        # hiss where a slower one is a low rumble. So a note's pitch picks the clock nearest to it
        # (#noise_clock), which is what a tracker's noise channel does and what makes a low note a
        # kick and a high one a hat. The fade is the part's, not the note's: a drum hit rings out
        # and is not held until the next one.
        #
        # A frequency of 0 is a rest: the voice restarts at no volume at all, which stops a hit
        # that was still ringing.
        def noise_note(frequency:, decay:, volume:, metallic:)
          return [[REG_SOUND4CNT_L, 0x0000], [REG_SOUND4CNT_H, 0x8000]] if frequency.zero?

          divisor, shift = noise_clock(frequency)
          control = (volume << 12) | (decay_step(decay) << 8)
          [[REG_SOUND4CNT_L, control],
           [REG_SOUND4CNT_H, 0x8000 | (shift << 4) | (metallic ? 0x0008 : 0x0000) | divisor]]
        end

        # The noise voice's clock is 524288 Hz divided by a small number and then halved +shift+
        # times over, so the rates it can make are a fixed ladder rather than a range. This finds
        # the rung nearest a wanted pitch. A divisor of 0 means a half, which is the one rung
        # above the rest of the ladder. The ladder itself is a fact about the voice that every
        # backend keeps (Sound.noise_rung); what is the console's alone is that the two numbers
        # go into a register.
        NOISE_CLOCK = NOISE_CLOCK_HZ
        NOISE_DIVISORS = NOISE_DIVIDERS
        NOISE_SHIFT_RANGE = (NOISE_HALVINGS.first..NOISE_HALVINGS.last).freeze

        def noise_clock(frequency) = Sound.noise_rung(frequency)

        def noise_frequency(divisor, shift) = Sound.noise_rung_hz(divisor, shift)

        # A percussion / explosion hit on channel 4 (the noise voice). Channel 4
        # makes pseudo-random noise rather than a pitched tone: a control word sets
        # the starting volume and how fast it fades (the envelope, same layout as the
        # square channels), and a trigger word sets how high the hiss sits (the shift
        # clock), whether it's the tighter 7-bit "metallic" noise or the full 15-bit
        # hiss, and the restart bit. The envelope fades it to silence, so no note
        # length is needed.
        def noise_hit_writes(pitch:, decay:, volume:, metallic:)
          shift = NOISE_SHIFTS.fetch(pitch) { raise ArgumentError, "unknown noise pitch #{pitch.inspect}" }
          control = (volume << 12) | (decay_step(decay) << 8)  # fades out (envelope counts down)
          trigger = 0x8000 | (shift << 4) | (metallic ? 0x0008 : 0x0000)
          [[REG_SOUND4CNT_L, control], [REG_SOUND4CNT_H, trigger]]
        end

        # Channel 3's output levels — it has no envelope like the other channels,
        # just a fixed volume: full, three-quarter, half, quarter, or silent.
        WAVE_VOLUMES = {
          mute:          0x0000,
          full:          0x2000, # bits 13-14 = 1 (100%)
          half:          0x4000, # bits 13-14 = 2 (50%)
          quarter:       0x6000, # bits 13-14 = 3 (25%)
          three_quarter: 0x8000, # bit 15 forces 75%
        }.freeze

        # Play a wavetable on channel 3 (the wave voice). +samples+ is 32 values
        # (0-15) that the hardware loops as one waveform period. Unlike the square and
        # noise voices there's no envelope: the tone holds at +volume+ until it is
        # replaced or stopped.
        #
        # The waveform lives in a small block of "wave RAM" split into two banks; the
        # CPU can reach one bank while the channel plays the other, which is a classic
        # source of silence (upload to the bank that isn't playing and you hear
        # nothing). To sidestep that entirely we write the same table to *both* banks,
        # so whichever one the channel loops, it loops our waveform.
        def wave_start_writes(samples, frequency:, volume:)
          level = WAVE_VOLUMES.fetch(volume) { raise ArgumentError, "unknown wave volume #{volume.inspect}" }
          halfwords = pack_wavetable(samples)

          writes = []
          writes << [REG_SOUND3CNT_L, 0x0000]                 # DAC off, CPU reaches bank 0
          halfwords.each_with_index { |hw, i| writes << [REG_WAVE_RAM + (i * 2), hw] }
          writes << [REG_SOUND3CNT_L, 0x0040]                 # DAC off, CPU reaches bank 1
          halfwords.each_with_index { |hw, i| writes << [REG_WAVE_RAM + (i * 2), hw] }
          writes << [REG_SOUND3CNT_L, 0x0080]                 # DAC on, one 32-sample bank
          writes << [REG_SOUND3CNT_H, level]
          writes << [REG_SOUND3CNT_X, 0x8000 | wave_rate(frequency)] # restart bit + sample rate
          writes
        end

        # Silence the wave voice — switch its DAC off.
        def wave_stop
          [[REG_SOUND3CNT_L, 0x0000]]
        end

        # Channel 3 tunes by a sample rate, and a 32-sample waveform completes one
        # cycle every 32 samples, so the tone works out to 65536/(2048-value) Hz.
        # Invert that for the register value and keep it in range.
        def wave_rate(freq_hz)
          WAVE_LONGEST_WAVE - Sound.wave_voice_ticks(freq_hz)
        end

        # Pack 32 four-bit samples into wave RAM's eight 16-bit words. Two samples to
        # a byte (the earlier sample in the high nibble), two bytes to a little-endian
        # word.
        def pack_wavetable(samples)
          bytes = samples.each_slice(2).map { |hi, lo| ((hi & 0xF) << 4) | (lo & 0xF) }
          bytes.each_slice(2).map { |low, high| ((high || 0) << 8) | low }
        end
      end
    end
  end
end
