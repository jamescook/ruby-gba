# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A song with more parts than there are voices to play them.
        #
        # A plain part plays a square wave, and the console has two square-wave voices for
        # music. A part that plays an instrument goes through the framework's mixer, which sums
        # Sound::MIXER_VOICES recordings at once. A song needs a voice for every part at the
        # same moment, since they all play together — so past either number, some part of it
        # would simply not be heard.
        #
        # Checked here, on the finished program, rather than where the notes are written,
        # because a song reaches the IR two ways — a `song` block, and a Score handed over in a
        # `songs` list — and both have to meet the same limits.
        class SongTooManyParts
          NAME = :song_too_many_parts
          PLAIN_NAME = "a song with more parts than there are voices to play them"

          def detect(program)
            program.walk.select { |node| node.kind == :song }.flat_map do |song|
              recorded = Tunes.recorded_parts(song)
              squares = song.voices.size - recorded
              messages = []
              messages << squares_message(program, song, squares) if squares > Music::MAX_SQUARE_PARTS
              messages << recorded_message(program, song, recorded, squares) if recorded > Sound::MIXER_VOICES
              messages.map { |message| Finding.new(check: NAME, severity: :error, message: message, node: song) }
            end
          end

          private

          def squares_message(program, song, squares)
            limit = Music::MAX_SQUARE_PARTS
            example = if SongWords.score?(program, song)
                        "`Score::Part.new(plays: :strings, notes: ...)`"
                      else
                        "`voice :strings, plays: :strings do ... end`"
                      end
            "#{SongWords.song_capitalized(program, song)} has #{squares} parts that play the square wave. A " \
              "song can have #{limit} of them at most, because the console has #{limit} square-wave voices " \
              "for music. To add more parts, give each extra part an instrument to play: #{example}."
          end

          def recorded_message(program, song, recorded, squares)
            limit = Sound::MIXER_VOICES
            message = "#{SongWords.song_capitalized(program, song)} has #{recorded} parts that play an " \
                      "instrument. A song can have #{limit} of them at most, because the mixer plays " \
                      "#{limit} recordings at once. To fix this, use fewer parts that play an instrument."
            case Music::MAX_SQUARE_PARTS - squares
            when 1 then "#{message} Or remove the instrument from one of these parts. Then that part plays " \
                        "the square wave."
            when 2 then "#{message} Or remove the instrument from one or two of these parts. Then those " \
                        "parts play the square wave."
            else message
            end
          end
        end
      end
    end
  end
end
