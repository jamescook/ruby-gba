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
      #
      # AND WHY ANY OTHER COLOR IS ONE MORE BRANCH. Black and white are a BRIGHTNESS
      # change, which is what `fade` is. Red is not: mixing a color in is a different
      # piece of the display, and that is `tint`. Both take an amount from 0 to 100 and
      # both leave the picture untouched underneath, so the ramp above them is the same
      # one — only the verb the branch reaches for changes. Each color a game asks for
      # earns a branch of its own, because a color is settled while building; a game asks
      # for one or two, and the routine only ever runs one of them.
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
        FIRST_TINT = 2 # every other color takes the next code after these two

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
        #   fade_out :red, frames: 12               # a redout, for a death
        #
        # The picture is not redrawn and nothing is lost — it is all still there under the
        # color, and `fade_in` brings it back untouched. Calling this again while a fade
        # runs redirects it from where it is now.
        #
        # `under:` places the fade in the stack instead of over the whole screen: it names
        # a layer, and that layer and everything in front of it stay as they are. Fade the
        # game out to a game-over screen and leave the score showing:
        #
        #   fade_out under: :ui
        #
        # `fade_in` with no arguments comes back the same way, so the layer is said once.
        # A layer and a color other than :black or :white cannot be asked for together,
        # which is a friendly error saying why.
        #
        # @param color [Symbol, String, Integer] the color to fade toward
        # @param frames [Integer, nil] how long the fade takes, in frames
        # @param duration [Numeric, nil] how long it takes, in seconds (instead of frames)
        # @param under [Symbol, nil] a layer the fade sits under, or nil for the whole screen
        def fade_out(color = :black, frames: nil, duration: nil, under: nil)
          start_fade(color, FULL, frames, duration, under: under)
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
        # @param color [Symbol, String, Integer, nil] a color; leave it out to keep the current one
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
        #   flash_screen :red                       # took damage
        #
        # Any color works, and red is the one a game reaches for most: a white flash reads
        # as "something happened" and a red one reads as "that hurt". Pair it with
        # `shake_screen` for a hit that is felt as well as seen. Calling it again restarts
        # the flash, so repeated hits keep flashing.
        #
        # @param color [Symbol, String, Integer] the color to flash
        # @param frames [Integer, nil] how long the flash lasts, in frames
        # @param duration [Numeric, nil] how long it lasts, in seconds
        # @param under [Symbol, nil] a layer the flash sits under, or nil for the whole screen
        def flash_screen(color = :white, frames: nil, duration: nil, under: nil)
          state = screen_fade_state
          state[:level].set FULL # start full, so the first frame shown is the bright one
          start_fade(color, 0.0, frames, duration, default: FLASH_FRAMES, under: under)
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
          PLAIN_NAME = "a fade with no frames to run on"

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
          PLAIN_NAME = "a fade out with no fade in"

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
        def start_fade(color, target, frames, duration, default: DEFAULT_FRAMES, under: nil)
          check_fade_placement!(color, under)
          place_the_fade(under) if under
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

            # The body is built once the game is written, not here — so by the time it
            # runs, every color the game asked for is known and each has its branch.
            once_a_frame(ROUTINE) do
              (active == 1).then do
                (color == BLACK).then { fade :black, level.to_i, under: @fade_place }
                (color == WHITE).then { fade :white, level.to_i, under: @fade_place }
                fade_tint_colors.each_with_index do |tint_color, i|
                  (color == FIRST_TINT + i).then { tint tint_color, level.to_i }
                end
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

        # WHERE THIS GAME'S SCREEN FADE SITS, and there is one of it.
        #
        # The pack is one ramp — one level, one color, one routine that walks them — and
        # its place in the stack is the same kind of thing: what a game means by "the
        # screen fading". Said on any of the verbs, it holds for all of them, so a
        # `fade_out under: :ui` is undone by a plain `fade_in`.
        #
        # Two different places is a friendly error rather than a choice, and the reason is
        # in the console: there is ONE set of blend registers, so two fades at two depths
        # cannot both be in force. A game that really wants that is writing two effects,
        # not one, and `fade` itself takes `under:` per call for it.
        def place_the_fade(under)
          if @fade_place && @fade_place != under
            raise ArgumentError,
                  "This game already fades under :#{@fade_place}, and now asks for :#{under}. " \
                  "A game has one screen fade, and it sits in one place. To fix this, use " \
                  "the same layer for every `fade_out` and `flash_screen`, or call `fade` " \
                  "yourself for a second one."
          end
          @fade_place = under
        end

        def fade_seconds_in_frames(duration)
          unless duration.is_a?(Numeric) && duration.positive?
            raise ArgumentError,
                  "a fade needs a positive duration in seconds. You gave #{duration.inspect}."
          end

          (duration * Builder::ControlFlow::FRAMES_PER_SECOND).round
        end

        # This color's code in the hidden variable the routine branches on. Black and
        # white have fixed ones, because the display brightens toward them and that is a
        # different verb; every other color earns the next code the first time the game
        # asks for it, and keeps it.
        def fade_color_code(color)
          return COLORS.fetch(color) if COLORS.key?(color)

          resolved = Color.resolve(color)
          fade_tint_colors << resolved unless fade_tint_colors.include?(resolved)
          FIRST_TINT + fade_tint_colors.index(resolved)
        end

        # The colors this game fades toward that are not black or white, in the order it
        # asked for them. Read by the routine when its body is built.
        def fade_tint_colors
          @fade_tint_colors ||= []
        end

        # A COLORED FADE CANNOT BE PLACED IN THE STACK, and the reason is the display
        # rather than this pack. Putting an effect at a depth works by hiding it from what
        # sits in front, and the console can hide only a BRIGHTNESS change that way — a
        # color mixed in reaches the whole picture however it is asked for.
        #
        # A game has one screen fade, so this asks about the whole game and not one call:
        # either order of the two — a color then a layer, or a layer then a color — leaves
        # the same game asking for something the console cannot show.
        def check_fade_placement!(color, under)
          place = under || @fade_place
          wanted = color unless color.nil? || COLORS.key?(color)
          wanted ||= fade_tint_colors.first
          return unless place && wanted

          raise ArgumentError,
                "This game fades under :#{place}, and it also fades toward " \
                "#{wanted.inspect}. The console can put only a fade to :black or :white " \
                "at a place in the stack. Every other color mixes into the whole picture. " \
                "To fix this, fade to :black or :white, or drop `under:` from every fade " \
                "in this game."
        end
      end
    end
  end
end
