# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Native
        # WHAT A GAME'S SOUND LOG SAYS, as the C prints it and as a test reads it.
        #
        # The interpreter keeps a log of what it played (Reference#audio): sound switched on, a
        # beep and everything about it, a note, a voice set, the wave voice told to play or stop,
        # a hit on the noise voice, the music turned down, the music stopped. The C prints the
        # same thing a line at a time (runtime/rg_sound.c), and what it prints is numbers: which
        # beep, which song, which pitch. The rest of an entry — what a beep sounds like, a song's
        # name, the waveform a part plays — was settled when the game was built, so the C need
        # not carry it. Both sides number the game's beeps, songs, waves and hits here, the
        # lowering to write the numbers in and the run to read them back, which is what keeps the
        # two in step.
        class SoundLog
          def initialize(program)
            defined = program.walk.select { |node| node.kind == :define_sound }.to_h { |node| [node.name, node.effect] }
            @effects = program.walk.select { |node| node.kind == :beep }.map { |node| effect_of(node, defined) }.uniq
            @defined = defined
            @songs = program.walk.select { |node| node.kind == :song }.uniq(&:name)
            @waves = program.walk.select { |node| node.kind == :wave }.map { |node| wave_of(node) }.uniq
            @hits = program.walk.select { |node| node.kind == :noise }.map { |node| hit_of(node) }.uniq
            @pitches = [0, *@songs.flat_map { |song| song.voices.flat_map { |part| part.events.map { |event| event[1] } } }].uniq
            # A name declared twice is the last declaration's, as the interpreter gathers them.
            @recordings = program.walk.select { |node| node.kind == :sample }.group_by(&:name).values.map(&:last)
          end

          # Every recording the game declares (its `sample` node), in the order the C numbers
          # them, and one of them by name.
          attr_reader :recordings

          def recording(name) = @recordings.find { |sample| sample.name == name }
          def recording_number(name) = @recordings.index { |sample| sample.name == name }

          # The number the C carries for a note's pitch. A pitch is in Hz and need not be whole —
          # a song handed over as MIDI note numbers is tuned from 440, so most of its notes fall
          # between two whole numbers — so the C is given which of the songs' pitches it is, and
          # the log reads it back as the pitch itself. 0 is a rest.
          def pitch_number(pitch)
            @pitches.index(pitch) or raise LoweringError, "a note's pitch #{pitch.inspect} is not among the songs' pitches"
          end

          # Every song the game has, and every different beep it makes (an Audio::Sound::Effect
          # each), in the order the C numbers them.
          attr_reader :songs, :effects

          # Every different thing the game tells the wave voice to play with `wave` — its
          # waveform, pitch and loudness, as the interpreter logs one — and every different hit
          # it makes with `noise`, in the order the C numbers them.
          attr_reader :waves, :hits

          # The number the C prints for this beep: which of the game's sounds it makes.
          def beep_number(node) = @effects.index(effect_of(node, @defined))

          def song_number(name) = @songs.index { |song| song.name == name }

          # ...and for this `wave`, and this `noise`.
          def wave_number(node) = @waves.index(wave_of(node))
          def noise_number(node) = @hits.index(hit_of(node))

          # One printed line ("sound" and what follows) read as the interpreter's log entry.
          def entry_from(line)
            kind, *numbers = line.delete_prefix("sound ").split(" ")
            numbers = numbers.map { |number| Integer(number) }
            case kind
            when "enabled" then [:enabled]
            when "beep" then [:beep, @effects.fetch(numbers[0])]
            when "note" then [:note, @songs.fetch(numbers[0]).name, @pitches.fetch(numbers[1])]
            when "voice" then [:voice, numbers[0], @songs.fetch(numbers[1]).name, @pitches.fetch(numbers[2]), numbers[3]]
            when "loudness" then [:loudness, numbers[0], numbers[1]]
            when "stop_music" then [:stop_music]
            when "wave" then [:wave, @waves.fetch(numbers[0])]
            when "stop_wave" then [:stop_wave]
            when "noise" then [:noise, @hits.fetch(numbers[0])]
            when "noise_rest" then [:noise, nil]
            when "part_wave" then [:wave, wave_of_part(part_at(numbers[0], numbers[1]), @pitches.fetch(numbers[2]))]
            when "part_noise" then [:noise, hit_of_part(part_at(numbers[0], numbers[1]), @pitches.fetch(numbers[2]))]
            when "sample" then [:sample, @recordings.fetch(numbers[0]).name]
            when "stop_sample" then [:stop_sample]
            else raise ArgumentError, "the program printed a sound line nobody reads: #{line}"
            end
          end

          private

          # What a beep sounds like, worked out the interpreter's way (Reference#resolve_effect).
          def effect_of(node, defined)
            Audio::Sound.resolve_effect(node.tone, duty: node.duty, decay: node.decay, volume: node.volume, defined: defined)
          end

          # What a `wave` says, and what a `noise` comes to, as the interpreter logs each
          # (Reference#exec_wave and #resolve_noise).
          def wave_of(node) = { shape: node.shape, frequency: node.frequency, volume: node.volume }

          def hit_of(node)
            Audio::Sound.resolve_noise(node.preset, pitch: node.pitch, decay: node.decay, volume: node.volume,
                                                    metallic: node.metallic)
          end

          # Part number +part+ of song number +song+, counting every part the song has.
          def part_at(song, part) = @songs.fetch(song).voices.fetch(part)

          # A note of a song's part on the wave voice or the noise voice, as the interpreter's
          # player logs one (Reference::Player#log_wave_or_noise). The C prints the note's pitch;
          # the rest is the part's.
          def wave_of_part(part, pitch) = { shape: part.wave, frequency: pitch, volume: part.volume }

          def hit_of_part(part, pitch)
            { pitch: pitch, decay: part.decay, volume: part.volume, metallic: part.metallic }
          end
        end
      end
    end
  end
end
