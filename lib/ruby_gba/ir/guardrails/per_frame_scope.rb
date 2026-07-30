# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # Shared machinery for the one-time-setup guardrails. Several footguns are the
        # same shape: a verb meant to run ONCE (seed the random stream, create a list)
        # written directly inside a per-frame context, where it silently re-runs every
        # frame. This finds those contexts so each check only has to say which verb it
        # cares about and how to phrase the fix.
        #
        # A "per-frame container" is one whose body re-runs each frame: the game loop, a
        # runtime-counted repeat, an every-N-frames timer, or a per-frame func (a scene
        # dispatched by case_var, or a routine the loop calls). `after` is one-shot, so
        # its body runs once and isn't one. A conditional (`.then`) isn't a container
        # either — a setup op it guards may be a deliberate, one-off re-run — so only a
        # verb that is a DIRECT statement of a per-frame body is caught.
        module PerFrameScope
          # Every func that runs each frame: the funcs reached from inside a per-frame
          # loop (the game loop and its timers) by UNCONDITIONAL calls, followed
          # transitively — a func a per-frame func unconditionally calls is itself
          # per-frame. A call guarded by a condition or an input edge
          # (`pressed(:start).then { call :new_game }`) runs on demand, not each frame,
          # so it does NOT put its target on the every-frame path — that's what keeps a
          # one-off reset routine (which may legitimately re-seed or rebuild a list) from
          # being mistaken for per-frame setup.
          def per_frame_func_names(program)
            funcs = {}
            program.walk { |n| funcs[n[:name]] = n if n.kind == :func }

            reached = {}
            queue = []
            program.walk { |n| queue.concat(direct_call_targets(n)) if %i[loop repeat every].include?(n.kind) }
            until queue.empty?
              name = queue.shift
              next if reached[name]

              reached[name] = true
              queue.concat(direct_call_targets(funcs[name])) if funcs[name]
            end
            reached.keys
          end

          # Whether a node's direct container re-runs every frame — a per-frame loop, or
          # a per-frame func. This is called with the offending op's parent, so a match
          # means the op is an unconditional per-frame statement.
          def per_frame_container?(container, per_frame_funcs)
            return false unless container

            case container.kind
            when :loop, :repeat, :every then true
            when :func then per_frame_funcs.include?(container[:name])
            else false
            end
          end

          # A plain-language name for where an offending op sits, for the message.
          def per_frame_where(container)
            case container.kind
            when :loop then "your game loop"
            when :repeat then "a repeat loop"
            when :every then "an every(...) timer"
            when :func
              name = container[:name].to_s
              name.start_with?("_scene_") ? "the scene :#{name.sub('_scene_', '')}" : "the :#{name} routine (it runs every frame)"
            end
          end

          # The funcs a node UNCONDITIONALLY calls or dispatches to: the call/case
          # targets among its DIRECT statement children only. A call nested inside a
          # conditional isn't included — it doesn't run every time its container does.
          # (A case is case_var dispatch, which does run each frame, so its scene
          # targets count.)
          def direct_call_targets(node)
            targets = []
            node.children.each do |child|
              targets << child[:target] if child.kind == :call
              child[:clauses].each { |_value, target| targets << target } if child.kind == :case
            end
            targets
          end
        end
      end
    end
  end
end
