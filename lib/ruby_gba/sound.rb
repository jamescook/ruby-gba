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

      # Power on the sound hardware: master enable, both PSG channels routed to
      # both speakers at full volume, PSG output at 100%.
      def enable
        [
          [REG_SOUNDCNT_X, 0x0080],
          [REG_SOUNDCNT_L, 0x3377],
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

      # A single music note on channel 1 (the music channel). A frequency of 0 is
      # a rest — silence the channel. Music notes sustain (no fade) until the next
      # note replaces them.
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

      # Silence the music channel.
      def stop_music
        [[REG_SOUND1CNT_H, 0x0000], [REG_SOUND1CNT_X, 0x8000]]
      end
    end
  end
end
