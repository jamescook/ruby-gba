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
          NAME = :seed_in_loop

          def detect(program)
            per_frame = per_frame_func_names(program)
            findings = []
            program.each do |node|
              next unless seed?(node)

              container = node.parent
              next unless per_frame_container?(container, per_frame)

              findings << Finding.new(check: NAME, severity: :warning,
                                      message: message_for(container), source: node.source)
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

          # A container whose body re-runs each frame: the game loop, a runtime-counted
          # repeat, an every-N-frames timer, or a per-frame func (a scene dispatched by
          # case_var, or a routine the loop calls). `after` is one-shot — a seed there
          # runs once and is fine — and a conditional (`.then`) isn't a container here, so
          # a seed it guards is treated as a deliberate re-seed.
          def per_frame_container?(container, per_frame_funcs)
            return false unless container

            case container.kind
            when :loop, :repeat, :every then true
            when :func then per_frame_funcs.include?(container[:name])
            else false
            end
          end

          # Every func that runs each frame: the call/case targets reached from inside a
          # per-frame loop (the game loop and its timers), followed transitively — a func
          # a per-frame func calls is itself per-frame.
          def per_frame_func_names(program)
            funcs = {}
            program.walk { |n| funcs[n[:name]] = n if n.kind == :func }

            reached = {}
            queue = []
            program.walk { |n| queue.concat(call_targets(n)) if %i[loop repeat every].include?(n.kind) }
            until queue.empty?
              name = queue.shift
              next if reached[name]

              reached[name] = true
              queue.concat(call_targets(funcs[name])) if funcs[name]
            end
            reached.keys
          end

          # Every func a node's subtree calls or dispatches to (including else-branches,
          # which live in an attr rather than in #children — hence walk, not each).
          def call_targets(node)
            targets = []
            node.walk do |n|
              targets << n[:target] if n.kind == :call
              n[:clauses].each { |_value, target| targets << target } if n.kind == :case
            end
            targets
          end

          def message_for(container)
            "seed sets the random stream's starting point — something you do once, in setup. " \
              "This seed is inside #{where(container)}, so it re-runs every frame and keeps resetting " \
              "the stream to the same point: every random draw then returns the same value (enemies, " \
              "drops, and rolls stop varying). Move the seed to setup — above the loop, or outside the " \
              "scene — so it runs once. To keep stirring the stream while you wait for input, call " \
              "`randomize` there instead."
          end

          # A plain-language name for where the offending seed sits, for the message.
          def where(container)
            case container.kind
            when :loop then "your game loop"
            when :repeat then "a repeat loop"
            when :every then "an every(...) timer"
            when :func
              name = container[:name].to_s
              name.start_with?("_scene_") ? "the scene :#{name.sub('_scene_', '')}" : "the :#{name} routine (it runs every frame)"
            end
          end
        end
      end
    end
  end
end
