# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A layer made so see-through that it cannot be seen.
        #
        # `transparency: 100` says none of the layer shows and all of what is behind it
        # does — which is the same picture as not declaring the layer at all, except that
        # the game still holds its art, its tiles and (for scenery) one of the console's
        # four levels of depth. Nothing crashes and nothing looks broken; the layer is
        # simply not there, which is hard to spot when the thing behind it is drawn.
        #
        # Almost always a slider walked the wrong way: 0 is solid and 100 is invisible,
        # and the two are easy to swap the first time.
        class LayerInvisible
          NAME = :layer_invisible

          # The amount at which nothing of the layer survives. Below it something does,
          # and a very faint layer is a style choice rather than a mistake.
          INVISIBLE = 100

          def detect(program)
            node = program.each.find { |n| n.kind == :layers && n.transparency == INVISIBLE }
            return [] unless node

            [Finding.new(check: NAME, severity: :warning, message: message(node.transparent), node: node)]
          end

          private

          def message(layer)
            "The layer :#{layer} is 100 see-through, so none of it shows. The game still " \
              "draws it and still holds its art. To fix this, use a smaller number — 0 is " \
              "solid and 100 is invisible — or remove the layer."
          end
        end
      end
    end
  end
end
