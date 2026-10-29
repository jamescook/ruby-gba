# frozen_string_literal: true

module VBlank
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
    #     of the old. What was up is gone, and comes back only by being put up again —
    #     the scenery every screen shows included, which nothing else puts up after
    #     power-on, and the pictures painted from lists that it and the sprites every
    #     screen shows are drawn from (see #always_up).
    #   * A scene that asks for it (`loads_first: true`) spends the pass it takes over on
    #     putting its pictures up, and its own work starts on the pass after (see
    #     Arrival#loads_first?).
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
      #
      # +loads_first+ says the scene's own work waits for the pass after it takes over, which
      # a scene asks for with `loads_first: true`. Putting its pictures up is a copy as big as
      # the pictures are, and on a pass shared with the scene's first pass of game the two
      # together can run past the end of the frame — later the more the scene holds. Asked
      # for, the copy has that pass to itself and the work starts on the next, so the work
      # begins the same number of passes after a hand-over whatever the scene holds: always
      # exactly one. What else the game loop does on that pass, outside the scene, still runs.
      # It is a HAND-OVER's pass: the scene up at power-on was handed over to by nobody, and
      # its copy is part of starting up, so its work starts on the first pass as it would
      # without the word — a game counting frames from power-on has no hand-over it could
      # move to make up a pass. In a program with no game loop there is no pass after, so the
      # scene starts at once.
      #
      # Its +backdrop+ is the colour it shows wherever nothing is drawn: what its own `screen`
      # says, or else what the game's says (#game_backdrop), 0 being black.
      Arrival = Data.define(:scene, :screen, :mode, :scenery, :map_choices, :painted_tiles, :painted_pictures,
                            :takes_down_scenery, :takes_down_art, :loads_first, :backdrop) do
        def takes_down_scenery? = takes_down_scenery
        def takes_down_art? = takes_down_art
        def loads_first? = loads_first
      end

      # WHAT EVERY SCREEN DRAWN FROM TILES SHOWS, to put up again after a screen of another
      # kind replaced the display: the scenery declared in no scene, the runs of tiles it
      # shows that the game paints from lists, and the painted pictures of the sprites
      # declared in no scene — each copied in from its list as it is now.
      #
      # The scenery goes up AS DECLARED, the same as a scene's own: the cells the game changed
      # and the map it chose were in the video memory the other screen has used since, so
      # +map_choices+ go back to the first map.
      AlwaysUp = Data.define(:scenery, :map_choices, :painted_tiles, :painted_pictures)

      def self.of(program) = new(program)

      # Whether handing over from a scene on the +from+ screen to one on the +to+ screen
      # replaces the whole display. The first screen a game puts up replaces nothing.
      def self.crossing?(from, to) = !from.nil? && DISPLAYS.fetch(from) != DISPLAYS.fetch(to)

      # Whether the +screen+ a `screen` names is drawn from tiles, and so shows scenery.
      def self.tiles?(screen) = DISPLAYS.fetch(screen) != DISPLAYS.fetch(:bitmap)

      def initialize(program)
        picture = Stacking.picture(program)
        @scenery = picture.scenery
        @objects = picture.objects
        @tile_runs, @picture_runs = program.walk.select { |node| node.kind == :tile_run }.partition { |run| run.picture.nil? }
        @funcs = program.children.select { |node| node.kind == :func }.to_h { |func| [func.name, func] }
        @game_screen = program.children.find { |node| node.kind == :screen }
        @backdrops = program.walk.any? { |node| node.kind == :screen && node.backdrop }
        @modes = Modes.resolve(program)
        @paced = program.walk.any? { |node| node.kind == :wait_vblank }
        @arrivals = {}
      end

      # The plan for +scene+ taking over.
      def arrival(scene)
        @arrivals[scene] ||= begin
          scenery = @scenery.select { |node| on_arrival?(node) && node.scene == scene }
          pictures = painted_pictures_of(@objects.select { |obj| obj.scene && obj.scene == scene })
          screen = @funcs[scene]&.children&.find { |node| node.kind == :screen }
          tiled = self.class.tiles?(Modes::SCREEN_OF_MODE.fetch(@modes.mode_of(scene)))
          Arrival.new(scene: scene, screen: screen, backdrop: tiled ? screen&.backdrop || game_backdrop : 0,
                      mode: @modes.mode_of(scene), scenery: scenery, map_choices: scenery.flat_map(&:choice),
                      painted_tiles: painted_tiles_of(scenery), painted_pictures: pictures,
                      takes_down_scenery: scenery.empty? && @scenery.any? { |node| on_arrival?(node) },
                      takes_down_art: pictures.empty? && @objects.any? { |obj| obj.scene && painted?(obj) },
                      loads_first: loads_first_in_loop?(@funcs[scene]))
        end
      end

      # THE COLOUR THE GAME SHOWS WHEREVER NOTHING IS DRAWN, as its own `screen` — the one in no
      # scene — says it: 0, black, when it says none. A scene that says no backdrop shows this.
      def game_backdrop = (@game_screen&.backdrop if @game_screen && DISPLAYS.key?(@game_screen.mode)) || 0

      # Does any `screen` say a backdrop? A game where none does shows black wherever nothing is
      # drawn, as every game did before a screen could say one, and a backend emits nothing for it.
      def backdrops? = @backdrops

      # Is +node+ a `screen` naming a kind of screen that a scene says, at the top of its own routine
      # (rather than the game's)? A raw display setting is the author's own register write.
      def scene_screen?(node) = DISPLAYS.key?(node.mode) && !scene_of_screen(node).nil?

      # THE BACKDROP A `screen` STATEMENT MEANS where it is written: at the top of a scene, the
      # scene's (Arrival#backdrop, its own or the game's); anywhere else its own, or the game's
      # where it says none. Black on a painted screen, and on a raw display setting, which names
      # no kind of screen.
      def backdrop_of(node)
        scene = scene_of_screen(node)
        return arrival(scene).backdrop if scene
        return 0 unless DISPLAYS.key?(node.mode) && self.class.tiles?(node.mode)

        node.backdrop || game_backdrop
      end

      # The scene whose routine says +node+ at its top, or nil — a scene, and not any other routine.
      def scene_of_screen(node)
        @funcs.find { |name, func| Modes.scene_func?(name) && func.children.any? { |child| child.equal?(node) } }&.first
      end

      # Every scene's own `screen` line, by the scene's routine.
      def scene_screens
        @funcs.filter_map do |name, func|
          screen = func.children.find { |node| node.kind == :screen }
          [name, screen] if Modes.scene_func?(name) && screen
        end
      end

      # Whether any scene loads first.
      def any_loads_first? = @funcs.each_value.any? { |func| loads_first_in_loop?(func) }

      # What to put up again on arriving at a screen drawn from tiles from a screen of another
      # kind (see AlwaysUp).
      def always_up
        @always_up ||= begin
          scenery = @scenery.select { |node| node.scene.nil? }
          AlwaysUp.new(scenery: scenery, map_choices: scenery.flat_map(&:choice),
                       painted_tiles: painted_tiles_of(scenery), painted_pictures: painted_pictures_of(@objects.reject(&:scene)))
        end
      end

      # The scenery on screen while +scene+ runs: what every screen shows, and its own.
      def showing(scene) = @scenery.select { |node| node.scene.nil? || node.scene == scene }

      # Whether +background+ goes up as its scene takes over, rather than where it is written.
      # Only scenery drawn from tiles is up in that sense: a scene on a painted screen paints
      # its background into the one picture where the statement is written, like any drawing.
      def on_arrival?(background) = !background.scene.nil? && drawn_from_tiles?(background.scene)

      private

      # Whether +func+ asked to load first, in a program with a game loop to give it a pass after.
      def loads_first_in_loop?(func) = @paced && func&.loads_first == true

      def drawn_from_tiles?(scene) = self.class.tiles?(Modes::SCREEN_OF_MODE.fetch(@modes.mode_of(scene)))

      # The runs of tiles painted from lists that +scenery+ shows.
      def painted_tiles_of(scenery) = @tile_runs.select { |run| scenery.any? { |bg| bg.tiles.intersect?(run.tiles) } }

      # The painted pictures +objects+ show in any of their poses.
      def painted_pictures_of(objects)
        poses = objects.flat_map(&:poses)
        @picture_runs.select { |run| poses.include?(run.picture) }
      end

      def painted?(obj) = @picture_runs.any? { |run| obj.poses.include?(run.picture) }
    end
  end
end
