# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A one-time-setup footgun. `seed` sets the random stream's starting point —
        # something a game does ONCE, in setup. Written directly inside a per-frame
        # context (the game loop, a scene, a repeat/every timer) it re-runs every
        # frame and keeps resetting the stream to the same point, so every "random"
        # draw returns the same value: enemies stop varying, item drops stop changing,
        # rolls freeze. There's no crash — just a game that feels eerily fixed.
        #
        # This is the RNG twin of the bug where a `var` written inside a scene re-set
        # its variable every frame. `var` now applies its initial value once wherever
        # it's written (a declaration inits once); `seed` can't be silently hoisted the
        # same way, because a game may deliberately re-seed from something the player
        # influences (their reaction time). So here we TEACH it instead: a plain warning
        # naming the verb and the fix, leaving a deliberate re-seed free to proceed.
        #
        # Only an UNCONDITIONAL seed — a direct statement of the per-frame body — is
        # flagged. A seed gated by a condition or an input edge (`pressed(:start).then {
        # seed ... }`) is a normal, deliberate re-seed and is left alone. A churn
        # (`randomize`/`roll`/`rand`) reads the stream to advance it, so it isn't a
        # re-seed and belongs in the loop; only a fresh assignment counts.
        class SeedInLoop
          include PerFrameScope

          NAME = :seed_in_loop

          def detect(program)
            per_frame = per_frame_func_names(program)
            findings = []
            program.each do |node|
              next unless seed?(node)

              container = node.parent
              next unless per_frame_container?(container, per_frame)

              findings << Finding.new(check: NAME, severity: :warning,
                                      message: message_for(container), node: node)
            end
            findings
          end

          private

          # The hidden variable the random stream's state lives in — a `seed` (and every
          # churn) assigns it. Read from the one place that owns it so the two can't drift.
          def rng_state
            RubyGBA::Builder::Randomness::RNG_STATE
          end

          # A seed is an assignment to the stream's state that does NOT read the current
          # state. A churn (roll/rand/randomize) advances the stream by reading it —
          # state = state * a + c — so it references the state var; a re-seed replaces
          # the state outright and doesn't. "Sets the state without reading it" is
          # exactly a re-seed, and it's what tells the two apart on the tree.
          def seed?(node)
            node.kind == :set && node[:var] == rng_state && !reads_rng?(node[:value])
          end

          def reads_rng?(value)
            value.is_a?(Node) && value.walk.any? { |n| n.kind == :var_ref && n[:name] == rng_state }
          end

          def message_for(container)
            "`seed` sets the start point of the random stream. You do this one time, in setup. " \
              "This seed is inside #{per_frame_where(container)}. So it re-runs every frame and resets " \
              "the stream to the same start point. Then every random value is the same, and enemies, " \
              "drops, and rolls no longer vary. To fix this, move the seed to setup: above the loop, or " \
              "outside the scene. Then it runs one time. To move the stream while you wait for input, " \
              "call `randomize` there instead."
          end
        end
      end
    end
  end
end
