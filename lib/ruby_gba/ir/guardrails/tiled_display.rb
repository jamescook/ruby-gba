# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      # What the tiled display can and cannot put on screen. Two checks ask the
      # same questions of it — "is anything painting here?" and "is this a draw
      # only the bitmap screen understands?" — so the vocabulary lives here once
      # and the two can never drift apart on the answer.
      #
      # The tiled screen and the bitmap screen are two display systems sharing one
      # video memory. The bitmap screen keeps a picture of every pixel, and
      # `pixel`/`fill_rect`/`blit` write into it. The tiled screen keeps no such
      # picture: it paints small reusable tile images arranged by a map, plus
      # sprites composited on top, and nothing else reaches the display.
      module TiledDisplay
        module_function

        # What the tile hardware can actually put on screen. A `background` is a
        # map of tiles; an `object` is a sprite the display composites on top.
        PAINTS = %i[background object].freeze

        # Draw ops that only exist on the bitmap screen — they write pixels into
        # the framebuffer, which a tiled screen never shows.
        #
        # These are safe to key a check on because the DSL has already made its
        # choice by the time the tree exists: `draw_text`, `draw_number` and
        # `sprite` on a tiled screen record `object` nodes (little hardware-sprite
        # glyphs the console composites), never these. So one of these kinds
        # sitting in a tiled scope is a draw the author wrote for the other screen.
        BITMAP_DRAWS = %i[pixel fill_rect dma_fill_rect clear_screen draw_rect_at
                          blit blit_pose draw_text draw_digit].freeze

        # Does the program give the tile hardware anything to paint?
        def paints?(program)
          program.each.any? { |node| PAINTS.include?(node.kind) }
        end

        # The verb the developer typed for a node, e.g. :fill_rect -> "fill_rect". The table is
        # {PlainWords}', shared with the builder's own layer refusal, which has to name the
        # same verbs back to the same person.
        def verb_for(kind) = PlainWords.verb(kind)
      end
    end
  end
end
