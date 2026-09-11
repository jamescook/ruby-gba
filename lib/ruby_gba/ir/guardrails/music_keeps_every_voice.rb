# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # Songs whose recorded parts keep every voice of the mixer, in a game that plays sounds
        # of its own.
        #
        # A part that plays an instrument has a mixer voice kept for it, and which voices are
        # kept is settled when the game is built — for the whole game, not only while that song
        # plays (see IR::Tunes). So a song with as many recorded parts as the mixer has voices
        # leaves the game's own `play`s nothing, ever: every one is dropped, and nothing says so.
        # Advisory, because a game can mean it — but a game that plays sounds almost never does.
        class MusicKeepsEveryVoice
          NAME = :music_keeps_every_voice
          PLAIN_NAME = "songs that leave no voices for the game's own sounds"

          # Exactly as many as the mixer has: a song with MORE is refused outright
          # (SongTooManyParts), and saying this about it as well would only be noise.
          def detect(program)
            return [] unless program.walk.any? { |node| node.kind == :play_sample }
            return [] unless Tunes.most_recorded_parts(program) == Sound::MIXER_VOICES

            song = Tunes.keeps_the_most(program)
            [Finding.new(check: NAME, severity: :warning, message: message(program, song), node: song)]
          end

          private

          def message(program, song)
            voices = Sound::MIXER_VOICES
            "#{SongWords.song_capitalized(program, song)} has #{voices} parts that play an instrument. The " \
              "mixer has #{voices} voices, and the music keeps all #{voices} of them for the whole game. This " \
              "game also starts its own sounds with `play`. Those sounds never play. To fix this, give the " \
              "song fewer parts that play an instrument."
          end
        end
      end
    end
  end
end
