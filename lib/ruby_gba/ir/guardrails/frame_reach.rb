# frozen_string_literal: true

require "set"

module RubyGBA
  module IR
    module Guardrails
      # Shared frame-path analysis for the per-frame footgun checks. Several
      # guardrails care about the same question — "what does this game loop actually
      # run *every* frame?" — so the traversal lives here once instead of in each.
      #
      # The steady path follows call/case dispatch into funcs (a scene called every
      # frame is steady work), but deliberately does NOT descend into a body guarded
      # by a `pressed` edge: that fires on a press, once in a while (a new round
      # starting, a menu choice), not steadily — so a board painted once on START and
      # then drawn incrementally is correctly left out of the steady path.
      module FrameReach
        module_function

        # Every game loop (an endless `loop`) in the program.
        def loops(program)
          program.each.select { |node| node.kind == :loop }
        end

        # name -> func node, so the steady walk can follow a call into its body.
        def index_funcs(program)
          program.each.select { |node| node.kind == :func }.to_h { |func| [func[:name], func] }
        end

        # Every statement reachable each frame from +node+, following call/case into
        # funcs but stopping at a `pressed`-guarded (transition) body.
        def steady_statements(node, funcs, seen = Set.new, acc = [])
          return acc if transition?(node)

          acc << node
          case node.kind
          when :call then follow(node[:target], funcs, seen, acc)
          when :case then node[:clauses].each { |(_value, target)| follow(target, funcs, seen, acc) }
          end
          node.children.each { |child| steady_statements(child, funcs, seen, acc) }
          acc
        end

        def follow(target, funcs, seen, acc)
          return acc if seen.include?(target)

          func = funcs[target] or return acc
          func.children.each { |child| steady_statements(child, funcs, seen | Set[target], acc) }
          acc
        end

        # A body gated on a `pressed` edge runs once in a while, not every frame.
        def transition?(node)
          node.kind == :if && node[:cond]&.kind == :pressed
        end
      end
    end
  end
end
