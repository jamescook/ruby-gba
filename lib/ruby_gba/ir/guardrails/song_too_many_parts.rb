# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A song with more parts than there are voices to play them.
        #
        # The console has four voices of its own: two that play a square wave, one that loops a
        # short waveform, and one that makes a hiss. A part that plays an instrument goes through
        # the framework's mixer instead, which sums Sound::MIXER_VOICES recordings at once. A
        # song needs a voice for every part at the same moment, since they all play together —
        # so past any of those numbers, some part of it would simply not be heard.
        #
        # Checked here, on the finished program, rather than where the notes are written,
        # because a song reaches the IR two ways — a `song` block, and a Score handed over in a
        # `songs` list — and both have to meet the same limits.
        class SongTooManyParts
          NAME = :song_too_many_parts
          PLAIN_NAME = "a song with more parts than there are voices to play them"

          # Each voice a part can play on: how many of that kind a song may have, and what the
          # message calls it. Kept together so a message and a limit cannot drift apart.
          LIMITS = {
            square: [Music::MAX_SQUARE_PARTS, "play the square wave",
                     "the console has %<limit>d square-wave voices for music"],
            wave: [Music::MAX_WAVE_PARTS, "play the wave voice",
                   "the console has %<limit>d wave voice"],
            noise: [Music::MAX_NOISE_PARTS, "play the noise voice",
                    "the console has %<limit>d noise voice"],
            recorded: [Sound::MIXER_VOICES, "play an instrument",
                       "the mixer plays %<limit>d recordings at once"],
          }.freeze

          def detect(program)
            program.walk.select { |node| node.kind == :song }.flat_map do |song|
              counts = LIMITS.keys.to_h { |kind| [kind, Tunes.parts_on(song, kind)] }
              LIMITS.filter_map do |kind, (limit, _, _)|
                next if counts.fetch(kind) <= limit

                message = message(program, song, kind, counts)
                Finding.new(check: NAME, severity: :error, message: message, node: song)
              end
            end
          end

          private

          def message(program, song, kind, counts)
            limit, does, because = LIMITS.fetch(kind)
            "#{SongWords.song_capitalized(program, song)} has #{counts.fetch(kind)} parts that " \
              "#{does}. A song can have #{limit} of them at most, because " \
              "#{format(because, limit: limit)}. #{fixes(program, song, kind, counts)}"
          end

          # WHERE THE PARTS THAT DO NOT FIT CAN GO, one voice with room per sentence. The point
          # of naming them all is that the two the console plays itself cost NO mixer voice,
          # which is the thing an author has no way to know and the reason to reach for them.
          def fixes(program, song, kind, counts)
            room = LIMITS.keys.reject { |other| other == kind }
                         .select { |other| counts.fetch(other) < LIMITS.fetch(other).first }
            last = "To fix this, use fewer parts that #{LIMITS.fetch(kind)[1]}."
            return last if room.empty?

            "#{room.map { |other| move(program, song, other) }.join(' ')} #{last}"
          end

          def move(program, song, kind)
            case kind
            when :square then "One part can play the square wave. To do that, remove `plays:` from it."
            when :wave then "One part can play the wave voice, with `plays: :wave`. That voice costs " \
                            "no mixer voice."
            when :noise then "One part can play the noise voice, with `plays: :noise`. That voice plays " \
                             "the drums, and it costs no mixer voice."
            else "One part can play an instrument: #{example(program, song)}."
            end
          end

          def example(program, song)
            return "`Score::Part.new(plays: :strings, notes: ...)`" if SongWords.score?(program, song)

            "`voice :strings, plays: :strings do ... end`"
          end
        end
      end
    end
  end
end
