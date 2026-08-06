# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A tiled screen with nothing for the tile hardware to paint — a silent
        # black screen.
        #
        # The tiled screen and the bitmap screen are two different display systems
        # that share the same video memory. The bitmap screen keeps a picture of
        # every pixel, and `pixel`/`fill_rect`/`blit` write into it. The tiled
        # screen keeps no such picture: it paints small reusable tile images,
        # arranged by a map, plus sprites composited on top. Nothing else reaches
        # the display. So a tiled screen with no background and no sprite paints
        # tile zero everywhere, tile zero is all color zero, and color zero is
        # black.
        #
        # The version people actually hit is a mode conversion. You have a working
        # bitmap game, you switch one line to `screen :tiled` because you want
        # sprites or scrolling, and every draw call in the game keeps running and
        # keeps painting a framebuffer that is no longer on screen. The game is
        # perfectly healthy and the console shows nothing.
        #
        # Because the check knows which of those two mistakes it found, it gives
        # the fix that matches: a game already drawing the bitmap way is told to
        # pick the bitmap screen, and a game drawing nothing is shown how to add
        # tiled content.
        class EmptyTiledScreen
          NAME = :empty_tiled_screen

          # What the tile hardware can actually put on screen. A `background` is a
          # map of tiles; an `object` is a sprite the display composites on top.
          # Either one means the screen is not blank.
          PAINTS = %i[background object].freeze

          # Draw ops that only exist on the bitmap screen — they write pixels into
          # the framebuffer, which a tiled screen never shows. Their presence is
          # how we know the developer meant to draw the bitmap way.
          BITMAP_DRAWS = %i[pixel fill_rect dma_fill_rect clear_screen draw_rect_at
                            blit blit_pose draw_text draw_digit].freeze

          # The DSL verb behind a node kind, for kinds whose internal name isn't
          # what the developer typed. Naming their own verb back to them is what
          # makes the message land.
          VERB_FOR = { blit_pose: "sprite", draw_digit: "draw_number" }.freeze

          def detect(program)
            return [] unless only_tiled?(program)
            return [] if paints?(program)

            verb = bitmap_verb(program)
            # Blame the `screen :tiled` line either way: it's the one line to change
            # for a game that meant to draw the bitmap way, and the one line that made
            # a promise the rest of the program never kept for a game with no content.
            [Finding.new(
              check: NAME,
              severity: :error,
              message: verb ? wrong_screen(verb) : nothing_to_show,
              node: tiled_screen_node(program),
            )]
          end

          private

          # The message for the mode-conversion mistake: the game draws, but it
          # draws the way the other screen draws.
          def wrong_screen(verb)
            "This game draws with `#{verb}`, but the screen mode is `screen :tiled`. " \
              "A tiled screen shows backgrounds and sprites only. It cannot show " \
              "`pixel`, `fill_rect`, `blit`, or `clear_screen`. So the drawing never " \
              "appears, and every frame stays black. There is no crash or error to " \
              "point at it.\n\n" \
              "To draw this way, change one line:\n\n" \
              "    screen :bitmap\n\n" \
              "To use sprites and scrolling instead, keep `screen :tiled`. Then add a " \
              "`background` or a `sprite`, and draw with those."
          end

          # The message for a tiled screen that was never given content.
          def nothing_to_show
            "This game sets `screen :tiled`, but it gives the screen nothing to show. " \
              "A tiled screen shows backgrounds and sprites only. With neither one, " \
              "every frame stays black. There is no crash or error to point at it.\n\n" \
              "To fix this, add a background. A background takes three steps:\n\n" \
              "    image :brick, \"#\" => :brown do ... end   # the picture for one tile\n" \
              "    tiles :ground, \"#\" => :brick             # a set of tiles\n" \
              "    background :level, tiles: :ground, map: \"##########\"\n\n" \
              "Or add a `sprite`. To draw with `pixel` or `fill_rect` instead, use " \
              "`screen :bitmap`."
          end

          # True when the program picks a screen and every mode it picks is tiled.
          # A program that also has a bitmap screen is switching modes per scene:
          # its bitmap drawing is correct where it sits, and judging one scene at a
          # time is a different check. Staying quiet beats blaming a valid program.
          def only_tiled?(program)
            modes = program.each.filter_map { |node| node[:mode] if node.kind == :screen }
            !modes.empty? && modes.all?(:tiled.method(:==))
          end

          def paints?(program)
            program.each.any? { |node| PAINTS.include?(node.kind) }
          end

          # The verb the developer typed for the first bitmap-only draw, or nil if
          # the game draws nothing at all.
          def bitmap_verb(program)
            kind = program.each.find { |node| BITMAP_DRAWS.include?(node.kind) }&.kind
            kind && (VERB_FOR[kind] || kind.to_s)
          end

          def tiled_screen_node(program)
            program.each.find { |node| node.kind == :screen && node[:mode] == :tiled }
          end
        end
      end
    end
  end
end
