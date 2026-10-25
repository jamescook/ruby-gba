# frozen_string_literal: true

require RubyGBA.root.join("lib/ruby_gba/ir/modes").to_s

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # `hide_sprites` where there is no sprite layer to switch off.
        #
        # On a screen drawn from tiles the console draws its sprites as a layer of their own,
        # over the backgrounds, and one bit says whether that layer is drawn at all — which is
        # what `hide_sprites` turns off for a frame. A bitmap screen has no such layer: its
        # sprites are painted into the one picture and taken out of it again, by the game's own
        # code. So the call would build, run, and change nothing, and nothing would say why. It
        # is refused instead, with the screen that has the layer and the verb that hides one
        # sprite on a bitmap screen.
        #
        # The screen is read where the call is, so a tiled scene of a game whose title is a
        # bitmap one can hide its sprites.
        class HideSpritesOnBitmap
          NAME = :hide_sprites_on_bitmap
          PLAIN_NAME = "hiding every sprite on a bitmap screen"

          def detect(program)
            modes = Modes.resolve(program)
            program.each.filter_map do |node|
              next unless node.kind == :hide_sprites && Modes::BITMAP_MODES.include?(modes.mode_at(node))

              Finding.new(check: NAME, severity: :error, message: message, node: node)
            end
          rescue Modes::Conflict
            # One drawing routine reached from two screen modes. That error names it, and until it
            # is fixed there is no one screen to judge the call on.
            []
          end

          private

          def message
            "`hide_sprites` cannot work on a bitmap screen. A bitmap screen paints its sprites " \
              "into the picture. So it has no sprite layer that it can hide, and this line does " \
              "nothing. To fix this, use `screen :tiled` here. On a bitmap screen, to hide one " \
              "sprite, call `hide` on that sprite. Then call `show` on it to show it again."
          end
        end
      end
    end
  end
end
