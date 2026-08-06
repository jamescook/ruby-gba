# frozen_string_literal: true

module RubyGBA
  module Effects
    module Packs
      # Screen shake — the impact effect for a hit, an explosion, a life lost.
      #
      # This is the worked example of what a pack is (see {Effects} for the rule).
      # Every line below is written in public DSL verbs — `var`, `each_frame`,
      # `camera`, `.then` — the same ones a game is written in. Nothing here knows
      # what an IR node is, and no backend knows this file exists. That is the whole
      # point: the shake runs on the console and in the reference interpreter because
      # `camera` already does, and it cost neither of them a line.
      #
      # What it does with those verbs: keep four variables, and move the camera a
      # little further each frame, alternating sides, until the count runs out — then
      # put the picture back exactly where it was. That last step is the one that
      # matters. A shake that does not restore leaves the whole game off centre with a
      # stripe of backdrop down one edge, forever.
      #
      # The jitter alternates rather than being random, which makes it repeatable: the
      # same hit shakes the same way every time, and both backends agree frame for
      # frame.
      module ScreenShake
        # The hidden variables the shake runs on, and the routine that drives them.
        # Named with the framework's underscore prefix so they can never collide with
        # a game's own variables.
        LEFT = :__shake_left       # frames of shaking still to run (-1 = settled)
        POWER = :__shake_power     # how far to move, in pixels
        DIRECTION = :__shake_dir   # +1 / -1, flipped every frame to make the jitter
        OFFSET = :__shake_offset   # this frame's offset, power * direction
        ROUTINE = :__shake_tick

        # Shake the screen — the impact effect for a hit, an explosion, a life lost.
        #
        # Say how hard and how long, and the framework does the rest: it jitters the
        # camera for you every frame from here on, then puts the picture back exactly
        # where it was. You call this once, at the moment of impact, and nothing else.
        #
        #   shake_screen intensity: 3, frames: 8      # eight frames of shaking
        #   shake_screen intensity: 3, duration: 0.2  # the same, said in seconds
        #
        # Calling it again while a shake runs restarts it, so repeated hits keep
        # shaking rather than queueing up.
        #
        # @param intensity [Integer] how far the picture moves, in pixels
        # @param frames [Integer, nil] how long to shake, in frames
        # @param duration [Numeric, nil] how long to shake, in seconds (instead of frames)
        def shake_screen(intensity: 2, frames: nil, duration: nil)
          count = shake_screen_frames(frames, duration)
          unless intensity.is_a?(Integer) && intensity.positive?
            raise ArgumentError,
                  "shake_screen needs a positive whole number for intensity. " \
                  "You gave #{intensity.inspect}."
          end

          shake = screen_shake_state
          shake[:left].set count
          shake[:power].set intensity
        end

        # The guardrails this pack brings with it. Effects.register_pack forwards them
        # to the guardrail registry, so the footgun below is only ever reported for a
        # build that loaded this pack.
        def self.checks
          @checks ||= [NeedsGameLoop.new]
        end

        # A screen shake that has no frames to happen on.
        #
        # A shake works by moving the picture a small amount, a different way each
        # frame, and then putting it back — so it is spread over time by definition.
        # The framework runs that for you once per frame, at the frame boundary a
        # `game_loop` provides. A program with no game loop has no boundary, so the
        # routine is never reached: `shake_screen` sets its counter, nothing ever
        # reads it, and the screen sits perfectly still. No crash, no warning, and the
        # call looks right where it is written.
        #
        # Read structurally rather than from build-time bookkeeping: the shake routine
        # is declared as soon as anything shakes, and a call to it is placed at each
        # frame boundary. A declared routine with no call to it is exactly this bug.
        class NeedsGameLoop
          NAME = :shake_needs_game_loop

          MESSAGE =
            "This game shakes the screen with `shake_screen`, but it has no " \
            "`game_loop`. A shake moves the picture a small amount on every frame, " \
            "so it needs frames to run on. With no game loop there are none, and the " \
            "screen never moves. To fix this, put the game in a `game_loop`."

          def detect(program)
            return [] unless declared?(program)
            return [] if called?(program)

            [IR::Guardrails::Finding.new(check: NAME, severity: :warning, message: MESSAGE,
                                         node: trigger(program) || :program)]
          end

          private

          def declared?(program)
            program.each.any? { |node| node.kind == :func && node[:name] == ROUTINE }
          end

          def called?(program)
            program.each.any? { |node| node.kind == :call && node[:target] == ROUTINE }
          end

          # Where the author wrote `shake_screen`. The routine itself is the
          # framework's and carries no line, but the counter it sets was recorded at
          # the call site, so that is the line to send them to.
          def trigger(program)
            program.each.find { |node| node.kind == :set && node[:var] == LEFT }
          end
        end

        private

        # Declare the shake's variables and its per-frame routine, once, however many
        # places in the game shake the screen. The handles are kept on the builder, so
        # the second `shake_screen` finds them rather than declaring a second shake.
        #
        # The routine owns the camera while a shake lasts: it flips the direction,
        # moves the picture that far, and counts down. The settle branch comes FIRST so
        # the last shaking frame is really shown — the branch below it takes the count
        # to zero, and only the NEXT frame puts the picture back. Once settled the
        # count goes negative, so a game that is not shaking does no work at all.
        def screen_shake_state
          @screen_shake_state ||= begin
            left = var LEFT, -1 # settled: nothing to undo yet
            power = var POWER, 0
            direction = var DIRECTION, 1
            offset = var OFFSET, 0

            each_frame(ROUTINE) do
              (left == 0).then do
                camera 0, 0
                left.sub 1 # -> -1, so this never runs again until the next shake
              end
              (left > 0).then do
                direction.flip
                offset.set power * direction
                camera offset, offset
                left.sub 1
              end
            end

            { left: left, power: power }
          end
        end

        # How many frames to shake for, from whichever unit the caller used.
        def shake_screen_frames(frames, duration)
          raise ArgumentError, "shake_screen takes frames: or duration:, not both." if frames && duration

          if duration
            in_frames = (duration * Builder::ControlFlow::FRAMES_PER_SECOND).round if duration.is_a?(Numeric)
            unless in_frames&.positive?
              raise ArgumentError,
                    "shake_screen needs a positive duration in seconds. You gave #{duration.inspect}."
            end
            return in_frames
          end

          frames ||= 8 # a short, punchy default
          unless frames.is_a?(Integer) && frames.positive?
            raise ArgumentError,
                  "shake_screen needs a positive whole number of frames. You gave #{frames.inspect}."
          end
          frames
        end
      end
    end
  end
end
