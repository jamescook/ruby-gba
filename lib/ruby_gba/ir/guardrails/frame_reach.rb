# frozen_string_literal: true

require "set"

module RubyGBA
  module IR
    module Guardrails
      # Shared frame-path analysis for the per-frame footgun checks. Several
      # guardrails care about the same question — "what does this game loop actually
      # run *every* frame?" — so the traversal lives here once instead of in each.
      #
      # The steady path follows every call into funcs (a scene called every
      # frame is steady work), but deliberately does NOT descend into a body guarded
      # by a `pressed` edge: that fires on a press, once in a while (a new round
      # starting, a menu choice), not steadily — so a board painted once on START and
      # then drawn incrementally is correctly left out of the steady path. Its `.else` is
      # followed, though: the press is the rare frame, so the other side is the steady one.
      #
      # Both sides of an ordinary `if` are on the path, since either may be what runs this
      # frame — which also means two things a check finds can sit on opposite sides of one
      # `if` and never run in the same frame. The checks built on this accept that: they
      # warn about what a frame CAN do.
      module FrameReach
        module_function

        # Every game loop (an endless `loop`) in the program.
        def loops(program)
          program.each.select { |node| node.kind == :loop }
        end

        # name -> func node, so the steady walk can follow a call into its body.
        def index_funcs(program)
          program.each.select { |node| node.kind == :func }.to_h { |func| [func.name, func] }
        end

        # Every statement reachable each frame from +node+, following every call into
        # funcs and into an `.else` as well as a `.then`, but stopping at a `pressed`-guarded
        # (transition) body. A press's own `.else` is followed: the press is the rare frame,
        # so its other side is the steady one.
        def per_frame_statements(node, funcs, seen = Set.new, acc = [])
          if transition?(node)
            node.else&.children&.each { |child| per_frame_statements(child, funcs, seen, acc) }
            return acc
          end

          acc << node
          node.callees.each { |target| follow_call(target, funcs, seen, acc) }
          node.statement_bodies.each { |child| per_frame_statements(child, funcs, seen, acc) }
          acc
        end

        def follow_call(target, funcs, seen, acc)
          return acc if seen.include?(target)

          func = funcs[target] or return acc
          func.children.each { |child| per_frame_statements(child, funcs, seen | Set[target], acc) }
          acc
        end

        # A body gated on a `pressed` edge runs once in a while, not every frame.
        def transition?(node)
          node.kind == :if && node.cond&.kind == :pressed
        end
      end
    end
  end
end
