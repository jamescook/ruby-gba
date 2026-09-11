# frozen_string_literal: true

module RubyGBA
  # A PIECE OF MUSIC AS DATA — for a game whose music already exists as numbers rather than as
  # something to write out by hand: decoded out of another game's cartridge, read from a file,
  # made up by a program. A `song do ... end` block is for writing a tune; a Score is for handing
  # one over. `songs :music, [score, ...]` takes a list of them and plays them by number.
  #
  #   note = RubyGBA::Score::Note
  #   melody = RubyGBA::Score::Part.new(plays: :flute, notes: [
  #     note.new(at: 0,  key: 72, length: 22),   # key 72 is the C above middle C
  #     note.new(at: 24, key: 76, length: 22),
  #   ])
  #   RubyGBA::Score.new(parts: [melody], tempo: 150)
  #
  # TIME IS COUNTED IN TICKS, the way sequenced music is stored everywhere: a beat is
  # +ticks_per_beat+ of them, and the tempo is how many beats a minute. The framework turns
  # ticks into frames once, when the game is built — so a decoder hands over what its format
  # says and never does the sum. The tempo can change as the song goes:
  # `tempo: [[0, 120], [960, 140]]` is 120 from the start and 140 from tick 960.
  #
  # A PART is one line of music: a note at a time, each lasting until the next one starts or
  # its own +length+ runs out. It plays the square wave, or the recording its +plays:+ names.
  #
  # A NOTE has a +key+ — a MIDI note number (60 is middle C) or a note name like :C4 — or no
  # key at all, which is a rest. It can also name its own +instrument+ and +volume+, for music
  # that changes instrument or loudness from one note to the next. What a part cannot do is
  # change from a square wave to a recording halfway through: it plays one or the other.
  Score = Data.define(:parts, :tempo, :ticks_per_beat, :length)

  class Score
    # FRAMES A SECOND, the rate the music is played at — the same round figure a song block's
    # note lengths are worked out from, so the two agree about how long a beat is.
    FRAME_RATE = 60

    # +length+ is where the song comes round again, in ticks. Left out, it is where the last
    # note ends — and a note with no length of its own counts as a beat long for that, since
    # it lasts until the next note and the last one has none after it.
    def initialize(parts:, tempo: 120, ticks_per_beat: 24, length: nil)
      super
    end

    # The score as the plain data every backend replays: each part's events as [frame,
    # frequency in Hz, instrument, volume] — a frequency of 0 a rest, and a nil instrument or
    # volume meaning the part's own — and the song's length in frames.
    def to_song
      Checks.score!(self)
      frames = Timing.new(self)
      total = [frames.at(length || last_tick), 1].max
      { voices: parts.map { |part| part.to_voice(frames, total) }, total_frames: total }
    end

    private def last_tick
      parts.flat_map(&:notes).map { |note| note.at + (note.length || ticks_per_beat) }.max || 0
    end

    Part = Data.define(:notes, :plays, :volume, :duty)

    class Part
      def initialize(notes:, plays: nil, volume: 12, duty: :half)
        super
      end

      # The instrument this part plays, by name — given as its Symbol, or as the handle
      # `instrument` gave back — or nil for the square wave.
      def instrument
        plays.respond_to?(:name) && !plays.is_a?(Symbol) ? plays.name : plays
      end

      def to_voice(frames, total)
        voice = { events: Events.of(self, frames, total), duty: duty, volume: volume }
        voice[:instrument] = instrument if instrument
        voice
      end
    end

    Note = Data.define(:at, :key, :length, :instrument, :volume)

    class Note
      def initialize(at:, key: nil, length: nil, instrument: nil, volume: nil)
        super
      end

      # How high the note is, in Hz — 0 for a rest. A MIDI note number is tuned the usual
      # way, from A above middle C (number 69) at 440 Hz.
      def frequency
        case key
        when nil then 0
        when Symbol then Music::NOTE_FREQUENCIES.fetch(key)
        else 440.0 * (2**((key - 69) / 12.0))
        end
      end

      # The instrument this note names for itself, by name, or nil to play the part's own.
      def instrument_name
        instrument.respond_to?(:name) && !instrument.is_a?(Symbol) ? instrument.name : instrument
      end
    end

    # TICKS INTO FRAMES, from the tempo map. Each note's frame is worked out from the start of
    # the song with exact fractions and rounded once, so rounding never builds up over a long
    # song the way adding up rounded note lengths would.
    class Timing
      def initialize(score)
        @per_beat = score.ticks_per_beat
        @changes = score.tempo.is_a?(Array) ? score.tempo.sort_by(&:first) : [[0, score.tempo]]
      end

      def at(tick)
        seconds = 0r
        from, bpm = @changes.first
        @changes.drop(1).each do |change_at, next_bpm|
          break if change_at > tick

          seconds += Rational(change_at - from) * 60 / (@per_beat * bpm.to_r)
          from = change_at
          bpm = next_bpm
        end
        seconds += Rational(tick - from) * 60 / (@per_beat * bpm.to_r)
        (seconds * FRAME_RATE).round
      end
    end

    # A PART'S EVENTS, as the player walks them: one event on a frame, in order. A note with a
    # length ends in a rest where the length runs out, unless the next note has already begun.
    # Two events that round onto one frame keep the later — the player takes one event a frame,
    # and the earlier would last no time at all — and nothing is kept past the song's end.
    module Events
      module_function

      def of(part, frames, total)
        notes = part.notes.sort_by(&:at)
        events = notes.each_with_index.flat_map do |note, n|
          on = [frames.at(note.at), note.frequency, note.instrument_name, note.volume]
          next [on] unless note.length

          ends = note.at + note.length
          following = notes[n + 1]
          following && following.at <= ends ? [on] : [on, [frames.at(ends), 0, nil, nil]]
        end
        events.each_with_object({}) { |event, by_frame| by_frame[event.first] = event }
              .values.select { |event| event.first < total }.sort_by(&:first)
      end
    end

    # WHAT A SCORE HAS TO BE, said plainly and early — a game hands these over from its own
    # decoder, and a mistake in one names the note it is in, rather than coming out as a wrong
    # sound or a crash somewhere deep in the build. What a SONG has to be — how many parts, how
    # low a square-wave note — is the same for a Score and a song block, so it is checked on the
    # finished program instead (IR::Guardrails).
    module Checks
      module_function

      def score!(score)
        if !score.parts.is_a?(Array) || score.parts.empty?
          raise ArgumentError, "A Score needs at least one part. Give them in `parts:`."
        end
        unless score.ticks_per_beat.is_a?(Integer) && score.ticks_per_beat.positive?
          raise ArgumentError, "ticks_per_beat: must be a whole number more than 0. " \
                               "You gave #{score.ticks_per_beat.inspect}."
        end
        tempo!(score.tempo)
        score.parts.each_with_index { |part, number| part!(part, number) }
      end

      def tempo!(tempo)
        changes = tempo.is_a?(Array) ? tempo : [[0, tempo]]
        unless changes.map(&:first).min&.zero?
          raise ArgumentError, "A tempo map must start at tick 0. Give `tempo: [[0, bpm], ...]`."
        end
        changes.each do |at, bpm|
          next if bpm.is_a?(Numeric) && bpm.positive?

          raise ArgumentError, "A tempo is beats a minute, more than 0. The tempo at tick #{at} " \
                               "is #{bpm.inspect}."
        end
      end

      def part!(part, number)
        raise ArgumentError, "Part #{number} is not a Score::Part." unless part.is_a?(Part)
        raise ArgumentError, "Part #{number} needs its notes in `notes:`." unless part.notes.is_a?(Array)

        volume!(part.volume, "Part #{number}")

        part.notes.each_with_index do |note, index|
          note!(note, "Note #{index} of part #{number}")
          next unless note.instrument && !part.plays

          raise ArgumentError, "Note #{index} of part #{number} plays #{note.instrument_name.inspect}, " \
                               "but part #{number} plays the square wave. Give the part an instrument " \
                               "with `plays:`. Then a note can change it."
        end
      end

      def note!(note, where)
        raise ArgumentError, "#{where} is not a Score::Note." unless note.is_a?(Note)
        unless note.at.is_a?(Integer) && note.at >= 0
          raise ArgumentError, "#{where} starts at tick #{note.at.inspect}. A tick is a whole number, 0 or more."
        end
        unless note.length.nil? || (note.length.is_a?(Integer) && note.length.positive?)
          raise ArgumentError, "#{where} is #{note.length.inspect} ticks long. A length is a whole number " \
                               "more than 0, or nothing for a note that lasts until the next one."
        end
        key!(note.key, where)
        volume!(note.volume, where) if note.volume
      end

      # A loudness is 0 (silent) to 15 (the loudest), the same scale a song block's `volume` is.
      def volume!(volume, where)
        return if volume.is_a?(Integer) && volume.between?(0, 15)

        raise ArgumentError, "#{where} has the volume #{volume.inspect}. A volume is 0 to 15."
      end

      def key!(key, where)
        case key
        when nil then nil
        when Symbol
          return if Music::NOTE_FREQUENCIES.key?(key)

          raise ArgumentError, "#{where} has the key #{key.inspect}, which is not a note. " \
                               "Use a note like :C4, or a MIDI note number."
        when Integer
          raise ArgumentError, "#{where} has the key #{key}. A MIDI note number is 0 to 127." unless key.between?(0, 127)
        else
          raise ArgumentError, "#{where} has the key #{key.inspect}. Use a MIDI note number " \
                               "(60 is middle C) or a note like :C4."
        end
      end
    end
  end
end
