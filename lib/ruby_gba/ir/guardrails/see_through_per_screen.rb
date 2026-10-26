# frozen_string_literal: true

require RubyGBA.root.join("lib/ruby_gba/ir/modes").to_s
require RubyGBA.root.join("lib/ruby_gba/ir/stacking").to_s
require RubyGBA.root.join("lib/ruby_gba/ir/see_through").to_s

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
        #
        # A console that blends nothing (Console::Description#blends) has no see-through
        # layer to count: the build refuses the first one (Checks::ConsoleAnswers), and the
        # interpreter, which does not ask that check, refuses none there.
        class SeeThroughPerScreen
          NAME = :see_through_per_screen
          PLAIN_NAME = "two see-through layers on one screen"

          def detect(program)
            return [] unless program.described_console.blends

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
          def refusal_message(program)
            detect(program).first&.message
          end

          private

          def message(both, scene)
            names = both.map { |layer| ":#{layer.name}" }.join(" and ")
            screen = scene ? "The scene :#{Modes.strip_scene_prefix(scene)} shows" : "This game shows"
            "#{screen} two see-through layers, #{names}. The console blends one layer with " \
              "what is behind it, so a screen can have one see-through layer. Each scene can " \
              "have its own. To fix this, make one of the two layers solid, or put each " \
              "see-through layer in a different scene."
          end
        end
      end
    end
  end
end
