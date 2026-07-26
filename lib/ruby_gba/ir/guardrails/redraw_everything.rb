# frozen_string_literal: true

require_relative "frame_reach"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # The specific, high-signal shape of the tearing footgun: a game loop that
        # clears the whole screen every frame AND repaints a collection that grows
        # as the game runs (a snake's body, a list of shots) — i.e. it rebuilds the
        # entire frame from scratch, including something unbounded. That's fine while
        # the collection is short, but the redraw gets heavier until it no longer
        # fits in the brief window the console has to change the screen, and the
        # picture tears. The fix is incremental drawing: paint the fixed parts once,
        # then each frame touch only the cells that actually change.
        #
        # This is the cheap structural companion to the cost estimator: no weights,
        # just the pattern, so it's near-zero false positives. It only looks at the
        # STEADY per-frame path — work behind a `pressed` edge (a once-per-round
        # transition, like repainting the board when a new game starts) is skipped,
        # so a game that paints the board once on START and then draws incrementally
        # is (correctly) left alone. Advisory, like the other soft checks.
        class RedrawEverything
          NAME = :redraw_everything

          # The pixel-drawing ops (draw is a category, but it also covers `screen`,
          # a mode-set, which isn't painting).
          PAINTS = %i[pixel fill_rect clear_screen draw_rect_at draw_text dma_fill_rect blit].freeze

          PROBLEM =
            "This game clears the whole screen every frame and then repaints a collection that grows as it " \
            "plays (a snake's body, a list of shots). That's fine while it's short, but the redraw gets " \
            "heavier as the collection grows, until it no longer fits in the brief moment the console has to " \
            "change the screen — and the picture tears. Paint the board once when a round starts, then each " \
            "frame repaint only the cells that actually change (draw the new one, erase the one that left)."

          def detect(program)
            # Double buffering is the cure for exactly this footgun: drawing goes to
            # a hidden page shown all at once, so clearing and repainting the whole
            # screen every frame can't tear (its worst case is a frame-rate drop,
            # which the draw-budget check catches on its own). So this warning —
            # which is specifically about *tearing* — has nothing to say here.
            return [] if buffered?(program)

            funcs = FrameReach.index_funcs(program)
            FrameReach.loops(program).filter_map do |loop_node|
              steady = FrameReach.steady_statements(loop_node, funcs)
              clears = steady.any? { |node| node.kind == :clear_screen }
              grows  = steady.any? { |node| growing_list_redraw?(node) }
              next unless clears && grows

              Finding.new(check: NAME, severity: :warning, message: PROBLEM, fix: nil)
            end
          end

          private

          def buffered?(program)
            program.walk.any? { |node| node.kind == :screen && node[:buffered] }
          end

          # A repeat over a list's length whose body paints — the unbounded redraw.
          def growing_list_redraw?(node)
            return false unless node.kind == :repeat

            count = node[:count]
            return false unless count.is_a?(Node) && count.kind == :list_len

            node.each.any? { |n| PAINTS.include?(n.kind) }
          end
        end
      end
    end
  end
end
