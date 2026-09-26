# frozen_string_literal: true

require_relative "../modes"
require_relative "../stacking"
require_relative "../see_through"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # TWO SEE-THROUGH LAYERS ON ONE SCREEN.
        #
        # The console blends ONE layer with what is behind it, so a screen has one
        # see-through layer. A game can have several — a title whose light rays shimmer,
        # and a menu whose window glows over its backdrop — as long as no screen shows
        # two of them.
        #
        # There is a second reason, and it is why this is refused rather than left to
        # draw what it draws: where one see-through layer sits directly over another, the
        # console blends only the top two things at a pixel, and the reference interpreter
        # paints back to front and would blend all three. The two would draw different
        # pictures and neither would be wrong about what was asked.
        #
        # Which screen a thing is on is known only once the whole game is built — a scene
        # is a screen, and what is declared outside every scene is on all of them — so this
        # is a check of the finished program. The interpreter and the cartridge lowering ask
        # it too, so all three refuse the same programs in the same words.
        class SeeThroughPerScreen
          NAME = :see_through_per_screen
          PLAIN_NAME = "two see-through layers on one screen"

          def detect(program)
            layers = SeeThrough.layers(program)
            return [] if layers.size < 2

            Stacking.screenfuls(program).each do |screenful|
              both = SeeThrough.on_screen(screenful, layers)
              next if both.size < 2

              return [Finding.new(check: NAME, severity: :error, node: both[1], message: message(both, screenful.scene))]
            end
            []
          rescue Modes::Conflict
            # One drawing routine reached from two screens. That error names it, and until
            # it is fixed there is no telling which screen a layer is on.
            []
          end

          # Why the layers are refused, or nil when each screen has one at most.
          def refusal(program)
            detect(program).first&.message
          end

          private

          def message(both, scene)
            names = both.map { |layer| ":#{layer.name}" }.join(" and ")
            screen = scene ? "The scene :#{Modes.friendly_name(scene)} shows" : "This game shows"
            "#{screen} two see-through layers, #{names}. The console blends one layer with " \
              "what is behind it, so a screen can have one see-through layer. Each scene can " \
              "have its own. To fix this, make one of the layers solid on this screen, or " \
              "put each see-through layer in a scene of its own."
          end
        end
      end
    end
  end
end
