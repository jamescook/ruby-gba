# frozen_string_literal: true

require "set"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A game loop that never waits for the screen's vertical blank runs flat
        # out — thousands of passes a second instead of 60 — rather than once per
        # frame. Three things go wrong at once: the picture tears or flickers
        # (drawing lands mid-scanout), the loop spins for nothing (the screen only
        # refreshes 60x/sec regardless), and any frame-based logic — edge-detected
        # input, the music sequencer — races at absurd speed. The classic report
        # is "my game runs way too fast / it flickers."
        #
        # This is a SOFT, advisory warning, not an error: there are legitimate
        # reasons to have no wait_vblank (a raw block hand-rolling its own sync, a
        # deliberate benchmark loop, or — later — VBlank-IRQ / IntrWait timing), so
        # we point it out and let the build proceed rather than block it.
        class VblankSync
          NAME = :vblank_sync

          PROBLEM =
            "This game loop never waits for the screen to refresh. So it runs " \
            "thousands of times a second, not 60. The usual signs are a game that " \
            "plays too fast and a picture that tears or flickers. Add `wait_vblank` " \
            "as the first line inside the loop. Then each pass runs in step with " \
            "the display."

          # Warn for every loop from which no frame sync is reachable. Reachability
          # — not a direct-child check — because a game may sync inside a scene it
          # dispatches to rather than in the loop body itself.
          def detect(program)
            funcs = index_funcs(program)
            loops(program).filter_map do |loop_node|
              next if reaches_sync?(loop_node, funcs, Set.new)

              Finding.new(check: NAME, severity: :warning, message: PROBLEM, fix: nil)
            end
          end

          private

          def loops(program)
            program.each.select { |node| node.kind == :loop }
          end

          def index_funcs(program)
            program.each.select { |node| node.kind == :func }.to_h { |func| [func[:name], func] }
          end

          # Whether a frame sync is reachable from +node+, following `call` and
          # `case` dispatch into the funcs they target. A reachable `raw` block
          # counts as "synced": it's opaque, so it may hand-roll a sync we can't
          # see, and staying quiet beats crying wolf. +seen+ guards a call cycle.
          def reaches_sync?(node, funcs, seen)
            node.walk.any? do |n|
              case n.kind
              when :wait_vblank, :raw then true
              when :call then follow?(n[:target], funcs, seen)
              when :case then n[:clauses].any? { |(_value, target)| follow?(target, funcs, seen) }
              else false
              end
            end
          end

          def follow?(target, funcs, seen)
            return false if seen.include?(target)

            func = funcs[target]
            return false unless func

            reaches_sync?(func, funcs, seen | Set[target])
          end
        end
      end
    end
  end
end
