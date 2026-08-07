# frozen_string_literal: true

module RubyGBA
  module Effects
    module Packs
      # Pulse — a sprite that breathes: it grows to a size, shrinks back, and keeps
      # doing it. A collectable that begs to be picked up, a boss winding up, a menu
      # item that says "this one is selected", a heart beating faster as the health
      # drops. It is the oldest trick there is for making a still picture feel alive.
      #
      # This is a pack, so every line below is written in public DSL verbs — `var`,
      # `each_frame`, `.approach`, `.then` — the same ones a game is written in. It knows
      # nothing about matrices or video memory. What makes it possible at all is
      # `sprite.scale`, which IS a hardware feature and lives in the library proper; the
      # rhythm on top of it is not, so it lives here. That split is the whole rule (see
      # {Effects}): new capability is kernel, new convenience is a pack.
      #
      # The rhythm is a counter, not a comparison against the size. Walking a counter up
      # and wrapping it can't get stuck; watching for the size to reach its target can,
      # if a step ever overshoots and the equality is never true.
      module Pulse
        # How long one full grow-and-shrink takes, if the caller doesn't say. Slow enough
        # to read as breathing rather than flashing.
        DEFAULT_SECONDS = 2.0

        # The size a pulse returns to. 1.0 is the size the sprite was drawn at.
        RESTING = 1.0

        # Make a sprite breathe: grow to +to+ times its drawn size, shrink back, and
        # repeat, taking +over+ seconds for the whole round trip.
        #
        #   pulse coin, to: 1.3                 # a coin that asks to be picked up
        #   pulse boss, to: 1.6, over: 0.8      # a fast, angry throb
        #   pulse ghost, from: 0.9, to: 1.1     # breathe around its own size
        #
        # Call it once, where the sprite is declared; the framework runs the rhythm every
        # frame from then on. Calling it again on the same sprite replaces the old rhythm
        # rather than adding a second one that fights it.
        #
        # Only a `screen :tiled` sprite can do this — resizing is the console's own, and
        # `sprite.scale` says so in a friendly error if the sprite is a bitmap one.
        #
        # @param sprite [HardwareSprite] the sprite to breathe
        # @param to [Numeric] the size at the top of the pulse (1.0 is as drawn)
        # @param from [Numeric] the size at the bottom of it
        # @param over [Numeric] seconds for one full grow and shrink
        def pulse(sprite, to:, from: RESTING, over: DEFAULT_SECONDS)
          half = pulse_half_cycle(over)
          pulse_sizes!(from, to)
          sprite.scale(from) # start where the rhythm starts, so the first frame is right

          # Written as Floats on purpose: a size with a fraction is what these variables
          # hold, and writing one is how a program says so. Handing over an already
          # multiplied-up whole number would be multiplied up a second time.
          state = pulse_state(sprite, half)
          state[:top].set to.to_f
          state[:bottom].set from.to_f
          # Over one frame FEWER than the half cycle, so the size lands exactly on the
          # size that was asked for on the last frame of the climb rather than a hair
          # short of it. It cannot overshoot: `approach` stops at its target.
          state[:step].set (to - from).abs / [half - 1, 1].max.to_f
          sprite
        end

        # The guardrails this pack brings with it — the same footgun the shake has, for
        # the same reason, so it reads the same way.
        def self.checks
          @checks ||= [NeedsGameLoop.new]
        end

        # A pulse that has no frames to happen on.
        #
        # A pulse is a size walked a little further every frame, so it only exists over
        # time. The framework runs that walk at the frame boundary a `game_loop` gives
        # it. With no game loop there is no boundary and the walk never runs: the sprite
        # sits at the size the pulse started it at, which is usually its resting size, so
        # nothing looks broken and nothing moves.
        class NeedsGameLoop
          NAME = :pulse_needs_game_loop

          MESSAGE =
            "This game pulses a sprite with `pulse`, but it has no `game_loop`. A pulse " \
            "changes the sprite's size a little on every frame, so it needs frames to " \
            "run on. With no game loop there are none, and the sprite never moves. To " \
            "fix this, put the game in a `game_loop`."

          ROUTINE_PREFIX = "__pulse_"

          def detect(program)
            routine = pulse_routine(program)
            return [] if routine.nil? || called?(program, routine)

            [IR::Guardrails::Finding.new(check: NAME, severity: :warning, message: MESSAGE,
                                         node: routine)]
          end

          private

          def pulse_routine(program)
            program.each.find { |node| node.kind == :func && node[:name].to_s.start_with?(ROUTINE_PREFIX) }
          end

          def called?(program, routine)
            program.each.any? { |node| node.kind == :call && node[:target] == routine[:name] }
          end
        end

        private

        # This sprite's own four variables and the routine that walks them, declared once
        # however many times the sprite is pulsed. A second `pulse` on the same sprite
        # finds them and writes new numbers into them, which is what makes it replace the
        # rhythm rather than stack another one on top.
        #
        # The counter runs a whole cycle and wraps. Below halfway the size heads for the
        # top, above it for the bottom; `approach` caps each step at the target, so the
        # size settles there and waits rather than overshooting if the arithmetic rounds
        # against us.
        def pulse_state(sprite, half)
          @pulse_states ||= {}
          @pulse_states[sprite.object_name] ||= begin
            name = sprite.object_name
            tick = var :"__pulse_#{name}_tick", 0
            top = var :"__pulse_#{name}_top", 1.0
            bottom = var :"__pulse_#{name}_bottom", 1.0
            step = var :"__pulse_#{name}_step", 1.0

            each_frame(:"__pulse_#{name}") do
              tick.add 1
              (tick >= half * 2).then { tick.set 0 }
              (tick < half).then { sprite.scale.approach top, step }
                           .else { sprite.scale.approach bottom, step }
            end

            { top: top, bottom: bottom, step: step }
          end
        end

        # Half a cycle, in frames — the part that grows. At least one frame, so the
        # shortest pulse anyone can ask for still has somewhere to happen.
        def pulse_half_cycle(over)
          unless over.is_a?(Numeric) && over.positive?
            raise ArgumentError,
                  "pulse needs a positive number of seconds for `over:`. You gave #{over.inspect}."
          end

          [(over * Builder::ControlFlow::FRAMES_PER_SECOND / 2).round, 1].max
        end

        # Both ends of the pulse have to be sizes a sprite can be drawn at, and they have
        # to differ — a pulse between one size and the same size never moves, which looks
        # exactly like a pulse that is broken.
        def pulse_sizes!(from, to)
          [from, to].each do |size|
            next if size.is_a?(Numeric) && size.positive?

            raise ArgumentError,
                  "a pulse's sizes must be more than 0. You gave #{size.inspect}. " \
                  "1.0 is the size the sprite was drawn at, 2.0 is twice as big."
          end
          return unless from == to

          raise ArgumentError,
                "a pulse needs two different sizes to move between, but `from:` and `to:` " \
                "are both #{to.inspect}. Give `to:` a different size."
        end
      end
    end
  end
end
