# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A SOUND EFFECT AND A SONG PART THAT SHARE ONE OF THE CONSOLE'S VOICES.
        #
        # The console has a small, fixed set of voices, and a sound effect plays on one of them
        # directly. So does a song part that names one of them. When a game does both, the two
        # keep cutting each other off — the effect interrupts the tune, the tune's next note
        # interrupts the effect — and that is silent and baffling if you do not know the console
        # only has so many voices. So we say it plainly.
        #
        # Three pairs, one per voice the console plays itself:
        #
        #   * `beep` and a song's SECOND square part. A one-part song leaves the beep's voice
        #     free; a second part is the only voice left.
        #   * `wave` and a song part on the wave voice. There is one, so any such part collides.
        #   * `noise` and a song part on the noise voice. Likewise.
        #
        # Advisory — the build still produces a ROM, and the two really can share a voice if you
        # do not mind them interrupting each other. A part that plays a recorded instrument
        # sounds through the mixer instead, so it never reaches any of these.
        class ChannelConflict
          NAME = :channel_conflict
          PLAIN_NAME = "a sound effect and a song that share a voice"

          # Which verb plays each voice, and what to call the voice in the message.
          EFFECTS = { beep: "beeps", wave: "wave tones", noise: "noise hits" }.freeze

          def detect(program)
            played = Tunes.played(program)
            plays = EFFECTS.keys.select { |verb| program.walk.any? { |node| node.kind == verb } }

            plays.flat_map do |verb|
              played.select { |song| collides?(song, verb) }.map do |song|
                Finding.new(check: NAME, severity: :warning, message: send(:"#{verb}_message", program, song),
                            node: song)
              end
            end
          end

          private

          # A beep shares the SECOND square voice, so one square part is fine. A wave tone or a
          # noise hit shares the only voice of its kind, so one part is already a collision.
          def collides?(song, verb)
            return Tunes.parts_on(song, :square) >= Music::MAX_SQUARE_PARTS if verb == :beep

            Tunes.parts_on(song, verb).positive?
          end

          def beep_message(program, song)
            "#{SongWords.song_capitalized(program, song)} plays in two parts. Its second part uses the same " \
              "sound voice as your beeps. The console has only a few voices. While the song plays, a beep and " \
              "its lower part interrupt each other. To use beeps and this music together, make it a one-part " \
              "song, just the melody. Or play the beeps only while the song does not play."
          end

          def wave_message(program, song)
            voice_message(program, song, "the wave voice", "wave", "wave tones")
          end

          def noise_message(program, song)
            voice_message(program, song, "the noise voice", "noise", "noise hits")
          end

          def voice_message(program, song, voice, verb, effects)
            "#{SongWords.song_capitalized(program, song)} has a part that plays #{voice}. Your #{effects} " \
              "play #{voice} too, and the console has one of it. While the song plays, a `#{verb}` and this " \
              "part interrupt each other. To use both together, remove this part from the song. Or play the " \
              "#{effects} only while the song does not play."
          end
        end
      end
    end
  end
end
