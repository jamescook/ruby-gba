# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A game that fades the screen AND sees through a layer.
        #
        # Both are the display's one blend unit, and it is told which of the two it is
        # doing. So while a fade runs the see-through layer is solid — it darkens with the
        # rest of the picture, which is what a fade out is supposed to look like, and the
        # layer comes back the moment the fade lifts.
        #
        # Neither half of that is visible from the code. The verbs are written in different
        # places, often in different files, and nothing about `fade_out` says it reaches a
        # layer somebody else declared. The picture during the fade is the only clue, and a
        # fade is over in half a second.
        #
        # This is information rather than a mistake, which is why it warns and offers the
        # way round instead of refusing: a tint moves the picture toward a color by another
        # route entirely, so `flash_screen :red` leaves the layer blending.
        class LayerSolidWhileFading
          NAME = :layer_solid_while_fading

          def detect(program)
            layers = program.each.find { |n| n.kind == :layers && blends?(n) }
            return [] unless layers

            fade = program.each.find { |n| n.kind == :fade }
            return [] unless fade

            [Finding.new(check: NAME, severity: :warning, message: message(layers.transparent), node: fade)]
          end

          private

          # Is there anything for a fade to take? A layer fixed at 0 is solid already; one
          # the game works out is asked about, since it is not 0 for long if it is worth
          # writing.
          def blends?(node)
            return false unless node.transparency

            fixed = Value.fixed_number(node.transparency)
            fixed.nil? || fixed.positive?
          end

          def message(layer)
            "This game fades the screen, and it can see through the layer :#{layer}. A " \
              "fade and a see-through layer use the same part of the display, and the " \
              "display does one of them at a time. While a fade runs, :#{layer} is solid " \
              "and darkens with the rest of the picture. The layer comes back when the " \
              "fade lifts. To keep :#{layer} see-through during an effect, use `tint` or " \
              "`flash_screen :red`, which the console mixes in a different way."
          end
        end
      end
    end
  end
end
