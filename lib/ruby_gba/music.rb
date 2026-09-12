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
  # @example An introduction that plays once, then a melody that repeats
  #   song :title do
  #     note :C4, :whole   # the fanfare
  #     loop_from_here
  #     note :E4, :half; note :G4, :half
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

    # HOW MANY PARTS A SONG CAN HAVE. A plain part plays a square wave, and the console has two
    # square-wave voices for music — that half is the hardware. A part that plays an instrument
    # goes through the mixer instead, one of its voices each, and that half is the framework's:
    # recordings are summed in software, and Sound::MIXER_VOICES is how many it sums today, not
    # a number the console imposes. Both are checked on the finished program
    # (IR::Guardrails::Checks::SongTooManyParts), so a Score meets them the same as a block.
    #
    # NAMED FOR WHAT IT COUNTS: a part is a line of music, and a voice is a slot that makes a
    # sound. One word for one meaning, so the number that limits tunes cannot be read as the
    # number that limits sounds.
    MAX_SQUARE_PARTS = 2

    # THE OTHER TWO VOICES THE CONSOLE HAS, and a tune can now use both. The wave voice loops a
    # short waveform, so it makes rounder timbres than a square wave and reaches lower — it is a
    # pad, a bass, a bell. The noise voice makes a hiss rather than a pitched tone, which is the
    # drums. There is one of each, so one part apiece.
    #
    # WHAT THEY ARE WORTH is that they cost NO mixer voice. The console makes both sounds
    # itself, where a part that plays a recording keeps a voice of the mixer for the whole game.
    # So a busy song reaches for these two before it reaches for a ninth recording, and the
    # voices it does not spend stay free for the game's own sounds.
    MAX_WAVE_PARTS = 1
    MAX_NOISE_PARTS = 1

    # The timbres a wave part can have. `plays: :wave` is the middle one of them, which is the
    # one somebody asking for "the wave voice" without saying more means.
    WAVE_SHAPES = %i[sine triangle sawtooth].freeze
    DEFAULT_WAVE_SHAPE = :triangle

    # WHAT A PART PLAYS, as plain data, worked out in one place for both ways a song reaches the
    # IR — a `song` block and a `Score` handed over as data. Answers the fields a Part carries,
    # so a part's kind is read off it the same way everywhere (see IR::Tunes.part_kind). The
    # Hash it hands back is a slice of keyword arguments with one place to go — straight into
    # Part.playing — rather than a record that travels.
    #
    # A bare Symbol is an instrument's name unless it is one of the console's own voices, and
    # nothing here looks an instrument up: a name that is neither is caught later, by the
    # guardrail that names the song and the part (Checks::SongInstrumentUnknown).
    def self.resolve_plays(plays)
      case plays
      when nil then {}
      when :noise then { noise: true }
      when :wave then { wave: DEFAULT_WAVE_SHAPE }
      when *WAVE_SHAPES then { wave: plays }
      # A waveform of the part's own, rather than one of the names — the wave voice either way.
      when Array then { wave: Sound.wave_steps!(plays) }
      when :square then raise ArgumentError, SQUARE_PLAYS_MESSAGE
      when Symbol then { instrument: plays }
      else
        return { instrument: plays.name } if plays.respond_to?(:name)

        raise ArgumentError, "plays: names an instrument, like :piano. It can also name one of " \
                             "the console's own voices: :wave (or a shape, " \
                             "#{WAVE_SHAPES.map(&:inspect).join(', ')}) or :noise. For a waveform " \
                             "of your own, give #{Sound::WAVE_SAMPLES} steps of 0 to " \
                             "#{Sound::WAVE_STEP_MAX}. You gave #{plays.inspect}."
      end
    end

    # `plays: :square` is refused because it can be read two ways and the wrong reading is
    # silent: the reader means "this part plays a square wave", which is what a part does with
    # no `plays:` at all, and would get the WAVE voice shaped like a square instead — a
    # different voice, and one of the two this song may be short of.
    SQUARE_PLAYS_MESSAGE =
      "A part plays the square wave when it names no instrument. To do that, remove `plays:` " \
      "from this part. For the wave voice, which is rounder and goes lower, write " \
      "`plays: :wave`."

    # ONE PART OF A SONG, resolved — the thing a `song` node's `voices:` list is made of, and
    # what every backend and every check about a tune reads.
    #
    # It is the one description of a part, built at each of the two ways a song reaches the IR
    # (VoiceContext#to_voice for a block, Score::Part#to_voice for data) and read by name
    # everywhere after. Named fields rather than a Hash, because the fields a part can leave out
    # are most of them: a misspelt one raises here, where a missing Hash key read as nil and
    # came out layers away as a part playing the wrong voice.
    #
    # WHAT IT HOLDS. +events+ is the part's score, one [frame, frequency in Hz, instrument,
    # volume] each with a frequency of 0 for a rest; +duty+ is the square wave's shape and
    # +volume+ its loudness. Then, at most one of: +instrument+ (a recording the part plays at
    # each note's pitch), +wave+ (a timbre for the console's wave voice), +noise+ (the hiss).
    # Naming none of those is the square wave.
    #
    # THE DEFAULTS ARE HERE, not at the places that read them. +decay+ and +metallic+ say how a
    # hit fades and whether it rattles, and only a part on the noise voice is ever asked — so
    # every other part carries the answer a drum would have given and nobody looks. That is the
    # trade an optional field makes: one harmless value on every part, against a `|| :fast`
    # written at each reader and a key that might not be there.
    Part = Data.define(:events, :duty, :volume, :instrument, :wave, :noise, :decay, :metallic, :name)

    class Part
      # WHAT A PART CARRIES WHEN IT SAYS NOTHING — every optional field's answer, in one place,
      # so the declaration and anything asking whether a part actually SAID so (the IR dumper,
      # writing a part back as the call that builds it) cannot drift apart. +events+ is not
      # here: a part with no notes in it is a part nobody wrote.
      DEFAULTS = { duty: :half, volume: 12, instrument: nil, wave: nil,
                   noise: false, decay: :fast, metallic: false, name: nil }.freeze

      def initialize(events:, **said) = super(events: events, **DEFAULTS.merge(said))

      # A part built from what its author said it PLAYS — an instrument's name, a wave shape,
      # :noise, or nothing for the square wave. One reader for that word (Music.resolve_plays),
      # so the two ways a song reaches the IR cannot disagree about which voice a part is on.
      def self.playing(plays, **rest) = new(**rest, **Music.resolve_plays(plays))
    end

    # One part of a song as it is WRITTEN, in a `song` block: a single line of notes and rests,
    # with its own tone (duty) and loudness (volume). The clock (tempo) lives on the song and is
    # shared, so every part advances together, note for note.
    #
    # A part plays the square-wave voice unless it names an instrument to play
    # instead (`plays:`) — then each note is that recording, at the note's pitch.
    #
    # Each event is [frame_offset, freq_hz] where freq_hz = 0 is a rest.
    class VoiceContext
      attr_reader :events

      def initialize(song, plays: nil, name: nil)
        @song = song       # the shared tempo is read back through this
        @name = name       # what the song calls this part, for a message about it
        @plays = Music.resolve_plays(plays)
        @duty = :half
        @volume = 12
        @decay = :fast     # a drum hit, for a part on the noise voice
        @metallic = false  # ...and whether it rattles (a snare, a hat) or thuds (a kick)
        @events = []       # [[frame_offset, freq_hz], ...]
        @current_frame = 0
      end

      # Set this part's default duty cycle (wave shape), or read it.
      # Valid: :eighth, :quarter, :half, :square, :three_quarter
      def duty(d = nil)
        return @duty if d.nil?
        @duty = d
      end

      # HOW FAST A HIT FADES, for a part on the noise voice — :fast, :medium, :slow, or :none
      # to hold. Every other kind of part holds its note until the next one, so this is read
      # only there. The same words `noise` takes for a sound effect.
      def decay(d = nil)
        return @decay if d.nil?
        @decay = d
      end

      # ...and whether the hiss is the tighter, more tonal rattle (a snare, a hat) or the full
      # one (a kick, an explosion). Read only by a part on the noise voice, same as #decay.
      def metallic(m = nil)
        return @metallic if m.nil?
        @metallic = m
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

      # Mark where the song loops back to. What comes before this plays once, as an
      # introduction; what comes after it repeats for as long as the song plays.
      def loop_from_here
        @song.loop_from(@current_frame)
      end

      # Total length of this part in frames.
      def total_frames
        @current_frame
      end

      # The part as the resolved data the IR carries: its score, tone, and loudness — and the
      # voice it plays on, and its name, when it has one.
      def to_voice
        Part.new(events: @events, duty: @duty, volume: @volume, decay: @decay,
                 metallic: @metallic, name: @name, **@plays)
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
        @loop_marks = []      # the frame each `loop_from_here` was written at
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

      # Add a part, played alongside the others. Name it for readability; the framework decides
      # which channel it sounds on — you never name a channel.
      #
      # `plays:` says what the part SOUNDS LIKE, and there are three answers. An instrument's
      # name (`plays: :piano`) plays that recording at each note's pitch. `plays: :wave` — or a
      # shape, :sine, :triangle, :sawtooth — plays the console's wave voice, which is rounder
      # than a square wave and reaches an octave lower, so it is the pad and the bass.
      # `plays: :noise` plays the hiss, which is the drums: a low note is a kick and a high one
      # a hat, and the part says how fast a hit fades (`decay`) and whether it rattles
      # (`metallic`). Say nothing and the part plays the square wave, as it always did.
      #
      # The last two cost NO mixer voice — the console makes those sounds itself — so a busy
      # song reaches for them before it reaches for another recording.
      def voice(name = nil, plays: nil, &block)
        raise ArgumentError, mixed_message if @default_voice
        vc = VoiceContext.new(self, plays: plays, name: name)
        vc.instance_eval(&block)
        @voices << { name: name, voice: vc }
        @has_blocks = true
        vc
      end

      # Notes written straight in the song (no `voice` block) form its one part.
      def note(pitch, duration) = default_voice.note(pitch, duration)
      def rest(duration) = default_voice.rest(duration)
      def duty(value = nil) = default_voice.duty(value)
      def volume(value = nil) = default_voice.volume(value)
      def loop_from_here = default_voice.loop_from_here

      # A part marked the loop at +frame+ (see VoiceContext#loop_from_here).
      def loop_from(frame)
        @loop_marks << frame
      end

      # The frame the song loops back to, or nil to loop from its start. One part can mark it,
      # or every part — but when several do, they must mark the same moment, since the whole
      # song goes back there together.
      def loop_frame
        marks = @loop_marks.uniq
        return nil if marks.empty?

        if marks.size > 1
          at = marks.map { |frame| "#{(frame / Score::FRAME_RATE.to_f).round(2)} seconds" }.join(" and ")
          raise ArgumentError, "The parts of this song mark different places to loop from: at #{at}. " \
                               "The whole song loops from one place. Mark the same place in every part, " \
                               "or mark it in one part only."
        end
        return marks.first if marks.first < total_frames

        raise ArgumentError, "`loop_from_here` is at the end of the song, so no notes come after it. Put it " \
                             "before the notes that repeat."
      end

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

      def mixed_message
        "write either loose notes or `voice` blocks in a song, not both"
      end
    end
  end
end
