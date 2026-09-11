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
  # @example A part that plays a recorded instrument instead of the square wave
  #   instrument :piano, from: "piano_c4.wav", note: :C4
  #   song :waltz do
  #     voice :melody, plays: :piano do
  #       note :E4, :quarter; note :G4, :quarter
  #     end
  #   end
  #
  #   # Anywhere — once, or every frame; it is the song playing now either way:
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

    # HOW MANY PARTS A SONG CAN HAVE, which is what the console really has for them. A plain
    # part plays a square wave, and the console has two square-wave voices for music. A part
    # that plays an instrument goes through the mixer instead, one of its voices each, so those
    # are held to the mixer's count and not to the square waves at all.
    #
    # NAMED FOR WHAT IT COUNTS: a part is a line of music, and a voice is a slot that makes a
    # sound. One word for one meaning, so the number that limits tunes cannot be read as the
    # number that limits sounds.
    MAX_SQUARE_PARTS = 2
    MAX_PARTS = MAX_SQUARE_PARTS + Sound::MIXER_VOICES

    # One part of a song: a single line of notes and rests, with its own tone
    # (duty) and loudness (volume). The clock (tempo) lives on the song and is
    # shared, so every part advances together, note for note.
    #
    # A part plays the square-wave voice unless it names an instrument to play
    # instead (`plays:`) — then each note is that recording, at the note's pitch.
    #
    # Each event is [frame_offset, freq_hz] where freq_hz = 0 is a rest.
    class VoiceContext
      attr_reader :events, :instrument

      def initialize(song, plays: nil)
        @song = song       # the shared tempo is read back through this
        @instrument = instrument_name(plays)
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

      # The part as plain data for the IR: its score, tone, and loudness — and the
      # instrument it plays, when it plays one.
      def to_voice
        part = { events: @events, duty: @duty, volume: @volume }
        part[:instrument] = @instrument if @instrument
        part
      end

      private

      # An instrument is named by the Symbol it was declared with, or by the handle
      # `instrument` gave back — either one reads as the same name.
      def instrument_name(plays)
        case plays
        when nil, Symbol then plays
        else
          return plays.name if plays.respond_to?(:name)

          raise ArgumentError, "plays: names an instrument, like :piano. You gave #{plays.inspect}."
        end
      end

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
      # `plays: :piano` makes the part play an instrument instead of the square
      # wave: each note is the instrument's recording at that note's pitch.
      def voice(name = nil, plays: nil, &block)
        raise ArgumentError, mixed_message if @default_voice
        vc = VoiceContext.new(self, plays: plays)
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
        recorded = @voices.count { |entry| entry[:voice].instrument }
        squares = @voices.length - recorded
        if squares > MAX_SQUARE_PARTS
          raise ArgumentError,
                "A song can have at most #{MAX_SQUARE_PARTS} square-wave parts, and this song has " \
                "#{squares}. The console has #{MAX_SQUARE_PARTS} square-wave voices for music. To add " \
                "more parts, give each extra part an instrument: `voice :strings, plays: :strings do ... end`."
        end
        return if recorded <= Sound::MIXER_VOICES

        raise ArgumentError,
              "A song can have at most #{Sound::MIXER_VOICES} parts that play an instrument, and this " \
              "song has #{recorded}. The mixer plays at most #{Sound::MIXER_VOICES} recordings at once. " \
              "To fix this, use fewer parts that play an instrument."
      end

      def mixed_message
        "write either loose notes or `voice` blocks in a song, not both"
      end
    end
  end
end
