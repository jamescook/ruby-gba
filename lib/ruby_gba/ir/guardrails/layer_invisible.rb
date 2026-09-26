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
          PLAIN_NAME = "a layer too see-through to see"

          # Nothing is said about an amount the game works out — the same silence
          # FadeNeverLifted and TintNeverLifted keep, and for the same reason: a variable
          # that reaches 100 for one frame of a thickening fog is the effect working.
          #
          # What counts is what the display is told — no share of the layer at all — so a
          # `shows:` small enough to round to nothing is said too. A very faint layer is a
          # style choice rather than a mistake, and is left alone.
          def detect(program)
            layer = SeeThrough.layers(program).find { |node| invisible?(node) }
            return [] unless layer

            [Finding.new(check: NAME, severity: :warning, message: message(layer), node: layer)]
          end

          private

          def invisible?(layer)
            shows = DSL::Value.fixed_number(layer.shows)
            behind = DSL::Value.fixed_number(layer.behind)
            return false if shows.nil? || behind.nil?

            SeeThrough.weights(layer, shows, behind).first.zero?
          end

          def message(layer)
            if layer.split
              return "The layer :#{layer.name} is 100 see-through, so none of it shows. The game still " \
                     "draws it and still holds its art. To fix this, use a smaller number — 0 is " \
                     "solid and 100 is invisible — or remove the layer."
            end

            "The layer :#{layer.name} shows #{DSL::Value.fixed_number(layer.shows)} of itself. That " \
              "rounds to nothing, so none of the layer shows. The game still draws it and still " \
              "holds its art. To fix this, use a bigger `shows:`, or remove the layer. 0 is none " \
              "of the layer and 100 is all of it."
          end
        end
      end
    end
  end
end
