# frozen_string_literal: true

module RubyGBA
  module Effects
    module Packs
      # Screen fade — the scene change, and the hit flash that is the same thing in a
      # hurry. Fade out to hand over to a game-over screen, fade in when play begins,
      # flash white when something lands.
      #
      # This is the pair {Effects} names in its own documentation: `fade` moves the
      # picture toward a color and is kernel, because the display does it in a register.
      # Walking that amount over frames is not — it is a few variables and a routine that
      # runs each frame, so it lives here, written in the same verbs a game is written in.
      #
      # WHY THE LEVEL HOLDS A FRACTION. The amount runs 0 to 100 and a fade lasts tens of
      # frames, so a whole-number step would be 3 for a thirty-frame fade — and 3 a frame
      # reaches 100 in thirty-four frames, not thirty. Saying `frames: 30` and taking
      # thirty-four is the kind of small lie that makes two effects drift apart when a
      # game tries to line them up. A variable that holds a fraction steps by exactly
      # 100/29 and lands on the last frame, so the number an author writes is the number
      # they get.
      #
      # WHY THE COLOR IS A BRANCH rather than a variable handed to `fade`. The display
      # picks brighten-toward-white or darken-toward-black with two bits of a register,
      # so there is no hardware reason it cannot be worked out as the game runs — the IR
      # simply settles it while building today. Until that changes, one routine covers
      # both by testing which is wanted; that is two compares on a frame that is fading
      # and nothing at all on a frame that is not.
      module ScreenFade
        # The hidden state, named with the framework's underscore prefix so a game's own
        # variables can never collide with it.
        LEVEL = :__fade_level     # how far toward the color, 0.0 to 100.0
        TARGET = :__fade_target   # where the ramp is heading
        STEP = :__fade_step       # how far it moves each frame
        COLOR = :__fade_color     # which color owns the screen right now
        ACTIVE = :__fade_active   # 1 while the ramp is running
        ROUTINE = :__fade_tick

        BLACK = 0
        WHITE = 1
        COLORS = { black: BLACK, white: WHITE }.freeze

        FULL = 100.0 # the amount at which nothing of the picture shows through

        # TARGET starts here rather than at 0, and that is not arbitrary: it is what lets
        # the guardrail below tell a real `fade_in` from the declaration. A fade_in writes
        # exactly 0, a fade_out writes 100, and nothing else in a program writes this
        # variable — so a program with no 0 written anywhere faded out and stayed there.
        # The value itself is never used: the routine only runs once a fade has set both a
        # target and its step.
        NEVER_FADED = -1.0

        DEFAULT_FRAMES = 30 # half a second — a scene change, not a blink
        FLASH_FRAMES = 6    # a hit, which wants to be over before it is read as a fade

        # Fade the screen out — toward black for a scene change, toward white for a
        # whiteout. Call it once, at the moment the change begins; the framework walks the
        # amount for you on every frame from there.
        #
        #   fade_out                                # to black, over half a second
        #   fade_out :white, frames: 10             # a fast whiteout
        #   fade_out :black, duration: 1.5          # the same, said in seconds
        #
        # The picture is not redrawn and nothing is lost — it is all still there under the
        # color, and `fade_in` brings it back untouched. Calling this again while a fade
        # runs redirects it from where it is now.
        #
        # @param color [Symbol] :black or :white
        # @param frames [Integer, nil] how long the fade takes, in frames
        # @param duration [Numeric, nil] how long it takes, in seconds (instead of frames)
        def fade_out(color = :black, frames: nil, duration: nil)
          start_fade(color, FULL, frames, duration)
        end

        # Bring the screen back from a fade — the other half of `fade_out`, and the one
        # that is easy to forget.
        #
        #   fade_in                    # back the way it went out, at the same speed
        #   fade_in frames: 10         # back faster than it left
        #
        # With no arguments it comes back in the color it faded to and over the same
        # number of frames, so a scene change is two words and no bookkeeping.
        #
        # @param color [Symbol, nil] :black or :white; leave it out to keep the current one
        # @param frames [Integer, nil] how long it takes, in frames
        # @param duration [Numeric, nil] how long it takes, in seconds
        def fade_in(color = nil, frames: nil, duration: nil)
          start_fade(color, 0.0, frames, duration)
        end

        # Flash the whole screen and let it fall back — the impact effect for a hit, a
        # score, a life lost. It is a fade that starts full and runs the other way, which
        # is why it lives here beside one.
        #
        #   flash_screen                            # a short white flash
        #   flash_screen :black, frames: 4          # a blink instead
        #
        # Pair it with `shake_screen` for a hit that is felt as well as seen. Calling it
        # again restarts the flash, so repeated hits keep flashing.
        #
        # Only :white and :black today. A flash in an arbitrary color is a different
        # effect on the display — the picture blended against a backdrop rather than
        # brightened — and needs a primitive the library does not have yet.
        #
        # @param color [Symbol] :white or :black
        # @param frames [Integer, nil] how long the flash lasts, in frames
        # @param duration [Numeric, nil] how long it lasts, in seconds
        def flash_screen(color = :white, frames: nil, duration: nil)
          state = screen_fade_state
          state[:level].set FULL # start full, so the first frame shown is the bright one
          start_fade(color, 0.0, frames, duration, default: FLASH_FRAMES)
        end

        # How far the screen is faded right now, as a value the game can read: 0 is the
        # picture as drawn and 100 is nothing but the color.
        #
        # THIS IS WHAT MAKES A SCENE CHANGE WRITABLE. `fade_out` leaves the screen dark on
        # purpose — that is what fading out means — so whatever is drawn next is invisible
        # until something brings it back. The order a game wants is: fade out, THEN switch
        # screens, THEN fade in, and the middle step has to wait for the first to arrive.
        # Reading the level is how it waits:
        #
        #   leaving = var :leaving, 0
        #   (lives <= 0).then { fade_out; leaving.set 1 }     # start dimming
        #   (leaving == 1).then do
        #     (fade_level == 100).then do                     # ...and once it is dark,
        #       state.set GAME_OVER                           # switch, and bring the
        #       fade_in                                       # new screen up
        #       leaving.set 0
        #     end
        #   end
        #
        # A value rather than a yes-or-no on purpose: half way through is a real place to
        # act too, and there is nothing to invert.
        def fade_level
          screen_fade_state[:level]
        end

        # The guardrails this pack brings with it, forwarded to the guardrail registry by
        # Effects.register_pack — so they only ever report on a build that has these verbs.
        def self.checks
          @checks ||= [NeedsGameLoop.new, FadedOutNeverIn.new]
        end

        # A fade with no frames to happen on.
        #
        # A fade is an amount walked a little further every frame, so it only exists over
        # time. The framework runs that walk at the frame boundary a `game_loop` gives it.
        # With no game loop there is no boundary and the walk never runs: the call sets its
        # target, nothing ever reads it, and the screen never changes. No crash, no
        # warning, and the call looks right where it is written.
        class NeedsGameLoop
          NAME = :fade_needs_game_loop

          MESSAGE =
            "This game fades the screen with `fade_out`, `fade_in` or `flash_screen`, " \
            "but it has no `game_loop`. A fade changes the screen a little on every " \
            "frame, so it needs frames to run on. With no game loop there are none, and " \
            "the screen never changes. To fix this, put the game in a `game_loop`."

          def detect(program)
            return [] unless declared?(program)
            return [] if called?(program)

            [IR::Guardrails::Finding.new(check: NAME, severity: :warning, message: MESSAGE,
                                         node: trigger(program) || :program)]
          end

          private

          def declared?(program)
            program.each.any? { |node| node.kind == :func && node.name == ROUTINE }
          end

          def called?(program)
            program.each.any? { |node| node.kind == :call && node.target == ROUTINE }
          end

          # Where the author wrote the fade. The routine is the framework's and carries no
          # line, but the target it set was recorded at the call site.
          def trigger(program)
            program.each.find { |node| node.kind == :set && node.var == TARGET }
          end
        end

        # A screen faded out and never brought back.
        #
        # A full fade blends every layer completely into one color, so nothing shows
        # through it — not the game, not a sprite, not text drawn afterwards. The picture
        # is all still there underneath, which is what makes this hard to spot: the
        # program runs correctly and draws everything it meant to, and the screen is a
        # flat color. The usual way in is to fade out for a scene change and forget the
        # fade back in.
        #
        # The library's own FadeNeverLifted check cannot see this one. It reads the amount
        # off a `fade` written by the author, and deliberately says nothing when that
        # amount is a variable — which is exactly what a fade over time is. So this reads
        # the pack's own target instead: `fade_out` writes the full amount, `fade_in` and
        # `flash_screen` write zero, and nothing else writes that variable at all.
        class FadedOutNeverIn
          NAME = :faded_out_never_in

          MESSAGE =
            "This game calls `fade_out` and never calls `fade_in`. A full fade blends " \
            "the whole picture into one color, so nothing shows through it. The game is " \
            "still running behind a flat screen. To fix this, call `fade_in` when the " \
            "screen must come back."

          def detect(program)
            targets = program.each.select { |node| node.kind == :set && node.var == TARGET }
            return [] if targets.empty?
            return [] if targets.any? { |node| returns_the_picture?(node) }

            [IR::Guardrails::Finding.new(check: NAME, severity: :warning, message: MESSAGE,
                                         node: targets.last)]
          end

          private

          # A target of exactly zero is a `fade_in` or a `flash_screen`. The declaration
          # writes NEVER_FADED, which is negative, so it cannot be mistaken for one.
          def returns_the_picture?(node)
            node.value.kind == :int && node.value.value.zero?
          end
        end

        private

        # Point the ramp at a new target and set it running. The one path all three verbs
        # take, so they cannot drift apart.
        #
        # A color of nil keeps whatever the screen is already fading toward, which is what
        # lets `fade_in` be written on its own: it comes back the way it went out. Leaving
        # the step alone when no length is given does the same for the speed.
        def start_fade(color, target, frames, duration, default: DEFAULT_FRAMES)
          state = screen_fade_state
          state[:color].set fade_color_code(color) if color
          state[:target].set target
          if frames || duration
            state[:step].set FULL / fade_ramp_frames(frames, duration, default)
          end
          state[:active].set 1
          nil
        end

        # The fade's variables and the routine that walks them, declared once however many
        # places in the game fade. The handles live on the builder, so the second call
        # finds them rather than declaring a second fade.
        #
        # THE ORDER INSIDE MATTERS. The level is APPLIED first and moved after, so the
        # first frame of a fade shows the level the screen is actually at — nothing yet
        # for a fade out, and full brightness for a flash, which is the frame a flash
        # exists for. Moving first would spend that frame part of the way there and a
        # flash would never be seen at its brightest.
        #
        # Once the level reaches its target the routine stops writing, and the display
        # holds the last amount it was given — which is what keeps a screen faded out
        # until something fades it back in, for no work per frame.
        def screen_fade_state
          @screen_fade_state ||= begin
            level = var LEVEL, 0.0
            target = var TARGET, NEVER_FADED
            step = var STEP, FULL / [DEFAULT_FRAMES - 1, 1].max
            color = var COLOR, BLACK
            active = var ACTIVE, 0

            each_frame(ROUTINE) do
              (active == 1).then do
                (color == BLACK).then { fade :black, level.to_i }
                (color == WHITE).then { fade :white, level.to_i }
                (level == target).then { active.set 0 }
                                 .else { level.approach target, step }
              end
            end

            { level: level, target: target, step: step, color: color, active: active }
          end
        end

        # How many frames the ramp is shown over, counting the first and the last. One
        # fewer step than that gets from one end to the other, so the level lands exactly
        # on the target on the final frame rather than a hair short of it — the same
        # reckoning the pulse pack makes for the same reason.
        def fade_ramp_frames(frames, duration, default)
          raise ArgumentError, "a fade takes frames: or duration:, not both." if frames && duration

          count = if duration
                    fade_seconds_in_frames(duration)
                  else
                    frames || default
                  end
          unless Whole.positive?(count)
            raise ArgumentError,
                  "a fade needs a positive whole number of frames. You gave #{(frames || duration).inspect}."
          end

          [count - 1, 1].max.to_f
        end

        def fade_seconds_in_frames(duration)
          unless duration.is_a?(Numeric) && duration.positive?
            raise ArgumentError,
                  "a fade needs a positive duration in seconds. You gave #{duration.inspect}."
          end

          (duration * Builder::ControlFlow::FRAMES_PER_SECOND).round
        end

        def fade_color_code(color)
          COLORS.fetch(color) do
            raise ArgumentError,
                  "a fade goes to :black or :white. You gave #{color.inspect}."
          end
        end
      end
    end
  end
end
