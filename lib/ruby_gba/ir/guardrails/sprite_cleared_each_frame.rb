# frozen_string_literal: true

require_relative "frame_reach"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # The sprite-that-gets-wiped footgun: a game loop that repaints a sprite AND
        # clears the whole screen every frame. The two contradict each other. A
        # sprite is the incremental, tear-safe way to move something — it remembers
        # the pixels underneath itself and puts them back as it moves — so there's
        # nothing to clear. A per-frame `clear_screen` (or a full-screen fill) erases
        # the field the sprite just restored and the sprite along with it, so the
        # sprite flickers or vanishes, and the tearing you used a sprite to avoid
        # comes right back. The fix is to paint the field ONCE, before the loop.
        #
        # A sprite is recognized structurally: its per-frame repaint uses save/
        # restore-region ops, which nothing but a sprite emits. Purely a pattern
        # match on the steady per-frame path, so it's near-zero false positives; a
        # clear behind a `pressed` edge (wiping the field when a new round starts) is
        # a transition, not steady work, and is correctly left alone. Advisory.
        class SpriteClearedEachFrame
          NAME = :sprite_cleared_each_frame

          SCREEN_W = Screen::WIDTH
          SCREEN_H = Screen::HEIGHT

          # Ops only a sprite's repaint emits — the tell that a sprite lives in a loop.
          SPRITE_OPS = %i[save_region restore_region].freeze

          PROBLEM =
            "This game moves a sprite, but it also clears the whole screen every frame. The two work against " \
            "each other. A sprite draws itself each frame and puts back the pixels under it as it moves. This " \
            "is how it leaves no trail. When you clear the screen every frame, you wipe the field the sprite " \
            "just put back, and the sprite with it. So the sprite flickers or disappears. To fix this, draw " \
            "the field one time, before the game loop. Let the sprite do the rest, and remove the clear from " \
            "inside the loop."

          def detect(program)
            funcs = FrameReach.index_funcs(program)
            FrameReach.loops(program).filter_map do |loop_node|
              steady = FrameReach.steady_statements(loop_node, funcs)
              next unless steady.any? { |node| SPRITE_OPS.include?(node.kind) }
              next unless steady.any? { |node| full_screen_clear?(node) }

              Finding.new(check: NAME, severity: :warning, message: PROBLEM, fix: nil)
            end
          end

          private

          # A whole-screen wipe: a `clear_screen`, or a fill that covers the display.
          def full_screen_clear?(node)
            return true if node.kind == :clear_screen
            return false unless %i[fill_rect dma_fill_rect].include?(node.kind)

            node[:w].to_i >= SCREEN_W && node[:h].to_i >= SCREEN_H
          end
        end
      end
    end
  end
end
