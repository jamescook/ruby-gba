# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A light beside something it cannot share the display with.
        #
        # A light is two things the display has one of each: its darkening, which it holds
        # for the whole game, and its first window, cut a row at a time into the shape of a
        # circle. So a game that also asks the display's blend for something else, or that
        # draws a screen where there are no layers to cut a window in, is asking for two
        # answers from one register. Nothing at either call site says so — each looks right
        # where it is written — so it is refused here, naming both halves.
        #
        # A plain fade is NOT among them: a game with a light fades by walking its colours,
        # so the two are both in force (see IR::Fading).
        class LightCannotShare
          NAME = :light_cannot_share
          PLAIN_NAME = "a light beside something that needs the same part of the display"

          # How the game came to have a light, said the way the author wrote it: an iris gives
          # a game a light as well as `spotlight` does.
          LIGHT = "a light (a `spotlight` or an `iris_out`)"

          def detect(program)
            light = program.walk.find { |node| node.kind == :shade_outside }
            return [] unless light

            [see_through(program), placed_fade(program), untiled_screen(program), no_frames(program)]
              .compact.map { |message| Finding.new(check: NAME, severity: :error, node: light, message: message) }
          end

          private

          def see_through(program)
            layer = SeeThrough.layers(program).first or return nil

            "This game has #{LIGHT}, and the layer :#{layer.name} is see-through. Both use the one " \
              "part of the console that mixes the picture, and it can do one of the two. To fix this, " \
              "remove `transparency:` (or `shows:`) from :#{layer.name}, or remove the light."
          end

          def placed_fade(program)
            fade = program.walk.find { |node| node.kind == :fade && node.under } or return nil

            "This game has #{LIGHT}, and it fades under the layer :#{fade.under}. A fade placed in " \
              "the stack and a light both use the console's one darkening. To fix this, fade the " \
              "whole screen: remove `under: :#{fade.under}`."
          end

          # A screen that is not `screen :tiled` anywhere in the game: the light's darkening
          # stands for the whole game, and on such a screen it reaches the whole picture.
          def untiled_screen(program)
            screen = program.walk.find { |node| node.kind == :screen && node.mode != :tiled } or return nil

            "This game has #{LIGHT}, and it shows a `screen :#{screen.mode}`. On that screen the " \
              "light's window is not switched on, so the whole screen would go dark. To fix this, " \
              "use `screen :tiled` for every screen of a game with a light."
          end

          def no_frames(program)
            return nil if program.walk.any? { |node| node.kind == :wait_vblank }

            "This game has #{LIGHT}, but it has no `game_loop`. The light is worked out again " \
              "before each frame, so with no frames it is never drawn. To fix this, put the game in " \
              "a `game_loop`."
          end
        end
      end
    end
  end
end
