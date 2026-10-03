# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A scene picks its screen AS IT TAKES OVER, and that is read off the top of its block:
        # the console switches the display before the scene's scenery goes up, because changing
        # the kind of screen wipes whatever was up (see IR::SceneHandover). A `screen` anywhere
        # else in a scene — under a test, or in a routine it calls — would change the screen
        # part way through, after the scenery was put up, and the scene would show nothing of
        # it. So it is refused, and the way round it is a scene of its own for the other screen.
        class ScreenInsideScene
          NAME = :screen_inside_scene
          PLAIN_NAME = "a screen change part way through a scene"

          SCENE_PREFIX = "_scene_"

          def detect(program)
            program.each.select { |node| node.kind == :func }.flat_map do |func|
              hidden_screens(func).map do |screen|
                Finding.new(check: NAME, severity: :error, message: message(func, screen), node: screen)
              end
            end
          end

          private

          # The `screen` statements in +func+ that are not at the top of a scene's block.
          def hidden_screens(func)
            on_top = scene?(func) ? func.children.select { |node| node.kind == :screen } : []
            func.walk.select { |node| node.kind == :screen } - on_top
          end

          def scene?(func) = func.name.to_s.start_with?(SCENE_PREFIX)

          def message(func, screen)
            said = "`screen :#{screen.mode}`"
            if scene?(func)
              scene = func.name.to_s.delete_prefix(SCENE_PREFIX)
              "The scene :#{scene} has #{said} inside a test. A scene changes the screen as it takes over, " \
                "before it puts up its scenery. A `screen` that is not at the top of the scene changes the " \
                "screen after that, and the scenery is lost. To fix this, move #{said} to the top of the " \
                "scene :#{scene}. If the game shows another screen, give that screen a scene of its own."
            else
              "The routine :#{func.name} has #{said}. A scene changes the screen as it takes over, before it " \
                "puts up its scenery. A `screen` in a routine changes the screen after that, and the scenery " \
                "is lost. To fix this, move #{said} to the top of the scene that calls :#{func.name}."
            end
          end
        end
      end
    end
  end
end
