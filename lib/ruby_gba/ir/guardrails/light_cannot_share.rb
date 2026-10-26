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
        #
        # A SEE-THROUGH LAYER OR A PLACED FADE IN ANOTHER SCENE IS NOT EITHER. The display is
        # told what to mix afresh every frame, and a game is in one scene at a time, so the
        # light is off in such a scene and on in the rest (see IR::LightScenes). What is
        # refused is one scene with both, or a game with no scenes, which is one screen.
        #
        # A console that blends nothing (Console::Description#blends) has no light to share:
        # Checks::ConsoleAnswers refuses the light itself.
        class LightCannotShare
          NAME = :light_cannot_share
          PLAIN_NAME = "a light beside something that needs the same part of the display"

          # How the game came to have a light, said the way the author wrote it: an iris gives
          # a game a light as well as `spotlight` does.
          LIGHT = "a light (a `spotlight` or an `iris_out`)"

          def detect(program)
            return [] unless program.described_console.blends

            light = LightScenes.light_of(program)
            return [] unless light

            sharing = LightScenes.scenes(program).empty? ? one_screen_sharing(program) : scenes_sharing(program)
            [*sharing, untiled_screen(program), no_frames(program)]
              .compact.map { |message| Finding.new(check: NAME, severity: :error, node: light, message: message) }
          end

          private

          # A game with no scenes is one screen, and the light is on all of it.
          def one_screen_sharing(program)
            layer = SeeThrough.layers(program).first
            fade = program.walk.find { |node| LightScenes.placed_fade?(node) }
            [layer && see_through_message(layer, nil), fade && placed_fade_message(fade, nil)]
          end

          # Each scene that moves the light and is one the light is off in, and a fade placed by
          # code outside every scene, which is in force in all of them.
          def scenes_sharing(program)
            scenes = LightScenes.dark_scenes_moving_light(program).map do |routine, why|
              scene = routine.to_s.delete_prefix(ScreenInsideScene::SCENE_PREFIX)
              why.kind == :fade ? placed_fade_message(why, scene) : see_through_message(why, scene)
            end
            fade = LightScenes.placed_fade_outside_scenes(program)
            fade ? scenes + [placed_fade_message(fade, nil)] : scenes
          end

          def see_through_message(layer, scene)
            where = scene ? "in the scene :#{scene}, which uses the light, " : ""
            fix = scene ? "use the light in a scene that sees through no layer, or " : ""
            "This game has #{LIGHT}, and #{where}the layer :#{layer.name} is see-through. Both use the one " \
              "part of the console that mixes the picture, and that part can do one of the two at a time. " \
              "To fix this, #{fix}remove `transparency:` (or `shows:`) from :#{layer.name}, or remove the light."
          end

          def placed_fade_message(fade, scene)
            who = scene ? "the scene :#{scene}, which uses the light," : "it"
            fix = scene ? "use the light in a scene that fades under no layer, or " : ""
            "This game has #{LIGHT}, and #{who} fades under the layer :#{fade.under}. A fade placed in " \
              "the stack and a light both use the console's one darkening. To fix this, #{fix}fade the " \
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
