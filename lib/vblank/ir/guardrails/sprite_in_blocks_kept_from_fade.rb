# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # A sprite that a placed fade keeps out of the fade, in a game that also shows
        # that sprite in blocks.
        #
        # Each half is fine alone, and the two together are the one mix of this family a
        # display cannot show the way the game says it. A fade placed between two sprites
        # is held off the kept one by the sprite's own SHAPE: where its drawn pixels are,
        # the fade does not apply. A sprite in blocks no longer has that shape — its
        # blocks run past its edge on one side and stop short on another — so the hole in
        # the fade and the sprite drawn in it do not line up, and the sprite comes out
        # part faded with an unfaded outline of itself beside it.
        #
        # Nothing at either call site says so: one is a fade, the other is a pixelate, and
        # both look right where they are written. So it is refused here, with the way
        # round, which is nearly always what was meant anyway — a thing kept out of the
        # fade is a thing to keep readable, so keep it out of the blocks as well.
        #
        # Only where a fade's line really falls between the sprites. A fade that keeps
        # EVERY sprite, or none of them, holds nothing off by its shape and is left alone.
        class SpriteInBlocksKeptFromFade
          NAME = :sprite_in_blocks_kept_from_fade
          PLAIN_NAME = "a sprite in blocks that a fade is kept off"

          def detect(program)
            places = Backends::Blocks.places(program)
            return [] unless places.size == 1

            picture = IR::Stacking.picture(program)
            sharp = places.first ? IR::Stacking.at_or_above(picture, places.first).map(&:name) : []
            program.walk.select { |node| node.kind == :fade && node.under }.uniq(&:under).filter_map do |fade|
              next unless sprite_kept_from_fade_in_blocks?(picture, fade.under, sharp)

              Finding.new(check: NAME, severity: :error, node: fade, message: message(fade.under, places.first))
            end
          end

          private

          def sprite_kept_from_fade_in_blocks?(picture, under, sharp)
            kept = IR::Stacking.at_or_above(picture, under).map(&:name)
            keeps, fades = picture.objects.map(&:name).partition { |name| kept.include?(name) }
            !fades.empty? && keeps.any? { |name| !sharp.include?(name) }
          end

          def message(under, place)
            pixelates = place ? "pixelates under the layer :#{place}" : "pixelates the whole screen"
            "This game fades the screen under the layer :#{under}, and it #{pixelates}. So a " \
              "sprite in :#{under} is kept out of the fade, and it is also drawn in blocks. The " \
              "console keeps a sprite out of a fade by the shape it was drawn in. A sprite in " \
              "blocks has a different shape, so part of it fades. To fix this, keep the same " \
              "things out of both: `pixelate ..., under: :#{under}`."
          end
        end
      end
    end
  end
end
