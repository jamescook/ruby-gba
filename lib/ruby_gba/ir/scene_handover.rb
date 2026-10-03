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
    #   * A run of tiles the game paints from a list (`tiles ..., from: list`) goes up showing
    #     what its list holds AT THAT MOMENT, as if the game had said `changed`. There is
    #     nowhere else it could come from: the scene before has used the same video memory
    #     for its own scenery, and the list is the only place the pixels are kept.
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

      # WHAT ONE SCENE PUTS UP AS IT TAKES OVER, as plain data, for a backend to carry out.
      #
      # +screen+ is the `screen` the scene declares, or nil for one that draws on the screen it
      # was reached on: the display changes first, since changing its kind wipes whatever was
      # put up before it. +mode+ is the screen it draws on either way, as IR::Modes names it.
      # Whether that CHANGES the kind of screen depends on the scene before, so a backend asks
      # that as the scene arrives (see .crossing?). +scenery+ is its own backgrounds, in the order the stack draws them;
      # +map_choices+ the variables saying which map each shows, put back to the first;
      # +painted_tiles+ the runs of tiles that scenery shows, and +painted_pictures+ the
      # pictures its sprites show, each copied in from its list. The last two flags are for a
      # scene with none of its own: the last scene's scenery or painted pictures still come
      # down, and a backend that only keeps note of whose are up has to be told.
      Arrival = Data.define(:scene, :screen, :mode, :scenery, :map_choices, :painted_tiles, :painted_pictures,
                            :takes_down_scenery, :takes_down_art) do
        def takes_down_scenery? = takes_down_scenery
        def takes_down_art? = takes_down_art
      end

      def self.of(program) = new(program)

      # Whether handing over from a scene on the +from+ screen to one on the +to+ screen
      # replaces the whole display. The first screen a game puts up replaces nothing.
      def self.crossing?(from, to) = !from.nil? && DISPLAYS.fetch(from) != DISPLAYS.fetch(to)

      def initialize(program)
        picture = Stacking.picture(program)
        @scenery = picture.scenery
        @objects = picture.objects
        @tile_runs, @picture_runs = program.walk.select { |node| node.kind == :tile_run }.partition { |run| run.picture.nil? }
        @funcs = program.children.select { |node| node.kind == :func }.to_h { |func| [func.name, func] }
        @modes = Modes.resolve(program)
        @arrivals = {}
      end

      # The plan for +scene+ taking over.
      def arrival(scene)
        @arrivals[scene] ||= begin
          scenery = @scenery.select { |node| on_arrival?(node) && node.scene == scene }
          pictures = painted_pictures_of(scene)
          Arrival.new(scene: scene, screen: @funcs[scene]&.children&.find { |node| node.kind == :screen },
                      mode: @modes.mode_of(scene), scenery: scenery, map_choices: scenery.flat_map(&:choice),
                      painted_tiles: @tile_runs.select { |run| scenery.any? { |bg| bg.tiles.intersect?(run.tiles) } },
                      painted_pictures: pictures,
                      takes_down_scenery: scenery.empty? && @scenery.any? { |node| on_arrival?(node) },
                      takes_down_art: pictures.empty? && @objects.any? { |obj| obj.scene && painted?(obj) })
        end
      end

      # The scenery on screen while +scene+ runs: what every screen shows, and its own.
      def showing(scene) = @scenery.select { |node| node.scene.nil? || node.scene == scene }

      # Whether +background+ goes up as its scene takes over, rather than where it is written.
      # Only scenery drawn from tiles is up in that sense: a scene on a painted screen paints
      # its background into the one picture where the statement is written, like any drawing.
      def on_arrival?(background) = !background.scene.nil? && drawn_from_tiles?(background.scene)

      private

      def drawn_from_tiles?(scene) = [Modes::TILED, Modes::AFFINE].include?(@modes.mode_of(scene))

      # The painted pictures a sprite of +scene+ shows in any of its poses.
      def painted_pictures_of(scene)
        poses = @objects.select { |obj| obj.scene && obj.scene == scene }.flat_map(&:poses)
        @picture_runs.select { |run| poses.include?(run.picture) }
      end

      def painted?(obj) = @picture_runs.any? { |run| obj.poses.include?(run.picture) }
    end
  end
end
