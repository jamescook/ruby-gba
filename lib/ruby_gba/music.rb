# frozen_string_literal: true

module RubyGBA
  # Music sequencing. A song is written at build time with a note/rest DSL and a
  # tempo; the resolved score (frame/frequency pairs) is handed to every backend,
  # which replays the same tune.
  #
  # A song can be a single line of notes, or several parts played together — a
  # melody over a bass line. Write notes straight in the song for one part, or
  # group them into `voice` blocks to layer parts:
  #
  # @example One part
  #   song :gameplay do
  #     tempo 140
  #     note :C4, :eighth
  #     note :E4, :eighth
  #     note :G4, :quarter
  #     rest :quarter
  #   end
  #
  # @example Two parts (a melody over a bass)
  #   song :duet do
  #     tempo 120
  #     voice :melody do
  #       note :G4, :quarter; note :A4, :quarter
  #     end
  #     voice :bass do
  #       note :G2, :half
  #     end
  #   end
  #
  #   # In a scene or game loop:
  #   play_song :gameplay
  module Music
    # Standard tuning note frequencies (A4 = 440 Hz). Covers C2 through C6 — a
    # bass line up to a high melody, the useful range for the square-wave voices.
    NOTE_FREQUENCIES = {
      C2: 65,  Cs2: 69,  D2: 73,  Ds2: 78,  E2: 82,  F2: 87,
      Fs2: 92, G2: 98,   Gs2: 104, A2: 110, As2: 117, B2: 123,

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

    # The most parts a song can sound at once. The console has two square-wave
    # voices free for a tune (a third opens up once the wave channel lands). This
    # is a count of *parts*, not hardware channels — the writer never picks one.
    MAX_VOICES = 2

    # One part of a song: a single line of notes and rests, with its own tone
    # (duty) and loudness (volume). The clock (tempo) lives on the song and is
    # shared, so every part advances together, note for note.
    #
    # Each event is [frame_offset, freq_hz] where freq_hz = 0 is a rest.
    class VoiceContext
      attr_reader :events

      def initialize(song)
        @song = song       # the shared tempo is read back through this
        @duty = :half
        @volume = 12
        @events = []       # [[frame_offset, freq_hz], ...]
        @current_frame = 0
      end

      # Set this part's default duty cycle (wave shape), or read it.
      # Valid: :eighth, :quarter, :half, :square, :three_quarter
      def duty(d = nil)
        return @duty if d.nil?
        @duty = d
      end

      # Set this part's volume (0-15), or read it.
      def volume(v = nil)
        return @volume if v.nil?
        raise ArgumentError, "volume must be 0-15 (got #{v})" unless v.is_a?(Integer) && v.between?(0, 15)
        @volume = v
      end

      # Add a note.
      #
      # @param pitch [Symbol, Integer] note name (:C4, :Fs4) or frequency in Hz
      # @param duration [Symbol] :whole, :half, :quarter, :eighth, :sixteenth, etc.
      def note(pitch, duration)
        @events << [@current_frame, resolve_pitch(pitch)]
        @current_frame += duration_frames(duration)
      end

      # Add a rest (silence) of the given duration.
      def rest(duration)
        @events << [@current_frame, 0]
        @current_frame += duration_frames(duration)
      end

      # Total length of this part in frames.
      def total_frames
        @current_frame
      end

      # The part as plain data for the IR: its score, tone, and loudness.
      def to_voice
        { events: @events, duty: @duty, volume: @volume }
      end

      private

      def resolve_pitch(pitch)
        case pitch
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
      end

      def duration_frames(duration)
        multiplier = DURATION_MULTIPLIERS.fetch(duration) do
          raise ArgumentError, "unknown duration :#{duration}. " \
            "Available: #{DURATION_MULTIPLIERS.keys.join(', ')}"
        end
        quarter_frames = 60.0 / @song.current_tempo * 60
        (quarter_frames * multiplier).round
      end
    end

    # A song: a shared tempo plus one or more parts that play together. Write
    # notes directly for a one-part tune, or group them into `voice` blocks to
    # layer parts. Collected at build time into the resolved score every backend
    # replays.
    class SongContext
      def initialize
        @tempo = 120
        @voices = []          # [{ name:, voice: VoiceContext }], in play order
        @default_voice = nil  # the part made for notes written straight in the song
        @has_blocks = false   # whether any `voice` block was used
      end

      # Set the tempo in BPM, or read it. Shared by every part.
      def tempo(bpm = nil)
        return @tempo if bpm.nil?
        raise ArgumentError, "tempo must be positive (got #{bpm})" unless bpm.is_a?(Numeric) && bpm > 0
        @tempo = bpm
      end

      # The live tempo, read by each part as it works out note durations.
      def current_tempo
        @tempo
      end

      # Add a part, played alongside the others. Name it for readability; the
      # framework decides which channel it sounds on — you never name a channel.
      def voice(name = nil, &block)
        raise ArgumentError, mixed_message if @default_voice
        vc = VoiceContext.new(self)
        vc.instance_eval(&block)
        @voices << { name: name, voice: vc }
        @has_blocks = true
        ensure_voice_budget!
        vc
      end

      # Notes written straight in the song (no `voice` block) form its one part.
      def note(pitch, duration) = default_voice.note(pitch, duration)
      def rest(duration) = default_voice.rest(duration)
      def duty(value = nil) = default_voice.duty(value)
      def volume(value = nil) = default_voice.volume(value)

      # The parts as plain data for the IR, in play order.
      def voices
        raise ArgumentError, "song has no notes" if @voices.empty?
        @voices.map { |entry| entry[:voice].to_voice }
      end

      # The song loops at the length of its longest part, so the parts realign
      # each time around.
      def total_frames
        @voices.map { |entry| entry[:voice].total_frames }.max || 0
      end

      private

      def default_voice
        @default_voice ||= begin
          raise ArgumentError, mixed_message if @has_blocks
          vc = VoiceContext.new(self)
          @voices << { name: nil, voice: vc }
          vc
        end
      end

      def ensure_voice_budget!
        return if @voices.length <= MAX_VOICES
        raise ArgumentError, "a song can play at most #{MAX_VOICES} parts at once " \
          "(this one has #{@voices.length}). Layer a melody and a bass — the console runs out of voices."
      end

      def mixed_message
        "write either loose notes or `voice` blocks in a song, not both"
      end
    end
  end
end
