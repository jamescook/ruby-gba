# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A fade held to a rectangle beside something it cannot share the display with.
        #
        # A held fade is the display's darkening, switched on in one part of its first window
        # and off in the other, with that window on for the whole game (see
        # GBA::ScreenEffects#emit_fade_window). A light wants the same window cut into a
        # circle a row at a time; a see-through layer wants the blend unit the darkening is;
        # and a fade placed in the stack wants the window's other regions to say which sprites
        # it leaves alone. Each looks right where it is written, so it is refused here, naming
        # both halves.
        #
        # A plain fade and a tint are NOT among them: in a game that holds a fade, each of those
        # says it reaches the whole screen, and the last one said is the one in force.
        #
        # A console that blends nothing (Console::Description#blends) holds no fade to a
        # rectangle: Checks::ConsoleAnswers refuses the held fade itself.
        class HeldFadeCannotShare
          NAME = :held_fade_cannot_share
          PLAIN_NAME = "a fade held to a rectangle beside something that needs the same part of the display"

          def detect(program)
            return [] unless program.described_console.blends

            held = program.walk.find { |node| node.kind == :fade && node.reaches } or return []

            words = "fades `#{held.reaches}:` a rectangle"
            [light(program, words), see_through(program, words), placed_fade(program, words)]
              .compact.map { |message| Finding.new(check: NAME, severity: :error, node: held, message: message) }
          end

          private

          def light(program, words)
            return nil unless program.walk.any? { |node| node.kind == :shade_outside }

            "This game #{words}, and it has a light (a `spotlight` or an `iris_out`). The console has " \
              "one window for both, and a light cuts it into a circle. To fix this, remove `inside:` " \
              "or `outside:` from the fade, or remove the light."
          end

          def see_through(program, words)
            layer = SeeThrough.layers(program).first or return nil

            "This game #{words}, and the layer :#{layer.name} is see-through. Both use the one part " \
              "of the console that mixes the picture, and it can do one of the two. To fix this, " \
              "remove `transparency:` (or `shows:`) from :#{layer.name}, or remove `inside:` or " \
              "`outside:` from the fade."
          end

          def placed_fade(program, words)
            fade = program.walk.find { |node| node.kind == :fade && node.under } or return nil

            "This game #{words}, and it fades under the layer :#{fade.under}. Both need the console's " \
              "windows, and they need them set two different ways. To fix this, remove " \
              "`under: :#{fade.under}`, or remove `inside:` and `outside:` from every fade."
          end
        end
      end
    end
  end
end
