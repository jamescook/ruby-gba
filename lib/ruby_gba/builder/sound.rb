# frozen_string_literal: true

module RubyGBA
  class Builder
    # The sound-effect verbs: turn the audio hardware on, name reusable presets,
    # and fire one-off beeps on the square-wave channel. Music (songs) is its own
    # concern; these share only the @sound_enabled flag the builder sets up.
    #
    # A concern of {Builder}, mixed in so enable_sound/define_sound/beep are flat
    # DSL verbs.
    module Sound
      # Enable the GBA sound hardware. Call once at the top of your build block.
      # Without this, all beep calls are silent.
      def enable_sound
        raise ArgumentError, "enable_sound already called — only call it once" if @sound_enabled

        @sound_enabled = true
        record(Build.enable_sound)
      end

      # Define a named sound preset for use with beep.
      #
      # @param name [Symbol] preset name
      # @param frequency [Integer] tone frequency in Hz (64-2048 useful range)
      # @param duty [Symbol] wave shape (:eighth, :quarter, :half, :three_quarter)
      # @param decay [Symbol] fade speed (:fast, :medium, :slow, :none)
      # @param volume [Integer] initial volume (0-15)
      #
      # @example
      #   define_sound :paddle_hit, frequency: 880, duty: :quarter, decay: :fast
      #   define_sound :wall_bounce, frequency: 440
      def define_sound(name, frequency:, duty: :half, decay: :fast, volume: 15)
        record(Build.define_sound(name, frequency: frequency, duty: duty, decay: decay, volume: volume))
      end

      # Trigger a beep on sound channel 2 (square wave, no sweep).
      #
      # @param tone [Symbol, Integer] a preset name or frequency in Hz
      # @param duty [Symbol] wave shape (default: :half)
      # @param decay [Symbol] fade speed (default: :fast)
      # @param volume [Integer] initial volume 0-15 (default: 15)
      #
      # @example Preset
      #   beep :high
      #   beep :paddle_hit     # custom preset from define_sound
      #
      # @example Frequency
      #   beep 880
      #   beep 440, duty: :quarter, decay: :slow
      def beep(tone, duty: nil, decay: nil, volume: nil)
        raise ArgumentError, "call enable_sound before beep" unless @sound_enabled

        record(Build.beep(tone, duty: duty, decay: decay, volume: volume))
      end

      # Play a percussion or explosion hit on the noise voice (channel 4) — the
      # console's drum/crash sound, made from filtered randomness rather than a
      # pitched tone.
      #
      # @param preset [Symbol, nil] a built-in noise sound (:hit, :kick, :snare,
      #   :hat, :explosion, :zap); omit for a plain hit
      # @param pitch [Symbol] how high the hiss sits (:low, :mid, :high)
      # @param decay [Symbol] fade speed (:fast, :medium, :slow, :none)
      # @param volume [Integer] initial volume 0-15
      # @param metallic [Boolean] a tighter, more tonal rattle (snare/hat)
      #
      # @example
      #   noise :explosion
      #   noise :hat
      #   noise pitch: :low, decay: :slow, volume: 15
      def noise(preset = nil, pitch: nil, decay: nil, volume: nil, metallic: nil)
        raise ArgumentError, "call enable_sound before noise" unless @sound_enabled

        record(Build.noise(preset, pitch: pitch, decay: decay, volume: volume, metallic: metallic))
      end
    end
  end
end
