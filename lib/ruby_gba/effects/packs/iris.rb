# frozen_string_literal: true

module RubyGBA
  module Effects
    module Packs
      # The iris — the scene change where a circle closes on a point until the screen is
      # black, the scene is swapped while nobody can see it, and the circle opens again.
      #
      # `spotlight` is kernel: the display darkens the picture outside a window it is told
      # the shape of, a row at a time. Closing that light over frames is not — it is a few
      # variables and a routine that runs each frame — so it lives here, written in the same
      # verbs a game is written in, the pair to `fade_out` / `fade_in` and `pixelate_out` /
      # `pixelate_in`, and said the same way.
      #
      # IT CLOSES THE GAME'S OWN LIGHT. A game with a lantern has one light already, and the
      # display has room for one; so the iris takes that light down to nothing and, on the way
      # back, gives it back as big and as dark as it was. A game with no light gets one that
      # reaches past the screen and darkens nothing (see Builder#spotlight), which is what the
      # iris opens back to.
      #
      # WHAT IS WALKED IS THE RADIUS, held as a number with a fraction so a walk of any length
      # lands on the last frame asked for, as the pixelate's is. It runs between nothing and
      # about the farthest corner of the screen from the point — never short of it, and never
      # far past it — so the circle is seen moving from the first frame to the last.
      module Iris
        # The hidden state, named with the framework's underscore prefix.
        SIZE = :__iris_size        # how far the circle reaches now, a fraction
        TARGET = :__iris_target    # where the walk is heading
        STEP = :__iris_step        # how far it moves each frame
        ACTIVE = :__iris_active    # 1 while the walk is running
        SHUT = :__iris_shut        # 1 once a walk out has arrived
        RADIUS = :__iris_radius    # the light's own radius, to give back
        DARK = :__iris_dark        # ...and its own darkness
        REACH = :__iris_reach      # how far the farthest corner is, which a walk starts and ends at
        ROUTINE = :__iris_tick

        # TARGET starts here, which is what lets the guardrail below tell a real `iris_in`
        # from the declaration: nothing else writes this variable.
        NEVER_WALKED = -1.0

        DEFAULT_FRAMES = 30 # half a second — a scene change, not a blink

        MIDDLE_X = Console::Hardware::SCREEN_WIDTH / 2
        MIDDLE_Y = Console::Hardware::SCREEN_HEIGHT / 2

        # Close a circle on a point until the screen is black. Call it once, at the moment the
        # change begins; the framework walks the circle in on every frame from there.
        #
        #   iris_out                          # on the middle of the light, over half a second
        #   iris_out at: [hero.x + 8, hero.y + 8]
        #   iris_out frames: 20               # faster
        #   iris_out duration: 1.0            # the same, said in seconds
        #
        # `at:` is the point it closes on, in screen pixels; either half may be worked out as
        # the game runs. Left out, it closes on wherever the light already is.
        #
        # @param at [Array, nil] the point the circle closes on
        # @param frames [Integer, nil] how long the walk takes, in frames
        # @param duration [Numeric, nil] how long it takes, in seconds (instead of frames)
        def iris_out(at: nil, frames: nil, duration: nil)
          light = spotlight
          state = iris_state(light)
          light.move_to(*at) if at
          keep_light_to_give_back(light, state)
          state[:size].set! light.radius.clamp(0, state[:reach]).to_f
          state[:target].set! 0.0
          state[:step].set! state[:size] / WalkLength.steps(frames, duration, DEFAULT_FRAMES, "an iris")
          light.dark.set! 100
          state[:shut].set! 0
          state[:active].set! 1
          nil
        end

        # Open the circle again, back to the light the game had before — the other half of
        # `iris_out`. With nothing closed before it, the screen starts black and the circle
        # opens from nothing, which is how a game opens on an iris.
        #
        #   iris_in                # out from where it closed, over half a second
        #   iris_in frames: 10     # faster
        #   iris_in dark: 0        # ...and come back to no darkness: out of the cave, into daylight
        #
        # `radius:` and `dark:` are the light it opens back to, where that is not the light it
        # closed from — a scene change is often from a dark place to a light one. Either may be
        # worked out as the game runs. Onto a light that darkens nothing, the circle opens all
        # the way past the corners rather than stopping at the light's own size.
        #
        # @param frames [Integer, nil] how long it takes, in frames
        # @param duration [Numeric, nil] how long it takes, in seconds
        # @param radius [Integer, DSL::Value, nil] the light's radius once it is open
        # @param dark [Integer, DSL::Value, nil] how dark outside the light is once it is open
        def iris_in(frames: nil, duration: nil, radius: nil, dark: nil)
          light = spotlight
          state = iris_state(light)
          ((state[:active] == 0) & (state[:shut] == 0)).then do
            keep_light_to_give_back(light, state)
            state[:size].set! 0.0
            light.radius.set! 0
            light.dark.set! 100
          end
          state[:radius].set! radius if radius
          state[:dark].set! dark if dark
          (state[:dark] == 0).then { state[:target].set! state[:reach].to_f }
                             .else { state[:target].set! state[:radius].clamp(0, state[:reach]).to_f }
          state[:step].set! (state[:target] - state[:size]).abs / WalkLength.steps(frames, duration, DEFAULT_FRAMES, "an iris")
          state[:shut].set! 0
          state[:active].set! 1
          nil
        end

        # Whether the circle has closed: true from the frame a walk out arrives until the
        # next `iris_in`. THIS IS WHAT MAKES A SCENE CHANGE WRITABLE, the way `fade_level` is
        # for a fade — swap the scene while the screen is black:
        #
        #   iris_shut?.then { room.show_map next_room; iris_in }
        def iris_shut?
          iris_state(spotlight)[:shut] == 1
        end

        def self.checks = CHECKS

        # A screen irised out and never back in. The game runs on behind a black screen.
        class IrisOutNeverIn
          NAME = :iris_out_never_in
          PLAIN_NAME = "an iris out with no iris in"

          MESSAGE =
            "This game calls `iris_out` and never calls `iris_in`. The circle closes and the " \
            "screen stays black. The game is still running behind it. To fix this, call " \
            "`iris_in` when the picture must come back."

          def detect(program)
            writes = program.walk.select { |node| node.kind == :set && node.var == TARGET }
            outs = writes.select { |node| node.value.kind == :int && node.value.value.zero? }
            return [] if outs.empty? || writes.any? { |node| node.value.kind != :int }

            [IR::Guardrails::Finding.new(check: NAME, severity: :warning, message: MESSAGE, node: outs.last)]
          end
        end

        private

        # The light as it is now, kept to give back when the circle opens — unless a walk is
        # already running or the circle is shut, when what the light holds is the iris's own
        # and the light to give back was kept before. And how far the farthest corner of the
        # screen is from the light's middle, which a walk starts from and opens to.
        def keep_light_to_give_back(light, state)
          ((state[:active] == 0) & (state[:shut] == 0)).then do
            state[:radius].set! light.radius
            state[:dark].set! light.dark
          end
          state[:reach].set! corner_reach(light)
        end

        # HOW FAR THE FARTHEST CORNER IS, without a square root. Across and down to it are
        # the longer and the shorter of two sides; the longer plus half the shorter is never
        # less than the corner's distance and at most an eighth more, which is close enough
        # that the circle is moving on screen from the first frame of a walk.
        def corner_reach(light)
          across = (light.x - MIDDLE_X).abs + MIDDLE_X
          down = (light.y - MIDDLE_Y).abs + MIDDLE_Y
          apart = (across - down).abs
          longer = (across + down + apart) >> 1
          shorter = (across + down - apart) >> 1
          longer + (shorter >> 1) + 1
        end

        # The walk's variables and the routine that moves it, declared once however many
        # places in the game iris. The radius is SHOWN AND THEN MOVED, the order the screen
        # fade keeps, so the frame a walk out arrives on is a frame showing the circle shut.
        def iris_state(light)
          @iris_state ||= begin
            size = var SIZE, 0.0
            target = var TARGET, NEVER_WALKED
            step = var STEP, 1.0
            active = var ACTIVE, 0
            shut = var SHUT, 0
            radius = var RADIUS, 0
            dark = var DARK, 0
            reach = var REACH, 0

            once_a_frame(ROUTINE) do
              (active == 1).then do
                light.radius.set! size.to_i
                (size == target).then do
                  active.set! 0
                  (target == 0.0).then { shut.set! 1 }.else do
                    light.radius.set! radius
                    light.dark.set! dark
                  end
                end.else { size.approach! target, step }
              end
            end

            { size: size, target: target, step: step, active: active, shut: shut, radius: radius, dark: dark,
              reach: reach }
          end
        end

        # Down here because the check class it names is declared above it.
        CHECKS = Ractor.make_shareable([IrisOutNeverIn.new])
      end
    end
  end
end
