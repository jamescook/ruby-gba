# frozen_string_literal: true

module RubyGBA
  # Music sequencing for the GBA. Songs are defined at build time using
  # a note/rest DSL, then emitted as unrolled frame-by-frame conditionals
  # that trigger channel 1 (square wave with sweep).
  #
  # Channel 1 is used for music so it doesn't conflict with channel 2
  # beep/SFX sounds.
  #
  # @example
  #   song :gameplay do
  #     tempo 140
  #     note :C4, :eighth
  #     note :E4, :eighth
  #     note :G4, :quarter
  #     rest :quarter
  #   end
  #
  #   # In a scene or game loop:
  #   play_song :gameplay
  module Music
    # Standard tuning note frequencies (A4 = 440 Hz).
    # Covers C3 through C6 — the useful range for GBA square waves.
    NOTE_FREQUENCIES = {
      C3: 131, Cs3: 139, D3: 147, Ds3: 156, E3: 165, F3: 175,
      Fs3: 185, G3: 196, Gs3: 208, A3: 220, As3: 233, B3: 247,

      C4: 262, Cs4: 277, D4: 294, Ds4: 311, E4: 330, F4: 349,
      Fs4: 370, G4: 392, Gs4: 415, A4: 440, As4: 466, B4: 494,

      C5: 523, Cs5: 554, D5: 587, Ds5: 622, E5: 659, F5: 698,
      Fs5: 740, G5: 784, Gs5: 831, A5: 880, As5: 932, B5: 988,

      C6: 1047,
    }.freeze

    # Duration multipliers relative to a quarter note.
    DURATION_MULTIPLIERS = {
      whole:           4.0,
      half:            2.0,
      dotted_quarter:  1.5,
      quarter:         1.0,
      eighth:          0.5,
      sixteenth:       0.25,
      dotted_eighth:   0.75,
    }.freeze

    # Collects notes and rests from a song definition block.
    # Each entry is [frame_offset, freq_hz] where freq_hz=0 means rest.
    class SongContext
      attr_reader :events

      def initialize
        @tempo = 120
        @duty = :half
        @volume = 12
        @events = []       # [[frame_offset, freq_hz], ...]
        @current_frame = 0
      end

      # Set the tempo in BPM, or read it.
      def tempo(bpm = nil)
        return @tempo if bpm.nil?
        raise ArgumentError, "tempo must be positive (got #{bpm})" unless bpm.is_a?(Numeric) && bpm > 0
        @tempo = bpm
      end

      # Set the default duty cycle for all notes in this song, or read it.
      # Valid: :eighth, :quarter, :half, :square, :three_quarter
      def duty(d = nil)
        return @duty if d.nil?
        @duty = d
      end

      # Set the default volume (0-15) for all notes, or read it.
      def volume(v = nil)
        return @volume if v.nil?
        raise ArgumentError, "volume must be 0-15 (got #{v})" unless v.is_a?(Integer) && v.between?(0, 15)
        @volume = v
      end

      # Add a note.
      #
      # @param pitch [Symbol, Integer] note name (:C4, :Fs4) or frequency in Hz
      # @param duration [Symbol] :whole, :half, :quarter, :eighth, :sixteenth, etc.
      #
      # @example Named note
      #   note :C4, :quarter
      #
      # @example Frequency (full control)
      #   note 440, :eighth
      def note(pitch, duration)
        freq = case pitch
               when Symbol
                 NOTE_FREQUENCIES.fetch(pitch) do
                   raise ArgumentError, "unknown note :#{pitch}. " \
                     "Available: #{NOTE_FREQUENCIES.keys.first(12).join(', ')}, ..."
                 end
               when Integer
                 raise ArgumentError, "frequency must be positive (got #{pitch})" unless pitch > 0
                 pitch
               else
                 raise ArgumentError, "note pitch must be a Symbol (:C4) or Integer (440), got #{pitch.class}"
               end
        frames = duration_frames(duration)
        @events << [@current_frame, freq]
        @current_frame += frames
      end

      # Add a rest (silence).
      # @param duration [Symbol] duration of the silence
      def rest(duration)
        frames = duration_frames(duration)
        @events << [@current_frame, 0]
        @current_frame += frames
      end

      # Total length of the song in frames.
      def total_frames
        @current_frame
      end

      private

      def duration_frames(duration)
        multiplier = DURATION_MULTIPLIERS.fetch(duration) do
          raise ArgumentError, "unknown duration :#{duration}. " \
            "Available: #{DURATION_MULTIPLIERS.keys.join(', ')}"
        end
        quarter_frames = 60.0 / @tempo * 60
        (quarter_frames * multiplier).round
      end
    end
  end
end
