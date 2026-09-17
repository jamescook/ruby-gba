# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A game that PLACES a fade in the stack AND sees through a layer.
        #
        # A fade over the whole screen used to be here too, and is not any more: that one
        # moves the colors themselves rather than asking the display to blend, so the
        # layer goes on showing what is behind it and the whole picture darkens together
        # (see IR::Fading for both mechanisms and which fade gets which).
        #
        # A fade PLACED in the stack cannot take that route. Being placed is the one thing
        # only the blend unit can do — the console hides a brightness change from the
        # layers in front of a line, where a table of colors is read by everything that
        # draws and has no notion of who is reading it. So this fade does take the layer's
        # blend, the layer is solid while it runs, and it comes back the moment the fade
        # lifts.
        #
        # None of that is visible from the code. The verbs are written in different
        # places, often in different files, and nothing about `fade_out under: :ui` says
        # it reaches a layer somebody else declared. The picture during the fade is the
        # only clue, and a fade is over in half a second.
        #
        # This is information rather than a mistake, which is why it warns and offers the
        # way round instead of refusing: the same fade with no `under:` keeps the layer.
        class LayerSolidWhileFading
          NAME = :layer_solid_while_fading
          PLAIN_NAME = "a see-through layer while a placed fade runs"

          def detect(program)
            layers = program.each.find { |n| n.kind == :layers && IR::Fading.can_be_seen_through?(n) }
            return [] unless layers

            fade = IR::Fading.resolve(program).blend_fades.first
            return [] unless fade

            [Finding.new(check: NAME, severity: :warning, node: fade,
                         message: message(layers.transparent, fade.under))]
          end

          private

          def message(layer, under)
            "This game fades the screen under the layer :#{under}, and it can see through " \
              "the layer :#{layer}. A fade placed in the stack and a see-through layer use " \
              "the same part of the display. The display does one of them at a time. " \
              "While the fade runs, :#{layer} is solid and darkens with the rest of the " \
              "picture. The layer comes back when the fade lifts. To keep :#{layer} " \
              "see-through, fade the whole screen. A fade with no `under:` moves the " \
              "colors instead, and it leaves the layer alone."
          end
        end
      end
    end
  end
end
