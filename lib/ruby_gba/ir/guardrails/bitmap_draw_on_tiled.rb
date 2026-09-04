# frozen_string_literal: true

require_relative "tiled_display"
require_relative "../modes"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A drawing call the tiled screen can never show, in a game that is
        # otherwise a working tiled game.
        #
        # `fill_rect` and its neighbors write pixels into the bitmap framebuffer.
        # The tiled screen never reads that framebuffer — it paints tiles and
        # composites sprites — so the call runs every frame, costs its time, and
        # changes nothing on screen. There is no crash and no error, and the rest
        # of the game looks fine, which is what makes it hard to spot: the
        # background is right there, so the screen is clearly working.
        #
        # This is the sibling of {EmptyTiledScreen}, and the split between them is
        # about which advice is TRUE, not about tidiness. When a tiled screen has
        # no background and no sprite, the author almost certainly meant to draw
        # the bitmap way, and EmptyTiledScreen tells them to change one line to
        # `screen :bitmap`. Say that here and it would be wrong: this game HAS a
        # background, so switching screens would throw it away. The fix is the
        # other one — put the drawing where the tiled screen can see it, or drop
        # the call. So this check speaks only once the program has committed to
        # tiled by giving it something to paint.
        class BitmapDrawOnTiled
          NAME = :bitmap_draw_on_tiled

          # The screen modes this check covers — both paint with tile hardware
          # (backgrounds + sprites), neither has a framebuffer a bitmap draw can land in.
          TILE_HARDWARE_MODES = [Modes::TILED, Modes::AFFINE].freeze

          def detect(program)
            modes = Modes.resolve(program)
            return [] unless modes.any_tiled? || modes.any_affine?
            return [] unless TiledDisplay.paints?(program)

            program.each.filter_map do |node|
              next unless TiledDisplay::BITMAP_DRAWS.include?(node.kind)
              mode = modes.mode_at(node)
              next unless TILE_HARDWARE_MODES.include?(mode)

              Finding.new(check: NAME, severity: :error,
                          message: message(TiledDisplay.verb_for(node.kind), mode), node: node)
            end
          rescue Modes::Conflict
            # The program already has a worse problem — one drawing routine reached
            # from two screen modes — and that error names it. Nothing to add.
            []
          end

          private

          def message(verb, mode)
            screen = mode == Modes::AFFINE ? "screen :rotozoom" : "screen :tiled"
            noun = mode == Modes::AFFINE ? "a rotozoom" : "a tiled"
            "`#{verb}` cannot draw on #{noun} screen. #{noun.capitalize} screen shows " \
              "backgrounds and sprites only, so this drawing never appears. There " \
              "is no crash or error to point at it.\n\n" \
              "This game already uses `#{screen}` for its backgrounds and " \
              "sprites, so it is on the right screen. To show something here, put " \
              "it in a `background` or draw it with a `sprite`. Or remove this line."
          end
        end
      end
    end
  end
end
