# frozen_string_literal: true

module VBlank
  module Audio
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

      # EVERY NAME `plays:` READS AS ONE OF THE CONSOLE'S OWN VOICES rather than as an instrument
      # (see .resolve_plays). A recording can never be given one of these: `plays: :sine` would
      # pick the wave voice and not the recording, and the recording would sit in the cartridge
      # unplayed, with its envelope and its hold point along with it and nothing to say so.
      CONSOLE_VOICE_NAMES = [:noise, :wave, :square, *WAVE_SHAPES].freeze

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

      # Whether what a part PLAYS (.resolve_plays, or a Part's own fields) is the square wave: no
      # recording, no waveform and no hiss.
      def self.plays_square?(plays) = kind_played(plays) == :square

      # WHICH KIND OF VOICE A PART PLAYS ON, from what it PLAYS (.resolve_plays, or a Part's own
      # fields): :recorded, :wave, :noise, or :square for none of those. IR::Tunes.part_kind reads a
      # finished part the same way.
      def self.kind_played(plays)
        return :recorded if plays[:instrument]
        return :wave if plays[:wave]
        return :noise if plays[:noise]

        :square
      end

      # Whether a part's own slide, or one of its events' (the seventh place), moves the pitch
      # (PitchSlide#moves?).
      def self.slides_said?(slide, events) = PitchSlide.moves?(slide) || events.any? { |event| PitchSlide.moves?(event[Part::SLIDE_SLOT]) }

      # AN EVENT, OR A LOG ENTRY, IS READ BY POSITION, and what a note did not say is left off the
      # end rather than written as nil — so the shape a note can have costs nothing to a note that
      # has none, and a song written before it existed is what it always was. A nil before
      # something said stays, to keep its place.
      def self.without_trailing_nils(said)
        said = said.dup
        said.pop while !said.empty? && said.last.nil?
        said
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
      # +envelope+ shapes how each of this part's notes starts and ends — read only by a part that
      # plays a recording, since the console's own voices shape their own notes.
      # +fade+ is how they do that: how each note of a part on a square or the noise voice fades
      # out or swells in by itself (a NoteFade), unless the note says its own. Nil leaves it to the
      # voice — a drum rings out as +decay+ says, a square note holds (see IR::Tunes.said_fade).
      #
      # +slide+ is how each note of the song's first square part slides its pitch by itself (a
      # PitchSlide), unless the note says its own; nil slides nothing. +vibrato+ is how each note
      # of a square or wave part wobbles its pitch (a Vibrato), unless the note says its own. +pan+
      # is the speaker each note plays from (a Pan), unless the note says its own; nil is both.
      # +duties+ is a square part's shapes when it gave a list of them to step through (a Duty, whose
      # first is +duty+), and nil when it gave one.
      #
      # AN EVENT CAN SAY ITS OWN in a sixth place, after the envelope, its own slide in a seventh,
      # its own wobble in an eighth, its own side in a ninth and its own shape in a tenth: [frame,
      # frequency, instrument, volume, envelope, fade, slide, vibrato, pan, duty].
      Part = Data.define(:events, :duty, :volume, :instrument, :wave, :noise, :decay, :metallic,
                         :name, :envelope, :fade, :slide, :vibrato, :pan, :duties)

      class Part
        # WHAT A PART CARRIES WHEN IT SAYS NOTHING — every optional field's answer, in one place,
        # so the declaration and anything asking whether a part actually SAID so (the IR dumper,
        # writing a part back as the call that builds it) cannot drift apart. +events+ is not
        # here: a part with no notes in it is a part nobody wrote.
        DEFAULTS = { duty: :half, volume: 12, instrument: nil, wave: nil,
                     noise: false, decay: :fast, metallic: false, name: nil, envelope: nil,
                     fade: nil, slide: nil, vibrato: nil, pan: nil, duties: nil }.freeze

        # WHAT A PART'S VOICE CANNOT DO IS REFUSED HERE, where both ways a song reaches the IR meet:
        # a fade on a voice that cannot count one (NoteFade.refuse_without_counting!), a slide off
        # the square voices (PitchSlide.refuse_off_square!), a wobble on a voice with no pitch to
        # move (Vibrato.refuse_without_pitch!), a side on a recording (Pan.refuse_recorded!), a shape
        # off the square voices (Duty.refuse_off_square!), and a note that both slides and wobbles.
        # +who+ names
        # the part, as the start of a sentence — a Score says its own, which is its place.
        #
        # +shift+ moves every note's pitch higher or lower (a PitchShift), worked into the events
        # here, so the part carries the pitches it plays and nothing that says how they were moved.
        def initialize(events:, who: nil, shift: PitchShift::NONE, **said)
          fields = DEFAULTS.merge(said)
          label = who || (fields[:name] ? "The part #{fields[:name].inspect}" : "A part")
          super(events: shift.applied(events, kind: Music.kind_played(fields), who: label), **fields)
          refuse_unplayable_shapes!(label)
        end

        # Where an event keeps what a note says of its own, after its frame, pitch, instrument,
        # volume and envelope.
        FADE_SLOT = 5
        SLIDE_SLOT = 6
        VIBRATO_SLOT = 7
        PAN_SLOT = 8
        DUTY_SLOT = 9

        # Does this part, or a note of it, say a slide?
        def slides? = Music.slides_said?(slide, events)

        private

        def refuse_unplayable_shapes!(who)
          if (wave || instrument) && (fade || events.any? { |event| event[FADE_SLOT] })
            NoteFade.refuse_without_counting!(who, wave: wave)
          end
          if slides? && !Music.plays_square?(wave: wave, instrument: instrument, noise: noise)
            PitchSlide.refuse_off_square!(who, wave: wave, noise: noise)
          end
          Vibrato.refuse_without_pitch!(who, noise: noise) if (noise || instrument) && wobbles?
          Pan.refuse_recorded!(who) if instrument && (pan || events.any? { |event| event[PAN_SLOT] })
          square = Music.plays_square?(wave: wave, instrument: instrument, noise: noise)
          Duty.refuse_off_square!(who, by_part: true) if !square && duties
          Duty.refuse_off_square!(who, by_part: false) if !square && events.any? { |event| event[DUTY_SLOT] }
          both = events.find do |event|
            PitchSlide.moves?(event[SLIDE_SLOT] || slide) && Vibrato.moves?(event[VIBRATO_SLOT] || vibrato)
          end
          Vibrato.refuse_with_slide!(who, frame: both.first) if both
        end

        def wobbles? = Vibrato.moves?(vibrato) || events.any? { |event| Vibrato.moves?(event[VIBRATO_SLOT]) }

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

        def initialize(song, plays: nil, name: nil, envelope: nil)
          @song = song       # the shared tempo is read back through this
          @name = name       # what the song calls this part, for a message about it
          @plays = Music.resolve_plays(plays)
          @envelope = Envelope.of(envelope, "the part #{(name || plays).inspect}")
          @duty = :half
          @volume = 12
          @decay = :fast     # a drum hit, for a part on the noise voice
          @metallic = false  # ...and whether it rattles (a snare, a hat) or thuds (a kick)
          @fade = nil        # how every note fades or swells, when the part says (a NoteFade)
          @slide = nil       # how every note slides its pitch, when the part says (a PitchSlide)
          @vibrato = nil     # how every note wobbles its pitch, when the part says (a Vibrato)
          @pan = nil         # the speaker every note plays from, when the part says (a Pan)
          @duties = nil      # the shapes every note steps through, when the part gives a list (a Duty)
          @transpose = nil   # the semitones every note moves, when the part says (see PitchShift)
          @pitch_offset = nil # ...and the voice's pitch steps it moves after that
          @events = []       # [[frame_offset, freq_hz], ...]
          @current_frame = 0
        end

        # Set this part's default duty cycle (wave shape), or read it.
        # Valid: :eighth, :quarter, :half, :square, :three_quarter — or a list of two or four of
        # them, which each note steps through a frame at a time (see Duty).
        def duty(d = nil)
          return @duty if d.nil?

          @duty, @duties = Duty.of_part(d, where: "The part #{part_label.inspect}")
        end

        # HOW FAST EACH NOTE FADES OUT — :fast, :medium, :slow, or :none to hold, or the 64ths of
        # a second each step of loudness lasts (0 to 7). The same words `noise` and `beep` take.
        # A drum part fades :fast when it says nothing; a square part holds its notes until the
        # next, like an organ, unless it says how they fade.
        def decay(d = nil)
          return @decay if d.nil?

          @fade = NoteFade.said(decay: d, swell: nil, where: "The part #{part_label.inspect}")
          @decay = d
        end

        # ...or how fast each note SWELLS IN from its volume to full, the same speeds as #decay.
        # A note written at volume 0 that swells is one that breathes in from nothing.
        def swell(s)
          @fade = NoteFade.said(decay: nil, swell: s, where: "The part #{part_label.inspect}")
        end

        # HOW FAST EACH NOTE SLIDES ITS PITCH UP, or down — :fast, :medium or :slow, or the voice's
        # own numbers, { every: 1..7, shift: 1..7 } (see PitchSlide). Only the song's first square
        # part can: the first square voice is the one with the circuit.
        def slide_up(speed)
          @slide = PitchSlide.said(up: speed, down: nil, where: "The part #{part_label.inspect}")
        end

        def slide_down(speed)
          @slide = PitchSlide.said(up: nil, down: speed, where: "The part #{part_label.inspect}")
        end

        # HOW EACH NOTE WOBBLES ITS PITCH — `vibrato depth: :slight, speed: :medium, after: :eighth`,
        # or the numbers themselves (see Vibrato.said), or `vibrato :none`. The square parts and the
        # wave part can.
        def vibrato(said = nil, **wobble)
          @vibrato = Vibrato.said(said || wobble, where: "The part #{part_label.inspect}",
                                                  frames: ->(length) { duration_frames(length) })
        end

        # EVERY NOTE MOVED BY WHOLE SEMITONES, up or down: `transpose 12` plays the part an octave
        # higher than it is written. Any part can (see PitchShift).
        def transpose(semitones)
          @transpose = semitones
        end

        # ...or by the voice's own pitch steps, a part a little sharp or flat: `pitch_offset 2`. A
        # square part or the wave part can.
        def pitch_offset(steps)
          @pitch_offset = steps
        end

        # WHICH SPEAKER EACH NOTE PLAYS FROM — :left, :right, or :center for both, which is what a
        # part that says nothing does. The square parts, the wave part and the drums can.
        def pan(side)
          @pan = Pan.said(side, where: "The part #{part_label.inspect}")
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

          refuse_volume_out_of_range!(v)
          @volume = v
        end

        # Add a note.
        #
        # @param pitch [Symbol, Integer] note name (:C4, :Fs4) or frequency in Hz
        # @param duration [Symbol] :whole, :half, :quarter, :eighth, :sixteenth, etc.
        # An +envelope+ here shapes this one note instead of the part's — a note plucked where the
        # rest are bowed.
        # A +volume+ here (0-15) is this note's loudness instead of the part's, and +decay+ or
        # +swell+ how it fades out or swells in instead of how the part's notes do (see #decay),
        # +slide_up+ or +slide_down+ how it slides its pitch (see #slide_up), +vibrato+ how it
        # wobbles (see #vibrato), +pan+ the speaker it plays from (see #pan), and +duty+ its shape,
        # or the shapes it steps through (see #duty). A note that says nothing leaves the later slots
        # off its event (Music.without_trailing_nils).
        def note(pitch, duration, envelope: nil, volume: nil, decay: nil, swell: nil, slide_up: nil, slide_down: nil,
                 vibrato: nil, pan: nil, duty: nil)
          where = "a note of the part #{part_label.inspect}"
          shape = Envelope.of(envelope, where)
          fade = NoteFade.said(decay: decay, swell: swell, where: where.capitalize)
          slide = PitchSlide.said(up: slide_up, down: slide_down, where: where.capitalize)
          wobble = Vibrato.said(vibrato, where: where.capitalize, frames: ->(length) { duration_frames(length) })
          side = Pan.said(pan, where: where.capitalize)
          duties = Duty.said(duty, where: where.capitalize)
          refuse_volume_out_of_range!(volume) if volume
          @events << [@current_frame, resolve_pitch(pitch),
                      *Music.without_trailing_nils([nil, volume, shape, fade, slide, wobble, side, duties])]
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
          @song.mark_loop_at(@current_frame)
        end

        # Total length of this part in frames.
        def total_frames
          @current_frame
        end

        # The part as the resolved data the IR carries: its score, tone, and loudness — and the
        # voice it plays on, and its name, when it has one.
        #
        # A drum part's `decay` is its +decay+, as it always was; only a swell is a fade of its own
        # there. Every other part's `decay` is its +fade+.
        def to_voice
          Part.new(events: @events, duty: @duty, volume: @volume, decay: @decay, metallic: @metallic, name: @name,
                   envelope: @envelope, fade: NoteFade.for_part(@fade, drum: @plays[:noise]), slide: @slide,
                   vibrato: @vibrato, pan: @pan, duties: @duties,
                   shift: PitchShift.said(transpose: @transpose, pitch_offset: @pitch_offset,
                                          where: "The part #{part_label.inspect}"),
                   **@plays)
        end

        private

        def part_label = @name || @plays[:instrument]

        def refuse_volume_out_of_range!(v)
          return if v.is_a?(Integer) && v.between?(0, 15)

          raise ArgumentError, "The part #{part_label.inspect} says a volume of #{v.inspect}. A volume is a whole " \
                               "number from 0 to 15. To fix this, give a volume in that range."
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
        def voice(name = nil, plays: nil, envelope: nil, &block)
          raise ArgumentError, loose_notes_and_voices_message if @default_voice
          vc = VoiceContext.new(self, plays: plays, name: name, envelope: envelope)
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
        def mark_loop_at(frame)
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
            raise ArgumentError, loose_notes_and_voices_message if @has_blocks
            vc = VoiceContext.new(self)
            @voices << { name: nil, voice: vc }
            vc
          end
        end

        def loose_notes_and_voices_message
          "write either loose notes or `voice` blocks in a song, not both"
        end
      end
    end
  end
end
