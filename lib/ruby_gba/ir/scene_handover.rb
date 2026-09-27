# frozen_string_literal: true

module RubyGBA
  module IR
    # WHAT A SCENE DOES TO THE SCREEN AS IT TAKES OVER.
    #
    # A scene owns the scenery declared inside it: its backgrounds are on screen while it is
    # the active state and not otherwise. That is what lets scenes take turns with the few
    # layers a display has (see Stacking#screenfuls). Handing the screen from one scene to
    # the next is therefore a handful of rules, and every backend has to keep all of them —
    # the interpreter by painting its fake screen, the lowering by telling the console — so
    # they are said here, once, and each backend carries them out.
    #
    #   * The scenery every screen shows (a background declared in no scene) stays up
    #     throughout. Nothing hands it over.
    #   * A scene's own scenery goes up AS IT TAKES OVER, once, and not where its
    #     `background` statement is written. That statement sits in the scene's own
    #     routine, which runs every frame the scene is active, and putting a background up
    #     again puts it back exactly as declared — throwing away the scroll the game had
    #     asked for and every cell it had changed.
    #   * It goes up AS DECLARED each time: a cell changed with set_tile, or a map chosen
    #     with show_map, is left behind with the visit that changed it, and what says which
    #     map is showing goes back to the first. A game that remembers an opened door opens
    #     it again on the way in.
    #   * The scene before's own scenery comes down, or it would show through wherever this
    #     scene's has a hole — whether or not this scene has any scenery of its own.
    #   * Handing over from one KIND of screen to another replaces the whole display: a
    #     painted picture, one drawn from tiles and one that turns share the same video
    #     memory in ways that cannot coexist, so the console shows the new one and nothing
    #     of the old. What was up is gone, and comes back only by being put up again.
    class SceneHandover
      # Each kind of screen a `screen` names, and the kind of display it is. Two screens of
      # the same kind share a display; two kinds cannot.
      DISPLAYS = { bitmap: :painted, tiled: :tiles, rotozoom: :turning }.freeze

      def self.of(picture) = new(picture)

      # Whether handing over from a scene on the +from+ screen to one on the +to+ screen
      # replaces the whole display. The first screen a game puts up replaces nothing.
      def self.crossing?(from, to) = !from.nil? && DISPLAYS.fetch(from) != DISPLAYS.fetch(to)

      def initialize(picture)
        @scenery = picture.scenery
      end

      # The backgrounds +scene+ puts up as it takes over, in the order the stack draws them.
      def arriving(scene) = @scenery.select { |node| node.scene && node.scene == scene }

      # The scenery on screen while +scene+ runs: what every screen shows, and its own.
      def showing(scene) = @scenery.select { |node| node.scene.nil? || node.scene == scene }

      # Whether +background+ goes up as its scene takes over, rather than where it is written.
      def on_arrival?(background) = !background.scene.nil?

      # The variables that say which map a background is showing, put back to its first as
      # +scene+ takes over.
      def resets(scene) = arriving(scene).flat_map(&:choice)
    end
  end
end
