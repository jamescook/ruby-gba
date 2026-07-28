# frozen_string_literal: true

module RubyGBA
  # The shared meaning of the sound ops — the one place that knows what a "beep"
  # or a note *is*, so every backend agrees on it (the audio counterpart to how
  # Int32 pins arithmetic). It has two layers:
  #
  #   * the musical layer (this module directly): named sound-effect presets and
  #     the rule for resolving a beep's tone + overrides into concrete musical
  #     values — a frequency in Hz, a wave shape, a fade, a volume. This layer is
  #     hardware-free, so a headless interpreter can use it to say "an 880 Hz
  #     blip played" without any notion of registers.
  #
  #   * Registers: the console-specific encoding — turning those musical values
  #     into the exact sound-register writes the hardware needs. A backend that
  #     lowers to a real ROM uses this; the interpreter never does.
  module Sound
    # Built-in sound-effect presets, as plain musical values. A game refers to
    # one by name (beep :blip) instead of spelling out the numbers.
    PRESETS = {
      high:  { frequency: 880,  duty: :half,    decay: :fast,   volume: 15 },
      low:   { frequency: 220,  duty: :half,    decay: :fast,   volume: 15 },
      blip:  { frequency: 1200, duty: :quarter, decay: :fast,   volume: 12 },
      thud:  { frequency: 110,  duty: :half,    decay: :medium, volume: 15 },
      score: { frequency: 660,  duty: :half,    decay: :medium, volume: 15 },
    }.freeze

    # What a bare-frequency beep uses for the parts the caller didn't specify.
    DEFAULTS = { duty: :half, decay: :fast, volume: 15 }.freeze

    # Resolve a beep into concrete musical values. +tone+ is either a preset name
    # (looked up first among the program's own +defined+ sounds, then the built-in
    # PRESETS) or a raw frequency in Hz. Any non-nil override replaces the base
    # value. The result is purely musical — no hardware in sight.
    def self.resolve_effect(tone, duty: nil, decay: nil, volume: nil, defined: {})
      base =
        if tone.is_a?(Symbol)
          defined[tone] || PRESETS[tone] ||
            raise(ArgumentError, "unknown sound preset #{tone.inspect} — " \
                                 "built-in: #{PRESETS.keys.join(', ')}; " \
                                 "define your own with define_sound")
        else
          DEFAULTS.merge(frequency: tone)
        end

      {
        frequency: base[:frequency],
        duty:      duty   || base[:duty],
        decay:     decay  || base[:decay],
        volume:    volume || base[:volume],
      }
    end

    # Built-in noise presets — the percussion voice, as plain intent. A game says
    # `noise :explosion` and gets a rumble; the numbers are the framework's job.
    # +pitch+ is how high the hiss sits (:low rumble … :high hiss), +decay+ how
    # fast it fades, +metallic+ a tighter, more tonal rattle (for a snare/hat).
    NOISE_PRESETS = {
      hit:       { pitch: :mid,  decay: :fast,   volume: 12, metallic: false },
      kick:      { pitch: :low,  decay: :medium, volume: 15, metallic: false },
      snare:     { pitch: :mid,  decay: :fast,   volume: 13, metallic: true },
      hat:       { pitch: :high, decay: :fast,   volume: 8,  metallic: true },
      explosion: { pitch: :low,  decay: :slow,   volume: 15, metallic: false },
      zap:       { pitch: :high, decay: :medium, volume: 12, metallic: false },
    }.freeze

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

    # Built-in wave shapes, each a plain 0..15 sample table. A game says
    # `wave :triangle, :C4` and gets that timbre; the samples are the framework's job.
    def self.wavetable(shape)
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
        raise ArgumentError, "unknown wave shape #{shape.inspect} — built-in: :sine, :triangle, :sawtooth, :square"
      end
    end

    # The console-specific half: encode musical values into sound-register writes.
    # Each method returns a list of [register_address, 16-bit value] pairs in the
    # order they must be written; a backend just stores each one.
    module Registers
      include RubyGBA::Constants
      module_function

      # Wave shape → the 2-bit duty field the hardware wants.
      DUTY_CYCLES = {
        eighth: 0, quarter: 1, half: 2, square: 2, three_quarter: 3
      }.freeze

      # Fade speed → the envelope step the hardware counts down by.
      DECAY_PRESETS = { fast: 1, medium: 3, slow: 5, none: 0 }.freeze

      # Noise pitch → the noise generator's shift-clock exponent. The hiss's
      # frequency divides down as the exponent grows, so a bigger number is a
      # lower, rumblier noise and a smaller one a higher hiss.
      NOISE_SHIFTS = { high: 2, mid: 5, low: 8 }.freeze

      # The console tunes a channel by a period value, not a frequency:
      # freq_hz = 131072 / (2048 - value). Invert that and keep it in range.
      def frequency_value(freq_hz)
        (2048 - (131_072.0 / freq_hz)).round.clamp(0, 2047)
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
      def enable
        [
          [REG_SOUNDCNT_X, 0x0080],
          [REG_SOUNDCNT_L, 0xFF77],
          [REG_SOUNDCNT_H, 0x0002],
        ]
      end

      # A one-off sound effect on channel 2 (the SFX channel): duty + volume +
      # fade, then frequency with the trigger bit that restarts the note.
      def channel2(frequency:, duty:, decay:, volume:)
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

      # Silence the music — both square-wave voices, so a layered tune stops
      # cleanly (and any note left ringing on channel 2 stops too).
      def stop_music
        [
          [REG_SOUND1CNT_H, 0x0000], [REG_SOUND1CNT_X, 0x8000],
          [REG_SOUND2CNT_L, 0x0000], [REG_SOUND2CNT_H, 0x8000],
        ]
      end

      # A percussion / explosion hit on channel 4 (the noise voice). Channel 4
      # makes pseudo-random noise rather than a pitched tone: a control word sets
      # the starting volume and how fast it fades (the envelope, same layout as the
      # square channels), and a trigger word sets how high the hiss sits (the shift
      # clock), whether it's the tighter 7-bit "metallic" noise or the full 15-bit
      # hiss, and the restart bit. The envelope fades it to silence, so no note
      # length is needed.
      def channel4(pitch:, decay:, volume:, metallic:)
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
      def wave_play(samples, frequency:, volume:)
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
        (2048 - (65_536.0 / freq_hz)).round.clamp(0, 2047)
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
