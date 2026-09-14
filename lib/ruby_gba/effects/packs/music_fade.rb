# frozen_string_literal: true

module RubyGBA
  module Effects
    module Packs
      # Music fade — the music going down with the lights at the end of a game, and coming back
      # up for the next one.
      #
      # The pair to {ScreenFade}, and built the same way: `music_volume` is kernel, because the
      # player that sounds the notes is what has to honour it, and walking it over frames is a
      # few variables and a routine that runs each frame, written in the verbs a game is written
      # in. The level holds a fraction for the reason the screen fade's does — a whole-number
      # step would not land on the frame the author asked for.
      #
      # A FADED-OUT SONG GOES ON PLAYING, SILENTLY, the way a faded-out screen goes on being
      # drawn. What happens while nobody can hear it is the game's to say: stop it, switch to
      # another song, or bring the same one back. Stopping it here instead would fight a game
      # that names its song every frame, which a jukebox does — the old tune would start over
      # the frame after it stopped.
      module MusicFade
        LEVEL = :__music_fade_level   # how loud, 0.0 to 100.0
        TARGET = :__music_fade_target # where the ramp is heading
        STEP = :__music_fade_step     # how far it moves each frame
        ACTIVE = :__music_fade_active # 1 while the ramp is running
        ROUTINE = :__music_fade_tick

        FULL = 100.0
        DEFAULT_FRAMES = 30 # half a second, the same as a screen fade — they are usually said together

        # TARGET starts below nothing, so the guardrail can tell a fade in (which writes FULL) from
        # the declaration. The value is never used: the routine runs only once a fade has set both.
        NEVER_FADED = -1.0

        # Fade the music out, over half a second unless told otherwise. Call it once, at the
        # moment it begins; the framework walks the volume down every frame from there, and the
        # song carries on playing silently until `fade_music_in` brings it back.
        #
        #   fade_music_out                    # over half a second
        #   fade_music_out frames: 90         # a slow fade for a sad ending
        #   fade_music_out duration: 1.5      # the same, said in seconds
        #
        # Calling it again while a fade runs turns it round from where it is now.
        #
        # @param frames [Integer, nil] how long the fade takes, in frames
        # @param duration [Numeric, nil] how long it takes, in seconds (instead of frames)
        def fade_music_out(frames: nil, duration: nil)
          start_music_fade(0.0, frames, duration)
        end

        # Bring the music up from silence — the song playing now, or one named in the same
        # frame, which then starts silent rather than at full for a moment.
        #
        #   fade_music_in                    # as fast as the last fade out went down
        #   fade_music_in frames: 10
        #
        # With no length it comes up at the speed the music last went down, so a fade out and a
        # fade in are two words and no bookkeeping.
        #
        # @param frames [Integer, nil] how long it takes, in frames
        # @param duration [Numeric, nil] how long it takes, in seconds
        def fade_music_in(frames: nil, duration: nil)
          music_fade_state[:level].set 0.0
          music_volume 0
          start_music_fade(FULL, frames, duration)
        end

        # The guardrails this pack brings with it, forwarded by Effects.register_pack.
        #
        # There is no "needs a game loop" check here, unlike the screen fade's: a music fade is
        # only heard through a song, and a song in a game with no frames is already told so
        # (Guardrails::Checks::SongNeedsFrames). Saying it twice would be noise.
        def self.checks
          @checks ||= [FadedOutNeverIn.new]
        end

        # Music faded out and never brought back.
        #
        # A faded-out song goes on playing at no volume, and the volume stays at nothing for every
        # song after it — so the game plays on in silence, which is exactly what a game with its
        # sound switched off sounds like, and nothing says why. It is the screen fade's footgun
        # heard rather than seen.
        #
        # `fade_music_out` writes the target 0 and `fade_music_in` writes the full amount, and
        # nothing else writes the target at all. Turning the volume back up by hand counts too:
        # the volume is declared with one write of the full level, so a second write of a level
        # above nothing is the game's own `music_volume`.
        class FadedOutNeverIn
          NAME = :music_faded_out_never_in
          PLAIN_NAME = "music faded out and never brought back"

          MESSAGE =
            "This game calls `fade_music_out` and never calls `fade_music_in`. A song that " \
            "fades out keeps playing, but it makes no sound. Every song after it makes no sound " \
            "too. To fix this, call `fade_music_in` at the place where the music must come back."

          def detect(program)
            targets = writes_of(program, TARGET)
            outs = targets.select { |node| written(node)&.zero? }
            return [] if outs.empty?
            return [] if targets.any? { |node| written(node)&.positive? }
            return [] if writes_of(program, IR::Tunes::LEVEL).count { |node| written(node)&.positive? } > 1

            [IR::Guardrails::Finding.new(check: NAME, severity: :warning, message: MESSAGE, node: outs.last)]
          end

          private

          # Every write, the whole tree walked — a fade in under an `else` sits beside its `if`
          # rather than under it, and a walk of statements alone would miss it.
          def writes_of(program, name) = program.walk.select { |node| node.kind == :set && node.var == name }

          # The number a write puts in, when it is one written into the program.
          def written(node) = node.value.kind == :int ? node.value.value : nil
        end

        private

        def start_music_fade(target, frames, duration)
          state = music_fade_state
          state[:target].set target
          state[:step].set FULL / music_fade_frames(frames, duration) if frames || duration
          state[:active].set 1
          nil
        end

        # The fade's variables and the routine that walks them, declared once however many places
        # in the game fade the music.
        #
        # THE LEVEL MOVES FIRST AND IS APPLIED AFTER, which is the other way round from the screen
        # fade, and for a reason on the other side of the same coin. The frame a fade is called on
        # is already the music at its old volume — the player reads the volume at the start of the
        # next frame — so a routine that applied first would spend a frame saying what was already
        # true. Moving first, the frames the author asked for are frames the volume changes on.
        def music_fade_state
          @music_fade_state ||= begin
            level = var LEVEL, FULL
            target = var TARGET, NEVER_FADED
            step = var STEP, FULL / (DEFAULT_FRAMES - 1)
            active = var ACTIVE, 0

            once_a_frame(ROUTINE) do
              (active == 1).then do
                (level == target).then { active.set 0 }
                                 .else do
                                   level.approach target, step
                                   music_volume level.to_i
                                 end
              end
            end

            { level: level, target: target, step: step, active: active }
          end
        end

        # One fewer step than the frames the fade is shown over, so the level lands exactly on its
        # target on the last of them — the reckoning ScreenFade#fade_ramp_frames makes.
        def music_fade_frames(frames, duration)
          raise ArgumentError, "a music fade takes frames: or duration:, not both." if frames && duration

          count = duration ? music_fade_seconds(duration) : frames
          unless Whole.positive?(count)
            raise ArgumentError,
                  "a music fade needs a positive whole number of frames. You gave #{(frames || duration).inspect}."
          end

          [count - 1, 1].max.to_f
        end

        def music_fade_seconds(duration)
          unless duration.is_a?(Numeric) && duration.positive?
            raise ArgumentError,
                  "a music fade needs a positive duration in seconds. You gave #{duration.inspect}."
          end

          (duration * Builder::ControlFlow::FRAMES_PER_SECOND).round
        end
      end
    end
  end
end
