# frozen_string_literal: true

require "set"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A program has to stop somewhere. If its top-level flow just ends — no
        # `halt`, no forever-running `game_loop` — the console doesn't stop at the
        # last line: it keeps executing whatever bytes come next in memory, which
        # is garbage. The classic version is a static program (draw a picture) that
        # forgets to `halt`.
        #
        # This reads it off the IR, which is exact where scanning finished machine
        # code was a heuristic: the top-level statements run unconditionally in
        # order, so the program stops iff one of them never returns — a `halt`, an
        # (always-infinite) `loop`, or a `call` into a func that itself never
        # returns. Everything else (a draw, an if, a case, a call to a func that
        # returns) falls through to the next line, and off the end if it's last.
        class Termination
          NAME = :termination

          # Definitions emit nothing on their own and don't execute in line, so
          # they can't be what stops the program — skip them when judging the flow.
          DEFINITIONS = %i[func define_sound song data bitmap].freeze

          PROBLEM =
            "This program does not stop at the end of your code. Nothing tells the " \
            "console to stop. So after the last line, it runs whatever is next in " \
            "memory (garbage). To fix this, end with `halt`. Or run a `game_loop`, " \
            "which loops forever."

          def detect(program)
            funcs = index_funcs(program)
            flow = executed(program)
            return [] if flow.empty? # nothing runs — that's the "no code" check's job
            return [] if flow.any? { |stmt| never_returns?(stmt, funcs, Set.new) }

            [Finding.new(check: NAME, severity: :warning, message: PROBLEM, fix: nil)]
          end

          private

          def executed(node)
            node.children.reject { |child| DEFINITIONS.include?(child.kind) }
          end

          def index_funcs(program)
            program.each.select { |node| node.kind == :func }.to_h { |func| [func[:name], func] }
          end

          # Whether reaching +stmt+ means control never falls through to the next
          # statement. A halt or an (always-infinite) loop stops for good; a call
          # stops only if the func it targets never returns. A raw block is opaque
          # — it might hand-roll its own halt/loop — so assume it may stop, rather
          # than warn wrongly. +seen+ guards a call cycle.
          def never_returns?(stmt, funcs, seen)
            case stmt.kind
            when :halt, :loop, :raw then true
            when :call then func_never_returns?(stmt[:target], funcs, seen)
            else false
            end
          end

          def func_never_returns?(target, funcs, seen)
            return false if seen.include?(target)

            func = funcs[target]
            return false unless func

            executed(func).any? { |stmt| never_returns?(stmt, funcs, seen | Set[target]) }
          end
        end
      end
    end
  end
end
