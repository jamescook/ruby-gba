# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # WHERE EVERYTHING THE CONSOLE DRAWS FOR YOU GOES, worked out once from the program
        # before a single instruction is emitted.
        #
        # A tiled screen is not painted by the game. The console composes it on its own,
        # every frame, out of things set up in its video memory: up to four background
        # layers, each a grid of references to 8x8 tiles, and a table of 128 sprites, each
        # pointing at pictures kept in 32K of sprite memory. Both are fixed, small budgets,
        # and deciding who gets what is the whole job here:
        #
        #   * which of the four layers each background uses, per screen (a scene that
        #     takes over can reuse the layers the last one had);
        #   * how every tile is stored — half a byte a pixel when it draws from sixteen
        #     colours or fewer, a byte otherwise — and which group of sixteen it reads;
        #   * where each layer's tiles and map land in video memory;
        #   * how each sprite's pictures are cut into rectangles the console can draw, where
        #     they sit in sprite memory, and which slots in the table each sprite takes.
        #
        # What comes back is a finished plan plus the cartridge data it needs (the colour
        # tables, the tile pictures, the maps). Nothing here emits code, so the plan can be
        # asked about directly — which layer a background landed on, how a sprite was cut
        # up — without building a cartridge or running one. The code generator reads the
        # plan; a mistake in the plan is a mistake here and nowhere else.
        #
        # A program that breaks one of the budgets is refused with a friendly error naming
        # what did not fit, raised as the plan is made.
        class ScreenLayout
          include Console::Hardware

          # A background, once given hardware to live in: where its map sits, which of the
          # console's layers draws it, and how far forward that layer is. +affine+ marks a
          # `screen :rotozoom` background — its map is one byte per cell (a plain tile
          # number, no flip bits), and it lives on the console's rotate/scale layer (BG2)
          # rather than a plain scrolling one. +small+ marks a layer whose tiles are stored
          # half a byte a pixel, each naming its own bank of sixteen colors — worked out
          # from the colors in its art, never asked for. +size+ is the grid it scrolls over,
          # already shifted into place for the layer's own settings.
          # +char_base+ is which of the four 16K places this layer counts its tile numbers
          # from, so two layers can each name a full run of tiles out of different parts of
          # the same memory.
          # +map_count+ is how many maps this background can be handed and +map_bytes+ how far
          # apart two of them sit in that blob: they are all the same size and laid end to
          # end, so the map numbered N starts N of these along. A background declared with one
          # map counts 1 and has nothing to step to.
          BackgroundPlacement = Data.define(:map, :map_units, :bg, :screen_block, :size,
                                            :priority, :affine, :small, :char_base,
                                            :map_count, :map_bytes, :grid, :colors)

          # THE OTHER LISTS OF COLOURS A LAYER CAN BE DRAWN FROM, for a background that was
          # told `draw_with`, and nil for every other one.
          #
          # +blob+ holds them end to end in the cartridge, a whole bank of sixteen for each list
          # and the layer's OWN colours last — so picking one is arithmetic on a number rather
          # than a test per list, and a number naming none of them can be answered by handing
          # over the last one instead of by branching around the write.
          #
          # A layer's tiles can be drawn from several lists, each in a group of sixteen of its
          # own, and then one version of the layer is a list for EACH: those sit side by side
          # in the blob, one version after another. +banks+ is the group each of the layer's
          # lists is in, in that order, which the swap writes into; +shift+ is how far apart two
          # versions are, as a power of two, so finding one is a shift rather than a multiply —
          # three lists take the room of four. +count+ is how many versions there are besides
          # its own. +at+ names the variable holding where the version it is showing NOW starts,
          # which is what lets a tint put the swap back after walking the whole table over it.
          BackgroundColorLists = Data.define(:blob, :banks, :count, :at, :shift)

          # A BACKGROUND'S GRID OF CELLS, for changing one of them while the game runs: how many
          # cells there are each way, and what to write into one to show a given tile. Nothing
          # else needs either, and a background that turns and resizes has no grid of this shape
          # at all — its cells hold a tile number and nothing else, so it is nil there.
          MapGrid = Data.define(:cols, :rows, :cells) do
            def holds?(col, row) = col >= 0 && col < cols && row >= 0 && row < rows
            def cell_for(tile) = cells.fetch(tile)
          end

          # WHAT ONE SCENE NEEDS OF THE TILED SCREEN: which layers are switched on, and which
          # of the console's two arrangements this screen is — four layers that scroll, or two
          # that scroll beside one that turns and resizes.
          SceneScreen = Data.define(:on, :turning)

          # WHAT ONE SCENE SENDS AS IT TAKES OVER, in one place: its own tile pictures (a
          # SceneTiles, or nil), the screen it has on (a SceneScreen, for a tiled scene), its
          # own sprite pictures (blob, at, units for each), and the blob of its sprite colour
          # table (or nil). Each pass that decides one of these fills in its part.
          #
          # +art+ is nil for a scene that owns no sprites, and a list — empty when there is
          # nothing to copy — for one that does, since a scene whose sprites keep one frame at
          # a time still marks its pictures as up (see Drawing#emit_scene_art_upload).
          SceneSend = Data.define(:tiles, :screen, :art, :obj_palette)
          NOTHING_SENT = Ractor.make_shareable(SceneSend.new(tiles: nil, screen: nil, art: nil, obj_palette: nil))

          AFFINE_MAX_TILES = 256

          # The console keeps four levels of depth, and a picture can ask for more of them
          # than that. Say so in the author's own layer names — the number this refuses is
          # a hardware fact, but "BG2" is not a thing anybody wrote.
          #
          # There are only two ways to run out, so the message names the one that happened
          # rather than listing both: too much scenery, or a layer of sprites sitting
          # behind every piece of it (which needs a level of its own, above the lot).
          MAX_LEVELS = 4

          # Sprite tile memory: 32KB, holding all the sprites' tile pictures at once.
          OBJ_TILE_CAPACITY = 0x8000

          # Turning sprites (see ScreenLayout#prepare_affine). The console applies a rotation to a
          # sprite through one of 32 shared "affine" parameter groups, so at most 32
          # sprites can turn at once. To rotate, a sprite points at a group; each frame we
          # fill that group with a rotation matrix built from the angle.
          MAX_AFFINE_GROUPS = 32

          # Where a sprite's banks are kept, and which entry is its own colours.
          RecolorBanks = Data.define(:table, :own)

          # EVERYTHING THAT CHANGES BETWEEN POSES THAT ARE NOT INTERCHANGEABLE, one word
          # each, read by the per-frame draw.
          #
          # A uniform sprite needs none of this: its size is the same every frame, so it
          # sits in the sprite's own entry and the pose is a stride. Once the poses differ
          # in size, four things move with the pose — which tiles, what shape, what size,
          # and how far along to draw it so the picture does not shift. A pose that is
          # another one MIRRORED breaks the stride too, since its tiles are the pose it
          # mirrors, and adds a fifth. All five fit in one word: one read a frame and some
          # shifting, against storing every pose at the biggest one's size and every mirror
          # a second time.
          #
          #   bits  0..9   the piece's first tile
          #        10..11  shape          12..13  size
          #        14..21  how far right   22..29  how far down (both a whole number of tiles)
          #           30   draw it mirrored
          #
          # ONE WORD PER PIECE PER POSE, laid out PIECE FIRST: a picture too big for one
          # object is drawn as several, and each of them reads its own row of this. Piece
          # first is what keeps the read cheap — the game's pose number is scaled by four and
          # the piece's row is a constant the build already knows, so a piece costs the same
          # one read whether it is the first or the fourth.
          POSE_MIRRORED = 1 << 30

          # Plan the screen for +program+. Everything it needs is worked out from the
          # program itself; a caller that has already collected the pictures or resolved the
          # display modes can pass them in rather than have them worked out twice. How the
          # picture stacks is always worked out here, so there is one answer to it.
          def self.plan(program, bitmaps: nil, modes: nil)
            new(program, bitmaps: bitmaps || bitmaps_of(program), modes: modes || IR::Modes.resolve(program))
          end

          # Every picture the program declares, by name — and each tile of a run the game paints
          # from a list, as the blank picture it is until the first copy, drawn from the run's
          # own colours so it gets a bank of sixteen like any tile with a list of its own.
          def self.bitmaps_of(program)
            pictures = program.walk.select { |node| node.kind == :bitmap }.to_h { |node| [node.name, Assets::Image.of(node)] }
            program.walk.select { |node| node.kind == :tile_run }.each { |run| pictures.merge!(painted_tile_pictures(run)) }
            pictures
          end

          # A run's tiles, or the one picture a sprite shows, each blank until the first copy.
          def self.painted_tile_pictures(run)
            return { run.picture => blank_picture(run.width, run.height, run.colors) } if run.picture

            blank = blank_picture(TILE_PX, TILE_PX, run.colors)
            run.tiles.to_h { |tile| [tile, blank] }
          end

          def self.blank_picture(width, height, colors)
            Assets::Image.new(width: width, height: height, transparent: Graphics::Image::TRANSPARENT,
                              pixels: ([Graphics::Image::TRANSPARENT] * (width * height)).pack("v*"),
                              colors: colors, places: ("\x00" * (width * height)).b)
          end

          # Does this sprite turn or change size? It does unless BOTH its angle and its size
          # are still the constants they default to. Either one being a variable (or any
          # other constant) means it goes through one of the console's rotation groups; both
          # at their defaults draws upright at its drawn size, for free.
          def self.transformed?(node) = rotates?(node) || scales?(node)

          def self.rotates?(node)
            value = const_int(node.angle)
            value.nil? || !value.zero?
          end

          def self.scales?(node) = const_int(node.scale) != Build::SCALE_ONE

          # A number settled while the program was built, or nil for one worked out as it runs.
          def self.const_int(node) = Primitives.const_int(node)

          def initialize(program, bitmaps:, modes:)
            @bitmaps = bitmaps
            @modes = modes
            # How the picture stacks: which scenery and sprites there are, in what order, and
            # how deep each sits — and the same picture cut into what can be on screen AT ONCE,
            # which is what the console's four layers and four depths actually have to cover.
            @picture = IR::Stacking.picture(program)
            @screenfuls = IR::Stacking.screenfuls(program)
            @blobs = {}           # cartridge data by name: colour tables, tile pictures, maps
            @codecs = {}          # names of the data that must stay unpacked in the cartridge
            @backgrounds = {}     # name -> where a background landed (see #prepare_one_background)
            @hardware_layers = {} # name -> which of the console's layers it uses
            @bg_shared = nil      # the one colour table and tile run every layer shares
            @objects = {}         # name -> where a sprite landed (see #object_record)
            @obj_pictures = {}    # name -> its pictures, cut and encoded
            @scene_sends = {}     # scene -> what it sends as it takes over (see SceneSend)
            @placed_fade = PlacedFade.new(@picture, program)
            # Each tile the game paints from a list, by its picture's name -> its run; and
            # where each run landed in video memory (see #note_painted_runs).
            runs = program.walk.select { |node| node.kind == :tile_run }
            @painted_runs = runs.flat_map { |run| run.tiles.map { |tile| [tile, run] } }.to_h
            # ...and each picture a sprite shows that is painted the same way, by its name.
            @painted_pictures = runs.select(&:picture).to_h { |run| [run.picture, run] }
            @painted_vram = {}
            @handover = IR::SceneHandover.of(program) # what each scene puts up as it takes over
            @see_through = IR::SeeThrough.layers(program).map(&:name) # the layers a sprite blends in
            if Modes.draws_with_tiles?(program)
              check_stack_depth_fits!
              prepare_backgrounds(program)
            end
            prepare_objects(program) if program.walk.any? { |node| node.kind == :object }
          end

          # WHICH GROUPS OF SIXTEEN A LAYER IS DRAWING FROM A LIST OF ITS OWN, so a tint that
          # walks the whole colour table can put those back rather than over: for each, where
          # the group sits, the variable holding where the layer's current version starts, and
          # how far along that version this group's list is.
          def bg_recolor_restore_banks
            @backgrounds.each_value.flat_map do |place|
              next [] unless place.colors

              place.colors.banks.each_with_index.map do |bank, at|
                [BG_PALETTE + (bank * PaletteBanks::BANK_SIZE * 2), place.colors.at, at * BackgroundDrawing::COLOR_LIST_BYTES]
              end
            end
          end

          attr_reader :picture, :screenfuls # how the picture stacks, whole and one screen at a time
          attr_reader :handover # what each scene puts up as it takes over (see IR::SceneHandover)
          attr_reader :backgrounds, :hardware_layers, :bg_shared, :vram,
                      :objects, :obj_pictures, :sprite_art, :placed_fade,
                      :obj_palette_blob, :obj_palette_units, :blobs, :codecs,
                      :painted_vram # run of painted tiles -> where it sits in video memory (see #note_painted_runs)

          # What +scene+ sends as it takes over (see SceneSend). A scene with nothing of its
          # own, or no scene at all, sends nothing.
          def scene_send(scene) = @scene_sends.fetch(scene, NOTHING_SENT)

          # Do the tiled scenes want different layers on? Only then does each scene tell the
          # display which, as it takes over (see #scene_screens_for).
          def layers_differ_by_scene? = @scene_sends.each_value.filter_map(&:screen).uniq.size > 1

          # The screen of the first tiled scene declared — the one boot sets up where the
          # scenes differ (see Drawing#first_scene_layers).
          def first_scene_screen = @scene_sends.each_value.find(&:screen)&.screen

          # Does any scene own sprites of its own? Then a scene's sprite pictures are marked
          # as up or not as scenes take turns, even for a scene with nothing to send.
          def scene_art? = @scene_sends.each_value.any?(&:art)

          # Does any scene send a sprite colour table of its own?
          def scene_obj_palettes? = @scene_sends.each_value.any?(&:obj_palette)

          # How many of the console's 128 sprite places +nodes+ take between them. Usually
          # one each; a sprite whose picture is bigger than one object takes one per piece.
          def object_count(nodes) = nodes.sum { |node| @obj_pictures.fetch(node.name).pieces }

          # ...and how many more the twins holding a placed fade off some of them take.
          def twin_object_count = @placed_fade.places_spent { |name| @obj_pictures.fetch(name).pieces }

          # THE SPRITES WHOSE ROWS OF THE CONSOLE'S TABLE HAVE TO BE WRITTEN EVERY FRAME, even
          # when nothing in the program moves them. There are two, and both are this layout's
          # own doing:
          #
          #   A SPRITE THAT KEEPS ONE FRAME AT A TIME copies its pictures into its room as the
          #   frame is drawn, and the scene it belongs to marks that room empty again as it
          #   takes over — later in the same frame. Written once, the copy would be undone and
          #   never made again, so the sprite would draw whatever tiles were left there.
          #
          #   A SPRITE KEPT OUT OF A PLACED FADE has a twin standing over it, and where the
          #   fade sits in the stack is a number the game moves. The twin is filled in from the
          #   sprite's own numbers on the way past, so it can only be written when the sprite
          #   is.
          def written_every_frame
            @objects.each_key.select { |name| @objects[name].frames || @placed_fade.fade_window_for(name) }
          end

          # WHERE EACH PIECE OF A SPRITE STANDS, pose by pose: for every pose, one
          # [x, y, width, height, mirrored] per piece, measured from the corner of the canvas
          # the art was drawn on.
          #
          # Read back out of what the console will actually be given — the per-pose words for a
          # sprite whose poses differ, the sprite's own size and offset for one whose poses all
          # came out alike — rather than out of the cut that produced them, so a word packed
          # wrong shows up here as a piece standing in the wrong place.
          def pieces_of(name)
            sprite = @objects.fetch(name)
            unless sprite.pose_words
              size = OBJ_SIZES.key([sprite.attr0_base >> 14, sprite.attr1_base >> 14])
              return Array.new(sprite.pose_count) { [[sprite.offset_x, sprite.offset_y, *size, false]] }
            end

            (0...sprite.pose_count).map do |pose|
              (0...sprite.pieces).map do |piece|
                word = sprite.pose_words.fetch((piece * sprite.pose_count) + pose)
                size = OBJ_SIZES.key([(word >> 10) & 3, (word >> 12) & 3])
                [*decode_pose_offset(word), *size, word.anybits?(POSE_MIRRORED)]
              end
            end
          end
          # WHICH OF THE CONSOLE'S 128 PLACES EACH DECLARED SPRITE WAS GIVEN.
          #
          # The console composes the picture from a table of 128 sprites, and each row of it says
          # which place it is — a number the build handed out and the author never saw. So a
          # cartridge that did not carry this can be asked where its sprites are and cannot say
          # which of the answers is the hero.
          #
          # Several places under one name is the ordinary case twice over. A picture too large
          # for the console to draw in one go is cut up, and the pieces stand shoulder to
          # shoulder from its first place; and every slot of a pool is a sprite of its own, all
          # of them the one thing the author declared. Both come back as the whole run of places
          # under that name, which is what somebody asking where a thing is wants.
          #
          # Keyed on the name the AUTHOR wrote. The program's own names for these are handed out
          # as it is built, so they say nothing to anybody, and a sprite drawn for something the
          # author named nothing (a letter of text) is left out rather than given one.
          def sprite_slots
            each_built_sprite.each_with_object({}) do |(node, sprite), places|
              next unless node.declared

              (places[node.declared] ||= []).concat((sprite.slot...(sprite.slot + sprite.pieces)).to_a)
            end
          end

          # Every sprite the picture declares, paired with the record the build made of it — what
          # the three reports below all walk. Nothing at all for a program that draws no picture.
          def each_built_sprite
            return to_enum(:each_built_sprite) unless block_given?
            return if @picture.nil?

            @picture.objects.each { |node| yield node, @objects[node.name] }
          end

          # HOW FAR ALONG THE BUILD MOVED EACH OF A SPRITE'S STORED POSES.
          #
          # A pose is kept trimmed to the part of its canvas that actually draws something, and
          # the sprite is told to stand that much further along so the picture does not move (see
          # PoseCutter#pose_box). A pose drawn BACKWARDS is trimmed from the other side, so it
          # stands a different amount further along again. Both are this backend's own doing, so
          # a place read back off the console is that much past the corner of the picture — right
          # for a sprite facing one way and wrong for the same sprite facing the other, which is
          # the worst way for a number to be wrong.
          #
          # Keyed by the PLACE in the console's table — which is the one thing a row of that table
          # says about itself that is its own — and then by whatever tells that place's poses apart
          # (see #pose_key, which is where the two answers to that are).
          #
          # The place has to be the outer key rather than the sprite's name, because a picture
          # cut into pieces can hold the same tiles in more than one of them (a wide plain wall
          # is the easy case) and those pieces stand at different distances.
          def sprite_offsets
            each_built_sprite.each_with_object({}) do |(_node, sprite), moved|
              sprite.pieces.times { |piece| moved[sprite.slot + piece] = pose_offsets(sprite, piece) }
            end
          end

          # WHAT THE PICTURES COST IN VIDEO MEMORY, and what storing them the small way saved.
          #
          # The console keeps sprite pictures in 32K and background tiles in a block of their
          # own, and a game that outgrows either gets a build error rather than a slow frame. So
          # what is worth reporting is the room left — and, since the framework chose the
          # storage without being asked, how much of that room the choice bought back. A build
          # with no sprites and no tiles has nothing to say and reports nothing.
          def video_memory_report
            return nil if @objects.empty? && @backgrounds.empty?

            RubyGBA::Diagnostics::VideoMemory.new(sprites: sprite_memory_report, tiles: tile_memory_report,
                                     objects: object_count_report)
          end

          private

          def const_int(node) = self.class.const_int(node)
          def object_transformed?(node) = self.class.transformed?(node)
          def object_scales?(node) = self.class.scales?(node)

          # Is this sprite in a layer the program sees through? Then its own table entry
          # says so, and the display blends it with what is behind it.
          def see_through_object?(node) = @see_through.include?(node.layer)

          # Turn the tiled backgrounds into the data tile hardware reads — one shared color
          # palette, the tile pictures, and a map per layer — and stash them as ROM blobs
          # uploaded at startup. Done up front (after every tile image is collected) so the
          # addresses exist before the code refers to them. emit_background (in Drawing) is
          # the run-time half.
          def prepare_backgrounds(program)
            # Back to front. A layer can put a background behind one declared before it,
            # and this order becomes the hardware layer number, which IS the paint order —
            # so it has to be settled here, before any layer is given a number.
            #
            # A `screen :rotozoom` background lives on its own rotate/scale layer (BG2) —
            # a different pair of hardware layers from the four `screen :tiled` scrolls on
            # — so it's set aside from the regular stack rather than counted against it.
            check_layers_fit!(program)
            affine_nodes, regular_nodes = @picture.scenery.partition(&:affine)

            banks, big = assign_tile_banks(regular_nodes, affine_nodes)

            slots = layer_slots
            scene_screens_for(slots).each { |scene, screen| record_scene_send(scene, screen: screen) }
            everywhere = place_shared_scenery(slots, banks, big)
            fullest = place_each_scene(everywhere, slots, banks, big)

            # Which layer each background ended up on, for everything that has to name one by
            # number afterwards. The blend unit is the only such thing today, and it cannot
            # work it out for itself: the number is not where the background sits in the
            # program, it is what was free on the screen the background belongs to.
            @hardware_layers = @backgrounds.transform_values(&:bg)

            colors = banks.entries
            @blobs[BG_SHARED_PAL] = colors.pack("v*")
            @blobs[BG_SHARED_CHAR] = everywhere.bytes
            @vram = fullest.vram # what the report reads the room left out of
            @bg_shared = shared_scenery_summary(regular_nodes + affine_nodes, big, colors, boot: everywhere, fullest: fullest)
          end

          # Fill in part of what +scene+ sends as it takes over.
          def record_scene_send(scene, **part) = @scene_sends[scene] = scene_send(scene).with(**part)

          # WHERE A SCENE'S OWN TILE PICTURES ARE SENT AS IT TAKES OVER: the blob holding them,
          # how far into video memory they go, and how many halfwords that is. Only scenes
          # with pictures of their own are here.
          SceneTiles = Data.define(:blob, :offset, :units)

          # WHERE A RUN OF PAINTED TILES SITS: how far into video memory it starts, how many
          # bytes it takes, and the list its pixels are copied from.
          #
          # +places+ is where it starts on each screen that shows it, by scene (nil for one
          # every screen shows). Scenes lay their own tiles out from the same starting point,
          # so a run shown in two of them can land in two places, and the place a run has in
          # one scene is some other picture's in the next. So +at+ is set only for a run every
          # screen shows, which sits in one place throughout; for a run that belongs to scenes
          # it is nil, and the copy reads where it goes from a variable each scene sets as it
          # runs (see Drawing#emit_painted_run_places).
          PaintedRun = Data.define(:at, :bytes, :list, :what, :places) do
            # +earlier+ is what was noted for the run before, if anything: one more screen's
            # place is added to its places.
            def self.with_place(earlier, scene:, at:, **rest)
              places = (earlier&.places || {}).merge(scene => at)
              new(at: places.key?(nil) ? at : nil, places: places, **rest)
            end

            # The variable a run that moves keeps its address in: where it sits on the screen
            # up now, as a whole address, or 0 on a screen that does not show it.
            def self.place_var(name) = :"__painted_#{name}_at"

            def moves? = at.nil?
          end

          # THE SCENERY EVERY SCREEN SHOWS GOES IN FIRST, and stays for the whole game: its
          # pictures are sent at boot and its maps are set up once. What it takes is what
          # each scene has left.
          def place_shared_scenery(slots, banks, big)
            store = BackgroundTiles.new(vram: TileVram.new)
            place_scenery(store, @picture.scenery.reject(&:scene), slots, banks, big)
            store
          end

          # THEN EACH SCENE'S OWN, IN THE SAME ROOM AS EVERY OTHER SCENE'S.
          #
          # This is what makes the budget one scene's rather than the whole game's, the way
          # it already is for sprite pictures. Two scenes are never on screen together, so
          # each goes on from what every screen shows and puts its pictures and maps in the
          # same place the others put theirs — and sends its pictures in as it takes over
          # (see Drawing#emit_scene_scenery), which is also when its maps are sent. A picture
          # every screen already has is shared rather than sent again, since that part of the
          # memory never changes hands.
          #
          # Returns the tile run of the screen that holds the most, which is what the report
          # has to say about: that one is the budget.
          def place_each_scene(everywhere, slots, banks, big)
            shared = everywhere.bytes.bytesize
            fullest = everywhere
            @picture.scenery.filter_map(&:scene).uniq.each_with_index do |scene, index|
              store = everywhere.dup
              place_scenery(store, @picture.scenery.select { |node| node.scene == scene }, slots, banks, big, scene: scene)
              own = store.bytes.byteslice(shared..)
              unless own.empty?
                blob = :"__bg_scene_tiles_#{index}"
                @blobs[blob] = own
                keep_unpacked!(blob)
                record_scene_send(scene, tiles: SceneTiles.new(blob: blob, offset: shared, units: own.bytesize / 2))
              end
              fullest = store if store.vram.free_bytes < fullest.vram.free_bytes
            end
            fullest
          end

          # Put +nodes+ in video memory — into +store+, the tile pictures and maps of the
          # screen they are on — the scrolling ones before any that turn. A screen whose
          # scenery does not fit is refused naming its scene, and counting what every screen
          # shows with it, since that is part of what the scene has to fit beside.
          def place_scenery(store, nodes, slots, banks, big, scene: nil)
            nodes.reject(&:affine).each { |node| prepare_one_background(store, node, slots.fetch(node.name), banks, big) }
            nodes.select(&:affine).each { |node| prepare_affine_background(store, node, banks) }
          rescue TileVram::Full => e
            raise LoweringError, tiles_overflow_message(e, @picture.scenery.reject(&:scene) + nodes, scene)
          end

          # WHICH OF THE CONSOLE'S FOUR SCROLLING LAYERS EACH BACKGROUND GETS.
          #
          # A layer is spent while something is being DRAWN, so the four have to cover one
          # screenful and never the whole program: two scenes that take turns can have four
          # backgrounds each, because the console is only ever holding one scene's.
          #
          # WHICH LAYER A BACKGROUND SITS ON IS NOT WHAT PUTS IT IN FRONT, and that is what
          # makes this straightforward. Paint order is a separate field of the layer's own
          # settings — its priority — so a slot is only a set of registers to use, free to be
          # handed out in whatever order suits, while the picture's order is carried by the
          # priority (see #hardware_priority, which reads the screenful's own depths).
          #
          # Scenery every screen shows is pinned the first time it is seen and keeps that
          # slot throughout, because nothing re-points it as scenes come and go. Each scene's
          # own backgrounds then take whatever is left, which is why a scene can have four
          # only when there is no always-there scenery beside them.
          #
          # There is always a slot to hand out, because #check_layers_fit! has already refused
          # a screenful asking for more than there are. It runs first for that reason.
          def layer_slots
            slots = {}
            @screenfuls.each do |screenful|
              free = scrolling_slots(screenful) - screenful.scrolling.filter_map { |node| slots[node.name] }
              screenful.scrolling.each { |node| slots[node.name] ||= free.shift }
            end
            slots
          end

          # The slots a screenful has to hand out — the same counts the check above refuses
          # against, read from the same place so the two cannot drift apart.
          #
          # A screen holding a background that TURNS has fewer, and they are not the same
          # ones: the console gives its rotate hardware to a particular layer (AFFINE_BG) and
          # the arrangement that provides it leaves only the two below that one scrolling.
          def scrolling_slots(screenful)
            check = Guardrails::Checks::TooManyBackgroundLayers
            most = if screenful.turning_on_tiled_screen(@modes).any?
                     check::MAX_SCROLLING_LAYERS_BESIDE_TURNING
                   else
                     check::MAX_SCROLLING_LAYERS
                   end
            (0...most).to_a
          end

          # WHAT EACH SCENE TELLS THE DISPLAY — and this is the half that has to happen while
          # the game RUNS, where the numbering above is settled during the build.
          #
          # Both were settled once for the whole program, from every background in it. That
          # was right while every background had a layer of its own and one arrangement held
          # the lot. Now that scenes share them, neither is:
          #
          #   A scene that uses FEWER layers than the one before it left the extra ones
          #   switched on and still pointed at the last scene's maps, so walking out of a
          #   parallax field into a plain room showed the field's far layers through the
          #   room's floor.
          #
          #   A scene that turns nothing was still put in the arrangement that holds a turning
          #   layer, because some other scene turned one — and that arrangement has only two
          #   scrolling layers, so a game could not have a title screen with something flying
          #   at the player AND a game played on four layers. The console is told which
          #   arrangement it is in as each screen is set up, so this is simply what it is for.
          #
          # Nothing is emitted for a program whose scenes all want the same screen, which is
          # every program with no scene-owned scenery and most of those that have it (see
          # #layers_differ_by_scene?). Returns each tiled scene's screen.
          def scene_screens_for(slots)
            wanted = @screenfuls.reject { |s| s.scene.nil? }.to_h do |screenful|
              [screenful.scene, scene_screen(screenful, slots)]
            end
            wanted.select { |scene, _| @modes.func_mode[scene] == IR::Modes::TILED }
          end

          # A turning background is always on the layer the console keeps that hardware on,
          # so it is switched on beside this screen's scrolling ones rather than taking one
          # of their slots — which is also why it does not count against them.
          def scene_screen(screenful, slots)
            turning = screenful.turning_on_tiled_screen(@modes).any?
            on = screenful.scrolling.filter_map { |node| slots[node.name] }
            on += [AFFINE_BG] if turning
            SceneScreen.new(on: on, turning: turning)
          end

          # DO THE DECLARED LAYERS FIT AN ARRANGEMENT THE CONSOLE HAS? A layer that did not
          # fit would simply not be drawn, and a picture missing one layer reads as a bug in
          # the art rather than as a budget — so lowering stops rather than dropping it.
          #
          # The rule and its wording live with the guardrail of the same name, because the
          # question is answerable from the program long before any of this runs and an
          # author should hear it then. This stays as the lowering's own invariant: a
          # program that reached a backend without passing the guardrails still cannot
          # build a cartridge with a layer quietly missing from it.
          def check_layers_fit!(program)
            refusal = Guardrails::Checks::TooManyBackgroundLayers.new.refusal_message(program) ||
                      Guardrails::Checks::SeeThroughPerScreen.new.refusal_message(program)
            raise LoweringError, refusal if refusal
          end

          # SORT EVERY TILE OF EVERY LAYER INTO THE COLOR TABLE THEY ALL READ FROM.
          #
          # A layer is stored one way or the other as a WHOLE — that is one bit in the
          # layer's own settings — but within a small-storage layer each TILE says which
          # bank of sixteen it draws from. So a tileset of hundreds of colors still stores
          # small, as long as no single 8x8 tile needs more than fifteen at once, which is
          # almost always true and is why this is worth doing.
          #
          # A layer with even one tile past that keeps the big storage, and then all of its
          # tiles read across the whole table together — so it is handed in as one picture
          # rather than as its tiles.
          #
          # A `screen :rotozoom` layer is always big: its map is one byte a cell, with no
          # room to name a bank. That is the console, not a choice.
          def assign_tile_banks(regular_nodes, affine_nodes)
            nodes = regular_nodes + affine_nodes
            nodes.each { |node| validate_tile_sizes!(node.name, node.tiles) }
            big = affine_nodes + regular_nodes.reject { |node| every_tile_small?(node) }

            loop do
              banks = PaletteBanks.new(bank_pictures(nodes, big))
              spilled = (regular_nodes - big).reject do |node|
                node.tiles.each_index.all? { |i| banks.placement(tile_key(node, i)).narrow? }
              end
              return [banks, big] if spilled.empty?

              big += spilled
            end
          rescue PaletteBanks::Overflow
            raise LoweringError,
                  "The tiled backgrounds use more colors between them than the console's background table " \
                  "holds (#{PaletteBanks::CAPACITY}). Draw the tiles from fewer different colors."
          end

          def every_tile_small?(node)
            node.tiles.each_index.all? { |i| tile_colors(node, i).size <= PaletteBanks::BANK_COLORS }
          end

          # One picture per tile for a layer stored the small way, and one picture for the
          # whole of a layer stored the big way (its tiles share the table, so they share
          # an entry).
          #
          # A layer stored the big way is read a whole byte a pixel, so it is handed over as
          # +wide+ — its colours must run across the whole table, however few of them there
          # are. A layer that went big because one greedy tile has too many colours is wide
          # on the count alone; a TURNING layer is the one that needs saying, because the
          # console gives it no other way to be read (its map holds one byte a cell, with no
          # room to name a bank) and it can still be drawn from a handful of colours.
          def bank_pictures(nodes, big)
            nodes.map do |node|
              if big.include?(node)
                colors = node.tiles.each_index.flat_map { |i| tile_colors(node, i) }.uniq
                PaletteBanks::Picture.new(key: node.name, colors: colors, authored: nil, wide: true)
              else
                # A layer that can be drawn with other colours keeps its bank to itself: the
                # swap writes into that bank, so anything else reading it would change colour
                # along with the layer (see PaletteBanks::Picture#keeps_to).
                keeps_to = node.recolors.empty? ? nil : node.name
                node.tiles.each_index.map do |i|
                  PaletteBanks::Picture.new(key: tile_key(node, i), colors: tile_colors(node, i),
                                            authored: @bitmaps.fetch(node.tiles[i]).colors,
                                            keeps_to: keeps_to)
                end
              end
            end.flatten
          end

          def tile_key(node, index) = [node.name, index]

          # Does this sprite show a picture the game paints from a list? One that does shows
          # nothing else: a painted picture is a sprite's only pose.
          def painted_sprite?(node) = node.poses.any? { |pose| @painted_pictures.key?(pose) }

          # Where sprite pictures start, counted from the start of video memory, as a painted
          # run's address is.
          def obj_tile_vram_offset = SpriteDrawing::OBJ_TILE_BASE - VRAM_START

          # WHERE EACH RUN OF PAINTED TILES LANDED, as bytes into video memory: the copy that
          # paints it writes there (see BackgroundDrawing#emit_copy_tiles). One copy is one
          # stretch of memory, so the run has to have landed in order and side by side, which
          # it does because its tiles are stored one after another and never shared.
          def note_painted_runs(store, node, images)
            images.map { |image| @painted_runs.fetch(image) }.uniq.each do |run|
              first = store.painted_at.fetch(run.tiles.first)
              unless run.tiles.each_with_index.all? { |tile, k| store.painted_at[tile] == first + (k * SMALL_TILE_BYTES) }
                raise LoweringError, "background :#{node.name} shows only part of tiles :#{run.name}, or shows them " \
                                     "out of order. Its tileset must hold all #{run.tiles.size} of them."
              end
              earlier = @painted_vram[run.name]
              unless one_place_per_screen?(earlier&.places || {}, node.scene, first)
                refuse_painted_run_in_two_places!(run, node)
              end
              @painted_vram[run.name] = PaintedRun.with_place(earlier, scene: node.scene, at: first,
                                                              bytes: run.tiles.size * SMALL_TILE_BYTES,
                                                              list: run.list, what: "tiles")
            end
          end

          # A screen copies the run to one place, so every background on one screen that shows
          # it has to show it from the same place — and a background every screen shows is on
          # all of them at once.
          def one_place_per_screen?(places, scene, first)
            same = places.select { |shown_in, _| shown_in == scene || shown_in.nil? || scene.nil? }
            same.values.all?(first)
          end

          def refuse_painted_run_in_two_places!(run, node)
            raise LoweringError, "background :#{node.name} shows tiles :#{run.name}, and so does another background " \
                                 "on the same screen. Background :#{node.name} counts its tiles from too far along " \
                                 "video memory to reach the copy the other one shows. The game paints the tiles in " \
                                 "one copy, so one screen must show them from one place. To fix this, declare " \
                                 "background :#{node.name} before the backgrounds with the biggest tilesets, or give " \
                                 "it its own list and its own tiles."
          end

          def refuse_painted_tiles_stored_big!(node)
            raise LoweringError, "background :#{node.name} shows tiles the game paints from a list, and its other " \
                                 "tiles need more than 15 colours. A painted tile holds 16 colours or fewer. To " \
                                 "fix this, draw the other tiles from fewer colours, or put the painted tiles on " \
                                 "a background of their own."
          end

          # A tile's distinct colors, first-seen order, without the see-through one.
          def tile_colors(node, index)
            bmp = @bitmaps.fetch(node.tiles[index])
            seen = {}
            (TILE_PX * TILE_PX).times do |i|
              seen[bmp.color_at(i)] = true unless bmp.tile_see_through_at?(i)
            end
            seen.keys
          end

          # What every layer shares, once they are all stored: the one color table and the
          # one run of tile pictures, with how many TILES got each storage and what the small
          # ones saved. Those two are counted off the layers rather than off the banks, since
          # a layer stored the big way is one picture there however many tiles it has.
          def shared_scenery_summary(nodes, big, colors, boot:, fullest:)
            small = nodes.reject { |node| big.include?(node) }.sum { |node| node.tiles.size }
            SharedScenery.new(palette_units: colors.size, tile_units: boot.bytes.bytesize / 2,
                              tile_bytes: fullest.bytes.bytesize,
                              small: small, big: nodes.sum { |node| node.tiles.size } - small,
                              saved: small * SMALL_TILE_BYTES,
                              shared: fullest.shared, skipped: fullest.skipped)
          end

          # The tiles and the maps grow toward each other and met. Name the biggest tileset,
          # since "out of room" with no name attached is the least useful thing a build can
          # say — and say what each half took, because which one to shrink is the decision.
          #
          # A scene is only ever measured against the room it has on its own screen, so a scene
          # that ran out is named — "the scenery" would send the author adding up the whole game.
          def tiles_overflow_message(full, nodes, scene = nil)
            worst = nodes.max_by { |node| node.tiles.size }
            whose = scene ? "The scenery of the scene :#{IR::Modes.strip_scene_prefix(scene)}" : "The scenery"
            everywhere = scene && @picture.scenery.any? { |node| node.scene.nil? }
            "#{whose} does not fit in the #{TileVram::TOTAL_BYTES} bytes the console keeps it in. " \
              "Its tile pictures take #{full.tile_bytes} bytes, and its #{full.map_blocks} maps take " \
              "#{full.map_blocks * SCREENBLOCK_BYTES} more.#{' This includes the scenery that every scene shows.' if everywhere} " \
              "The background with the most tiles is :#{worst.name} (#{worst.tiles.size}). Use fewer " \
              "different tiles, or draw fewer layers #{scene ? 'in this scene' : 'at once'}."
          end

          # Put one layer's tiles in video memory and build its map. +layer+ is its place in
          # the stack, which is also its hardware layer number (BG0, BG1, ...). What decides
          # its paint order is the priority below.
          def prepare_one_background(store, node, layer, banks, big)
            name = node.name
            validate_map_fits!(name, node.map)
            small = !big.include?(node)
            painted = node.tiles.each_with_index.select { |tile, _| @painted_runs.key?(tile) }.to_h { |tile, i| [i, tile] }
            refuse_painted_tiles_stored_big!(node) if !small && !painted.empty?
            stored = store.add(name, tile_pictures(node, banks),
                               unit: small ? SMALL_TILE_BYTES : BIG_TILE_BYTES, painted: painted)
            note_painted_runs(store, node, painted.values)

            # The map: one 16-bit entry per cell, holding the tile to draw there and — for a
            # layer stored the small way — which bank of sixteen that tile reads from. Cells
            # outside the authored map, and blank cells, get this layer's blank tile: every
            # pixel see-through, so a layer behind shows through. Which number that is
            # depends on where the layer counts from, and it is 0 for a layer counting from
            # the bottom, which is nearly all of them.
            cols, rows = IR::TileMap.grid(node.map)
            cell_for = node.tiles.each_index.to_h do |index|
              bank = small ? banks.placement(tile_key(node, index)).bank : 0
              [index, stored.number(index) | (bank << BG_BANK_SHIFT)]
            end
            entries = map_entries(node.map, cols, rows, stored.blank) { |index| cell_for.fetch(index) }

            grids = every_map(node)
            map_blob = :"__bg_map_#{name}"
            @blobs[map_blob] =
              grids.map { |map| map_entries(map, cols, rows, stored.blank) { |i| cell_for.fetch(i) }.pack("v*") }
                   .join
            keep_unpacked!(map_blob) if grids.size > 1
            keep_unpacked!(map_blob) if node.scene
            @backgrounds[name] = BackgroundPlacement.new(
              map: map_blob, map_units: entries.size,
              bg: layer,                           # hardware layer (BG0..BG3), in stack order
              screen_block: store.vram.take_map(entries.size / MAP_ENTRIES_A_BLOCK),
              size: regular_map_size(cols, rows),
              priority: hardware_priority(name),
              affine: false,
              small: small,
              char_base: stored.char_base,
              map_count: grids.size, map_bytes: entries.size * 2,
              grid: MapGrid.new(cols: cols, rows: rows, cells: cell_for),
              colors: background_color_lists(node, banks, small)
            )
          end

          # Lay out the other lists of colours a background can be drawn from (see
          # BackgroundColorLists), and say where in the display's table they are written.
          def background_color_lists(node, banks, small)
            return nil if node.recolors.empty?

            raise LoweringError, recolor_colors_message(node) unless small

            room = 1 << (node.palettes.length - 1).bit_length # lists a version takes, rounded up to a power of two
            blob = :"__bg_colors_#{node.name}"
            @blobs[blob] = (node.recolors + [node.palettes]).flat_map do |version|
              version.flat_map { |list| pad_to_bank(list) } + ([0] * (PaletteBanks::BANK_SIZE * (room - version.length)))
            end.pack("v*")
            keep_unpacked!(blob) # picked out of by a number the game works out, so it stays where it is put
            BackgroundColorLists.new(blob: blob, count: node.recolors.length,
                                     banks: node.palettes.map { |list| bank_drawn_from(node, list, banks) },
                                     at: :"__bg_#{node.name}_colors_at",
                                     shift: BackgroundDrawing::COLOR_LIST_SHIFT + room.bit_length - 1)
          end

          # The group of sixteen a layer's tiles drawn from +list+ read. Every such tile reads the
          # same one: a list someone wrote down shares a group only with that very list.
          def bank_drawn_from(node, list, banks)
            tile = node.tiles.index { |image| @bitmaps.fetch(image).colors == list }
            banks.placement(tile_key(node, tile)).bank
          end

          # A list as the display holds it: sixteen entries, the author's own order kept, and
          # nothing in the places a shorter list does not reach.
          def pad_to_bank(list)
            list.first(PaletteBanks::BANK_SIZE) + ([0] * [PaletteBanks::BANK_SIZE - list.length, 0].max)
          end

          def recolor_colors_message(node)
            "background :#{node.name} is told to draw with other colors, and its tiles are drawn from " \
              "too many colors for that. A background can be given other colors only when its tiles " \
              "are drawn from 16 colors or fewer between them. To fix this, draw its tiles from fewer " \
              "colors, or do not give it other colors."
          end

          # Every grid a background can be handed, the one it was declared showing first. A
          # background declared with a single map has just that one.
          def every_map(node) = node.maps&.any? ? node.maps : [node.map]

          # KEEP A BLOB OUT OF THE PACKER. A background's maps are laid end to end so the map
          # numbered N can be found by counting N strides along from the first — arithmetic
          # the game does as it runs, and which packing the lot into one compressed stream
          # would destroy. Registering the codec here is what stops the first upload packing
          # it (see BlobUpload#pack_blob, which asks this table before doing anything).
          #
          # WHAT A SCENE SENDS AS IT TAKES OVER is kept unpacked too, for a different reason:
          # time. Packed data is unpacked by the console's own built-in routine, a few bytes at
          # a time, and a scene's art is sent inside the pass that switches to it — so a big
          # scene unpacking its tiles and maps made that pass run three frames long, and the
          # game lost those frames of its logic on the console alone (the interpreter spends no
          # time copying). A plain copy is the console's copying engine, which moves the
          # largest scene's scenery in a fraction of a frame. What it costs is cartridge space,
          # which a game has far more of than frames. Art sent once at power-on still packs.
          def keep_unpacked!(name) = @codecs[name] = :none

          def regular_map_size(cols, rows) = REGULAR_MAP_SIZES.fetch([cols, rows]) << MAP_SIZE_SHIFT

          # A MAP WIDER OR TALLER THAN ONE BLOCK IS SEVERAL BLOCKS, and the console reads
          # them in a fixed order: the left half first, then the right, and for a tall map
          # the top pair before the bottom pair. So a 64x64 map is four 32x32 squares laid
          # out top-left, top-right, bottom-left, bottom-right — not 64 rows of 64.
          #
          # That is why this cannot simply walk the authored rows: a cell's place in the
          # blob depends on which quarter of the map it is in. The blocks are consecutive in
          # memory (TileVram hands out a run), so the whole thing still uploads as one copy.
          def map_entries(map, cols, rows, blank = 0)
            entries = Array.new(cols * rows, blank)
            map.each_with_index do |row, r|
              next if r >= rows

              row.each_with_index do |index, c|
                next if c >= cols || index.nil?

                entries[map_offset(c, r, cols)] = yield(index)
              end
            end
            entries
          end

          def map_offset(col, row, cols)
            quarter = ((row / MAP_CELLS) * (cols / MAP_CELLS)) + (col / MAP_CELLS)
            (quarter * MAP_ENTRIES_A_BLOCK) + ((row % MAP_CELLS) * MAP_CELLS) + (col % MAP_CELLS)
          end

          # A layer's tiles as {BackgroundTiles} takes them: each the picture it was drawn
          # from, and where that tile's colors sit — its own bank if the layer is stored the
          # small way, else the whole table the layer shares.
          def tile_pictures(node, banks)
            node.tiles.each_index.map do |index|
              key = tile_key(node, index)
              [@bitmaps.fetch(node.tiles[index]), banks.placement(banks.known?(key) ? key : node.name)]
            end
          end

          # Fold an affine background's tiles into the shared character block (same as a
          # regular one) but build its MAP differently: one byte per cell, not two, because
          # the console's rotate/scale layer reads a plain tile number with no flip bits —
          # so it can name only 256 tiles, not the 1024 a regular layer's map can.
          #
          # That one byte is also why this layer is always stored the big way: with no room
          # in a map entry to name a bank of sixteen, its tiles have nothing to draw from
          # but the whole table.
          def prepare_affine_background(store, node, banks)
            name = node.name
            tiles = node.tiles
            validate_map_fits!(name, node.map)
            if tiles.any? { |tile| @painted_runs.key?(tile) }
              raise LoweringError, "background :#{name} turns or resizes, and it shows tiles the game paints from a " \
                                   "list. A turning background stores every tile with 256 colours, and a painted " \
                                   "tile holds 16. To fix this, put the painted tiles on a background that does " \
                                   "not turn."
            end

            # The same shared sine table a turning sprite reads (see #prepare_affine) —
            # baked in here too, since a program can turn a background without ever
            # turning a sprite.
            @blobs[OBJ_SINE_BLOB] ||= build_sine_table

            begin
              stored = store.add(name, tile_pictures(node, banks),
                                 unit: BIG_TILE_BYTES, most: AFFINE_MAX_TILES)
            rescue LoweringError
              raise LoweringError,
                    "background :#{name} turns and resizes, so its map can only name " \
                    "#{AFFINE_MAX_TILES} tiles — one byte per cell, no room for more. It has #{tiles.size} of " \
                    "its own, and they must all sit inside one #{CHAR_BLOCK_BYTES}-byte stretch of video " \
                    "memory. Use fewer distinct tiles, or declare this background first."
            end

            # A rotate/scale layer's map is one BYTE per cell and is laid out as plain rows
            # of the whole grid — not as squares of 32x32 the way a regular layer's is. So a
            # bigger one of these needs no re-arranging, only more room.
            cols, rows = IR::TileMap.grid(node.map)
            grids = every_map(node).map { |map| affine_map_entries(map, cols, rows, stored) }
            entries = grids.first

            map_blob = :"__bg_map_#{name}"
            @blobs[map_blob] = grids.map { |one| one.pack("C*") }.join
            keep_unpacked!(map_blob) if grids.size > 1
            keep_unpacked!(map_blob) if node.scene
            blocks = ((entries.size + SCREENBLOCK_BYTES - 1) / SCREENBLOCK_BYTES)
            @backgrounds[name] = BackgroundPlacement.new(
              map: map_blob, map_units: entries.size / 2, # DMA copies halfwords, so a byte map is half as many
              bg: AFFINE_BG,
              screen_block: store.vram.take_map(blocks),
              size: affine_map_size(cols, rows, name),
              priority: hardware_priority(name),
              affine: true,
              small: false,
              char_base: stored.char_base,
              map_count: grids.size, map_bytes: entries.size,
              grid: nil, # its cells are one byte and hold a tile number alone: no grid of that shape
              colors: nil # ...and its tiles read the whole table rather than a group of sixteen
            )
          end

          # One rotate/scale map's cells, plain rows of the whole grid, one byte each.
          def affine_map_entries(map, cols, rows, stored)
            entries = Array.new(cols * rows, stored.blank)
            map.each_with_index do |row, r|
              next if r >= rows

              row.each_with_index do |index, c|
                next if c >= cols || index.nil?

                entries[(r * cols) + c] = stored.number(index)
              end
            end
            entries
          end

          def affine_map_size(cols, rows, name)
            side = [cols, rows].max
            unless cols == rows
              raise LoweringError,
                    "background :#{name} turns about its middle, so its map must be square. This one " \
                    "is #{cols}x#{rows} tiles. Make it #{side}x#{side}."
            end

            AFFINE_MAP_SIZES.fetch(side) << MAP_SIZE_SHIFT
          end

          # ASKED ONE SCREENFUL AT A TIME, the same way the layers are (see #layer_slots).
          # A level is spent while something is being drawn, so what has to fit is what can be
          # on screen together — and scenes that take turns never are. Counted across the
          # whole program instead, a game that declared a stack and three backgrounds in each
          # of two scenes passed the layer count and then died here at six levels.
          def check_stack_depth_fits!
            return if @picture.stack.empty?

            deepest = @screenfuls.max_by { |screenful| screenful.depths.count }
            needed = deepest.depths.count
            return if needed <= MAX_LEVELS

            raise LoweringError,
                  "#{whose_picture(deepest)} needs #{needed} levels of depth and the console " \
                  "stacks #{MAX_LEVELS} at one time. #{stack_overflow_cause(deepest)}\n" \
                  "The stack is #{@picture.stack.map { |name| ":#{name}" }.join(', ')}, back to front."
          end

          def whose_picture(screenful)
            return "This picture" unless screenful.scene

            "The scene :#{IR::Modes.strip_scene_prefix(screenful.scene)}'s picture"
          end

          # Which of the two ways it ran out, and what to do about that one.
          def stack_overflow_cause(screenful)
            backmost = screenful.objects.select { |node| screenful.depths[node.name].zero? }
            if backmost.any? && screenful.scenery.none? { |node| screenful.depths[node.name].zero? }
              behind = backmost.map(&:layer).uniq.compact
              "The sprites in #{behind.map { |name| ":#{name}" }.join(', ')} sit behind every background, " \
                "which takes a level of its own. To fix this, move that layer in front of one background, " \
                "or use one background less."
            else
              "Each background takes a level, and the sprites in front of it share that level. " \
                "To fix this, use fewer backgrounds."
            end
          end

          # What the console's stacking hardware is told about how deep a thing sits.
          #
          # It counts the other way round from the picture: 0 is the FRONT and 3 the back,
          # and there are only four of them. So the levels the picture needs are flipped
          # onto that scale, deepest first. Several named layers can land on one number,
          # which is the point — the console has more layers than it has priorities, and
          # it can already tell apart what shares one (a sprite is drawn over a background
          # of the same priority, and two sprites keep their table order).
          #
          # READ OFF ONE SCREENFUL, for the same reason the layer slots are: there are four
          # of these too, and they are spent while something is being drawn. A game whose
          # scenes take turns would otherwise run out of depths having never shown more than
          # four things at once — and ask the console for a priority it does not have.
          # THE FURTHEST BACK IT HAS TO BE ON ANY SCREEN, which matters for scenery every
          # screen shows. Such a thing is drawn once, where it was declared, so it carries ONE
          # priority — while the screens it appears on can hold different numbers of layers,
          # and so place it differently.
          #
          # Taking the backmost of those is what keeps every screen right. A backdrop behind
          # one layer in a quiet scene and behind three in a busy one has to be told the
          # busier number, or the busy scene draws it in front of its own backmost layer.
          # Measured before this said `max`: a backdrop beside scenes of one and three
          # backgrounds came out in front of the three-background scene's back layer.
          #
          # Pushing it further back can never disturb the quiet screen, because there is
          # nothing behind it there to get in the way of.
          def hardware_priority(name)
            @screenfuls.filter_map do |screenful|
              next unless screenful.depths.of.key?(name)

              screenful.depths.count - 1 - screenful.depths[name]
            end.max
          end

          # This color's slot in the shared background palette, adding it if it's new.
          #
          # Every tiled layer draws from one 256-color palette, and a tile pixel is a
          # single byte holding an index into it. So the 257th distinct color has no
          # index that fits in a pixel. The check belongs here, at the moment a color is
          # added, because the very next thing the caller does is pack the index into a
          # byte — past 255 that is a raw range error from deep inside the packing, which
          # tells the developer nothing.
          # A tiled background scrolls over a grid that comes in fixed sizes, and the biggest
          # is 64x64 tiles — 512x512 pixels, four screenfuls. Past that a level has to be
          # split, and saying so is better than a silently cropped one.
          def validate_map_fits!(name, map)
            return if IR::TileMap.fits?(map)

            cols = map.map(&:length).max || 0
            most = IR::TileMap.max_grid_size
            raise LoweringError,
                  "background :#{name} is #{cols}x#{map.length} tiles, and a tiled background is at most " \
                  "#{most}x#{most} tiles (#{most * TILE_PX}x#{most * TILE_PX} pixels, which is four " \
                  "screenfuls and scrolls and wraps). Use a smaller map, or split the level."
          end

          def validate_tile_sizes!(name, tiles)
            tiles.each do |tile|
              bmp = @bitmaps.fetch(tile) do
                raise LoweringError, "background :#{name} references undefined tile image #{tile.inspect}"
              end
              next if bmp.width == TILE_PX && bmp.height == TILE_PX

              raise LoweringError,
                    "screen :tiled needs #{TILE_PX}x#{TILE_PX} tiles, but tile #{tile.inspect} is " \
                    "#{bmp.width}x#{bmp.height} — resize it, or draw this background under screen :bitmap"
            end
          end
          # Lay all the declared sprites out: one shared color table every sprite indexes
          # into, then each sprite's picture as tiles and its place in the sprite table.
          # Done up front so the addresses exist before the per-frame draw refers to them;
          # the boot upload (emit_boot_objects) and the per-frame draw
          # (emit_present_objects) are the run-time halves.
          #
          # Slots run backwards: the sprite drawn last takes the lowest table slot, and a
          # lower slot draws in front — so the last one in the frame's draw order sits on
          # top, the same front-to-back order the interpreter and the software sprites
          # use. That ordering is fixed at build time, which is what lets hardware sprites
          # hold a stable stack (one reliably in front of another) that software
          # save-under sprites can't.
          #
          # The order comes from the frame's own draw list, not from where the sprites
          # happen to sit in the tree. The two are usually the same and are not always:
          # a HUD is drawn after the game whatever order it was written in, and a layer
          # can put a sprite in front of one declared later. Reading the list the frame
          # actually draws is what keeps this console agreeing with every other backend
          # about which sprite is on top.
          def prepare_objects(program)
            nodes = @picture.objects
            # The guardrail of the same name has the rule and the words; this is the lowering's
            # own invariant, for a program that reached it without passing the guardrails.
            refusal = Guardrails::Checks::TooManySprites.new.refusal_message(program)
            raise LoweringError, refusal if refusal
            build_shared_object_palette(nodes)
            # EVERY SPRITE'S PICTURES, cut into the rectangles the console draws and encoded,
            # before any of them is given a place: a picture the console can draw in one go is
            # one object, and a bigger one is several (see PoseCutter), so the places are handed
            # out in runs rather than one apiece. None of this changes while the pictures are
            # fitted into memory below, so it is done once.
            cutter = PoseCutter.new(@bitmaps)
            @obj_pictures = nodes.to_h { |node| [node.name, sprite_pictures(node, cutter)] }
            check_sprite_count_fits!(nodes)
            check_fade_windows_fit!(nodes)

            # The window twins take the front slots and every real sprite moves back by as
            # many, which changes nothing about what is in front of what (a twin paints
            # nothing, and the sprites keep their order among themselves). It has to be
            # this way round: a twin only holds the effect off a sprite that is BEHIND it.
            front = @placed_fade.place_fade_windows { |name| @obj_pictures.fetch(name).pieces }
            slot_of = {}
            nodes.reverse_each do |node| # last declared is in front, so it takes the front slots
              slot_of[node.name] = front
              front += @obj_pictures.fetch(node.name).pieces
            end
            affine_of = affine_slots(nodes) # ...and which rotation group each turning sprite uses
            prepare_affine(nodes)

            sets = @obj_pictures.values.group_by(&:stored).values.map { |sprites| PictureSet.new(sprites: sprites) }
            one_frame = Set.new # the names of the sprites kept to one frame at a time
            blobs = SpriteLayout::Blobs.new(data_blobs: @blobs, keep_plain: method(:keep_unpacked!))
            painted = nodes.select { |node| painted_sprite?(node) }.to_h { |node| [node.name, node.poses.first] }
            sets.reject! { |set| set.names.any? { |name| painted.key?(name) } } # nothing to give back
            loop do
              @sprite_art = SpriteLayout.new(nodes: nodes, pictures: @obj_pictures, painted: painted,
                                             one_frame: one_frame, blobs: blobs) do |pictures, placed|
                object_record(pictures, slot: slot_of.fetch(pictures.name),
                                        affine_slot: affine_of[pictures.name], **placed)
              end
              break if @sprite_art.fits?(OBJ_TILE_CAPACITY)

              set = pick_set_for_one_frame(sets, one_frame) or raise LoweringError, sprite_art_overflow_message(nodes)
              set.names.each { |name| @blobs.delete(:"__obj_tiles_#{name}") }
              one_frame.merge(set.names)
            end
            @objects = @sprite_art.sprites
            scene_of = nodes.to_h { |node| [node.name, node.scene] }
            painted.each do |name, picture|
              run = @painted_pictures.fetch(picture)
              at = obj_tile_vram_offset + (@objects.fetch(name).tile_index * 32)
              @painted_vram[run.name] = PaintedRun.with_place(@painted_vram[run.name], scene: scene_of.fetch(name), at: at,
                                                              bytes: run.width * run.height / 2, list: run.list,
                                                              what: "image")
            end
            @sprite_art.scene_art.each do |scene, sent|
              sent.each { |blob, *| keep_unpacked!(blob) }
              record_scene_send(scene, art: sent)
            end
          end

          # A SPRITE WHOSE PICTURES DO NOT ALL FIT KEEPS ONE FRAME IN SPRITE MEMORY AT A TIME.
          #
          # Every picture a sprite can show normally sits in the console's 32K of sprite memory
          # from the moment its scene starts, so a character costs every frame of every
          # animation it has, all the time. That is the fast arrangement — showing another
          # frame is pointing at different tiles — and it is what every sprite gets while the
          # pictures fit.
          #
          # When they do not, the sprite with the most to give back is given room for ONE frame
          # instead, and whenever the frame it is showing changes, that frame's pictures are
          # copied into the room out of the cartridge before the sprite is drawn. It is how the
          # console's own retail games put a full cast on screen: The Minish Cap gives each
          # character a slot of sixteen tiles and copies a frame into it when the frame changes.
          # More are given room this way until the pictures fit, and when nothing left would
          # give anything back, that is the friendly error.
          #
          # What it costs is the copy, and only on a frame where the pose changed: a sprite
          # holding still copies nothing, and one animating copies one frame's worth of tiles
          # each time it steps. The cartridge holds every frame at the same stride, blank room
          # included, so finding a frame is one multiply.
          #
          # What is weighed is a SET OF PICTURES and every sprite showing it (see PictureSet),
          # because a set is stored once however many sprites show it — so it gives nothing back
          # until all of them are kept to one frame, and then each costs a frame's room. A pool is
          # the usual case, and is often worth more kept whole. What has to give back is what is
          # over: the pictures every screen shows and the fullest scene's.
          def pick_set_for_one_frame(sets, one_frame)
            scene = @sprite_art.fullest_scene
            best = sets.reject { |set| one_frame.include?(set.names.first) }
                       .select(&:can_keep_to_one_frame?)
                       .max_by { |set| set.bytes_freed_by_one_frame(scene) }
            best if best&.bytes_freed_by_one_frame(scene)&.positive?
          end

          # Out of room for sprite pictures. Name the greediest, since the fix is nearly
          # always one piece of art rather than "fewer sprites" — and say what sharing
          # already saved, because a reader's first question is whether it is doing
          # anything.
          def sprite_art_overflow_message(nodes)
            scene = @sprite_art.fullest_scene
            sprites = @sprite_art.sprites
            worst = nodes.select { |node| node.scene.nil? || node.scene == scene }
                         .max_by(3) { |node| sprites[node.name].tile_units }
            # Name the PICTURES rather than the sprites: an author named the pictures, and a
            # sprite's own name is the framework's.
            named = worst.map { |node| ":#{node.poses.first} (#{sprites[node.name].tile_units * 32})" }
            "The sprites' pictures need #{@sprite_art.bytes} bytes at once, and the console keeps them in " \
              "#{OBJ_TILE_CAPACITY}. Only one scene's are needed at a time. #{fullest_scene_phrase(scene)}, " \
              "and its biggest pictures are #{named.uniq.join(', ')}. When that makes room, a sprite that " \
              "animates keeps only one frame at a time in this memory, and that was not enough. To fix " \
              "this, use fewer pictures there, or smaller ones." \
              "#{" Sharing already saved #{@sprite_art.saved} bytes." if @sprite_art.saved.positive?}"
          end

          # A scene is a routine named after the state it draws, with a prefix of the
          # framework's in front. The author wrote the state.
          def fullest_scene_phrase(scene)
            return "The fullest is what every screen shows" if scene.nil?

            "The fullest is the :#{scene.to_s.delete_prefix('_scene_')} scene"
          end

          # WHICH ROTATION GROUP EACH TURNING SPRITE USES. The console draws a sprite that turns
          # or changes size through one of 32 parameter groups (its "affine slot"); a sprite that
          # does neither keeps its default upright, drawn-size settings, gets no group, and costs
          # nothing. More than 32 is a friendly error — the hardware simply has no more.
          #
          # Worked out here, beside the sprites' places and before any of them is built, because
          # it is the same kind of fact: something the build hands the sprite. It used to be
          # written into each sprite AFTER it was built, which left the drawing reading a field
          # nothing in the construction mentioned.
          def affine_slots(nodes)
            turning = nodes.select { |node| object_transformed?(node) }
            if turning.size > MAX_AFFINE_GROUPS
              raise LoweringError,
                    "#{turning.size} sprites turn or change size, but the console can do that to at " \
                    "most #{MAX_AFFINE_GROUPS} at once. Turn or resize fewer sprites at the same time."
            end
            turning.each_with_index.to_h { |node, group| [node.name, group] }
          end

          # The sine table every turning sprite reads, baked into ROM once. A game with nothing
          # that turns or resizes has no table at all.
          def prepare_affine(nodes)
            return if nodes.none? { |node| object_transformed?(node) }

            @blobs[OBJ_SINE_BLOB] = build_sine_table
          end

          # The sine lookup table as ROM bytes: sin(d°) in 8.8 fixed point for d in
          # 0..449, each a signed 16-bit little-endian value (256 = 1.0, -256 = -1.0).
          # Built from the same helper the reference interpreter reads, so the two cannot
          # turn a sprite through different numbers.
          def build_sine_table
            (0...OBJ_SINE_ENTRIES).map { |degrees| Affine.sine(degrees) }.pack("s<*")
          end

          def check_fade_windows_fit!(nodes)
            spent = object_count(nodes)
            total = spent + twin_object_count
            return if total <= MAX_SPRITES

            raise LoweringError,
                  "#{@placed_fade.count} sprites are kept out of a fade, and each one needs a second " \
                  "slot in the sprite table to hold the fade off it. That is #{total} slots with the " \
                  "#{spent} sprites themselves, and the console draws #{MAX_SPRITES} at once. " \
                  "To fix this, keep fewer sprites out of the fade, or use fewer sprites."
          end

          # Out of places in the console's sprite table. A game whose sprites are one object
          # each gets the plain count; one with a picture too big for a single object gets
          # told which sprites are spending several, since that is the part nobody wrote.
          def check_sprite_count_fits!(nodes)
            spent = object_count(nodes)
            return if spent <= MAX_SPRITES

            raise LoweringError,
                  "This game needs #{spent} sprites at once. The console draws #{MAX_SPRITES} at most." \
                  "#{big_sprites_sentence(nodes)}"
          end

          # Which sprites are drawn as more than one object, said in the author's own names
          # — the pictures, since a sprite's own name is the framework's.
          def big_sprites_sentence(nodes)
            big = nodes.select { |node| @obj_pictures.fetch(node.name).pieces > 1 }
            return " To fix this, use fewer sprites." if big.empty?

            named = big.map { |node| ":#{node.poses.first} (#{@obj_pictures.fetch(node.name).pieces} each)" }
            " A picture bigger than #{OBJ_MAX_SIDE}x#{OBJ_MAX_SIDE} is drawn as several sprites at once. " \
              "These pictures spend more than one: #{named.uniq.join(', ')}. To fix this, draw them " \
              "smaller, or use fewer sprites."
          end

          # Sort the sprites' colors into the table they all read from.
          #
          # A sprite that draws from few enough colors is stored half a byte a pixel and
          # reads one BANK of that table — sixteen colors of its own, shared with nothing
          # unless it happens to use the same ones. It costs half the sprite memory of the
          # same picture stored the old way, and nothing about the program says so: the
          # count of colors in the art decides it. A sprite with more colors than a bank
          # holds keeps the whole-byte storage and reads across the whole table, exactly
          # as every sprite did before this.
          #
          # The unit is the SPRITE, not the picture, because which way the console reads a
          # sprite is one bit in that sprite's own table entry — so all of its poses are
          # stored the same way, out of one bank.
          #
          # THE SIXTEEN GROUPS TAKE TURNS BY SCENE, the way the pictures do. The sprites every
          # screen shows are laid out first and keep their groups throughout; each scene's own
          # go on from that into the same groups as every other scene's (see
          # PaletteBanks#allocate_after), and that scene's table is sent as it takes over (see
          # Drawing#emit_scene_art_upload). So the budget is one screen's, not the game's. A game
          # whose sprites belong to no scene has the one table, exactly as before.
          def build_shared_object_palette(nodes)
            everywhere = nodes.reject(&:scene)
            @obj_banks = { nil => object_banks(everywhere) }
            scene_palettes = {}
            nodes.filter_map(&:scene).uniq.each_with_index do |scene, index|
              in_scene = nodes.select { |node| node.scene == scene }
              @obj_banks[scene] = object_banks(in_scene, after: @obj_banks[nil], scene: scene)
              scene_palettes[scene] = :"__obj_palette_scene_#{index}"
            end
            nodes.each { |node| recolor_banks_fit!(node) }

            # Every table the same length, so walking the one on screen (a tint, a fade that moves
            # the colours) is the same walk whichever it is.
            tables = @obj_banks.transform_values(&:entries)
            units = tables.values.map(&:size).max
            tables.transform_values! { |colors| colors + ([0] * (units - colors.size)) }
            @obj_palette_blob = :__obj_palette
            @obj_palette_units = units
            @blobs[@obj_palette_blob] = tables.fetch(nil).pack("v*")
            scene_palettes.each do |scene, blob|
              @blobs[blob] = tables.fetch(scene).pack("v*")
              keep_unpacked!(blob)
              record_scene_send(scene, obj_palette: blob)
            end
          end

          # The colour table +nodes+ draw from, going on from +after+ for a scene's own.
          def object_banks(nodes, after: nil, scene: nil)
            pictures = nodes.map do |node|
              colors = []
              node.poses.each do |image|
                bmp = @bitmaps.fetch(image) do
                  raise LoweringError,
                        "sprite object #{node.name.inspect} references undefined image #{image.inspect}"
                end
                scan_object_colors(bmp, colors)
              end
              PaletteBanks::Picture.new(key: node.name, colors: colors, authored: authored_palette(node))
            end
            pictures += recolor_pictures(nodes)
            PaletteBanks.new(pictures, after: after)
          rescue PaletteBanks::Overflow
            raise LoweringError, object_colors_overflow_message(pictures, scene)
          end

          # The table a sprite's colours are in: its scene's, or the one every screen shows.
          def obj_banks_for(node) = @obj_banks.fetch(node.scene)

          # THE OTHER LISTS A SPRITE CAN BE DRAWN WITH, each a bank of its own.
          #
          # Which colours a sprite's pixels show is the bank named in its table entry, and
          # nothing else — the pixels themselves are places in a bank. So drawing a sprite with
          # another list is naming another bank, laid out the way the sprite's own is: each list
          # goes in as a table no picture draws from, pinned as written, and two sprites (or the
          # thirty slots of a pool) that name the same list share its bank.
          def recolor_pictures(nodes)
            nodes.flat_map do |node|
              node.recolors.each_with_index.map do |list, index|
                PaletteBanks::Picture.new(key: [:recolor, node.name, index], colors: [], authored: list)
              end
            end
          end

          # A sprite drawn with other lists has to be stored the small way, and so does every
          # list — a bank is the only thing its table entry can name. When the banks ran out,
          # one of them was stored the big way instead, and that is a friendly error.
          def recolor_banks_fit!(node)
            return if node.recolors.empty?

            keys = [node.name, *node.recolors.each_index.map { |index| [:recolor, node.name, index] }]
            return if keys.all? { |key| obj_banks_for(node).placement(key).narrow? }

            raise LoweringError,
                  "#{whose_sprites(node.scene)} and the lists of colors they draw with need more than the " \
                  "#{PaletteBanks::BANKS} groups of colors the console holds for sprites. Each different list " \
                  "takes one group, and so does each sprite with different colors.#{shared_sprites_note(node.scene)} " \
                  "To fix this, tell sprites to draw_with fewer different lists, or give more sprites the same " \
                  "`colors:` list."
          end

          # Which sprites ran out. Only one scene's sprites are on screen at a time, so a scene
          # is measured on its own and named — "the sprites" would send the author counting
          # every sprite in the game.
          def whose_sprites(scene)
            scene ? "The sprites of the scene :#{IR::Modes.strip_scene_prefix(scene)}" : "The sprites"
          end

          # ...and that a scene's count includes the sprites every scene shows, when there are any.
          def shared_sprites_note(scene)
            return "" unless scene && @picture.objects.any? { |node| node.scene.nil? }

            " This count includes the sprites that every scene shows."
          end

          # The bank each of a sprite's other lists landed in, in the order the program counts
          # them, then its own. nil for a sprite never drawn with another list.
          #
          # The draw reads it as a table of the bank already shifted to where the table entry
          # carries it, one word each, so a frame picks one with a single read. Sprites whose
          # lists landed in the same banks — every slot of a pool — share the one table.
          def sprite_recolor_bank_table(node)
            return nil if node.recolors.empty?

            banks = [*node.recolors.each_index.map { |index| obj_banks_for(node).placement([:recolor, node.name, index]).bank },
                     obj_banks_for(node).placement(node.name).bank]
            blob = :"__recolor_banks_#{banks.join('_')}"
            @blobs[blob] = banks.map { |bank| bank << OBJ_BANK_SHIFT }.pack("V*")
            keep_unpacked!(blob) # read from the middle, by the list the game picked
            RecolorBanks.new(table: blob, own: banks.length - 1)
          end

          # The table a sprite's art came with, where its poses all name the same one.
          # Art made somewhere else on this console arrives as numbers picking out of its
          # own sixteen, so the order is the whole point and the framework must not
          # rearrange it. Poses that disagree is a friendly error rather than a silent
          # choice of one of them.
          def authored_palette(node)
            by_table = node.poses.group_by { |image| @bitmaps.fetch(image).colors }
            return by_table.keys.first if by_table.size == 1

            named = by_table.values.map { |images| ":#{images.first}" }.first(3).join(" and ")
            raise LoweringError,
                  "The pictures one sprite shows were given different `colors:` lists (#{named}). All the " \
                  "pictures a sprite shows are drawn from one table of colors. So give them all the same " \
                  "list, or give none of them a list and the framework works the table out."
          end

          # Every non-see-through color in a sprite picture, first-seen order, deduped.
          def scan_object_colors(bmp, colors)
            seen = colors.to_h { |color| [color, true] }
            (bmp.width * bmp.height).times do |i|
              next unless bmp.drawn_at?(i)

              color = bmp.color_at(i)
              next if seen[color]

              seen[color] = true
              colors << color
            end
          end

          # Nothing fits: even stored the big way, the sprites name more colors than the
          # console's sprite table holds. Name the greediest pictures, since "255 colors"
          # on its own leaves the author hunting through their own art.
          def object_colors_overflow_message(pictures, scene = nil)
            worst = pictures.max_by(3) { |picture| picture.colors.size }
            named = worst.map { |picture| ":#{picture.key} (#{picture.colors.size})" }.join(", ")
            "#{whose_sprites(scene)} use more colors between them than the console's sprite table holds " \
              "(#{PaletteBanks::CAPACITY}, one of which means see-through).#{shared_sprites_note(scene)} The sprites " \
              "with the most colors are #{named}. Draw them from fewer colors, or use fewer sprites at once."
          end

          # ONE SPRITE'S PICTURES, encoded once for the whole build (see SpritePictures).
          #
          # Where each pose's tiles begin, in the 32-byte units a tile number counts in —
          # taken from the bytes already written rather than from a tile count, since a
          # picture stored the big way is two units to the tile. One number per piece, and
          # a mirrored pose adds nothing and points back at the pose it mirrors.
          #
          # A PIECE THAT HOLDS TILES ALREADY WRITTEN IS NOT WRITTEN AGAIN, and this is the
          # one saving a game written straight against the console cannot have. An object
          # reads a CONTIGUOUS run of tiles, so by hand every frame of an animation has to
          # be its own run and a part that did not move between two frames is kept twice.
          # A pose built as a table of PIECES is under no such rule — each piece names its
          # own first tile — so the head and the still arm of a walk cycle are stored once
          # and every frame points at them. Judged on the encoded bytes, which say the
          # pixels and the size of the box together, so two pieces match only when they
          # would draw the same thing.
          def sprite_pictures(node, cutter)
            # A painted picture is kept whole, never trimmed to what it draws: it draws nothing
            # until the game paints it, and then whatever the game paints.
            cut = cutter.cut(node, transformed: object_transformed?(node) || painted_sprite?(node))
            mirrors = cut[:mirrors]
            boxes = cut[:boxes]
            pieces = boxes.map(&:size).max
            place = obj_banks_for(node).placement(node.name)
            encoded = node.poses.each_with_index.map do |image, k|
              boxes[k].map { |box| cutter.encode(@bitmaps.fetch(image), place, box) } unless mirrors[k]
            end
            stored = +"".b
            starts = []
            repeats = 0
            written = {} # the bytes of every run so far -> the unit it starts at
            node.poses.each_index do |k|
              if mirrors[k]
                starts << starts[mirrors[k]].dup # point it at the pose it mirrors and store nothing
                next
              end
              starts << encoded[k].map do |bytes|
                at = written[bytes]
                if at
                  repeats += bytes.bytesize # already written: point at it, and say so
                else
                  at = written[bytes] = stored.bytesize / 32
                  stored << bytes
                end
                at
              end
            end
            pad_object_pieces(boxes, starts, stored, place, pieces)
            SpritePictures.new(node: node, place: place, boxes: boxes, mirrors: mirrors, encoded: encoded,
                               stored: stored, starts: starts, repeats: repeats,
                               width: cut[:width], height: cut[:height],
                               animates: const_int(node.pose).nil? && node.poses.length > 1)
          end

          # The record the drawing reads, from what either layout worked out. +starts+ is where
          # each pose's pieces begin, counted from +tile_index+, for the pose table of a sprite
          # whose poses are not alike.
          def object_record(pictures, slot:, affine_slot:, starts:, alike:, per_pose:, tiles:, tile_units:,
                            tile_index:, frames: nil, frame_bytes: nil)
            node = pictures.node
            name = node.name
            place = pictures.place
            boxes = pictures.boxes
            mirrors = pictures.mirrors
            # Poses that trimmed alike carry their one size in the sprite's own entry. Poses
            # that differ carry NOTHING here — the size and shape come out of the table with
            # the rest of what changes, so these bases must not also hold the canvas's.
            shape, size = alike ? OBJ_SIZES.fetch(boxes.first.first.last(2)) : [0, 0]
            Sprite.new(
              slot: slot,
              pieces: pictures.pieces, # how many of the console's 128 places this one sprite takes
              tiles: tiles, tile_units: tile_units, # sprite memory counts in 32-byte units
              scene: node.scene, # sent when that scene takes over, rather than at boot
              tile_index: tile_index, # this sprite's base tile number
              frames: frames, frame_bytes: frame_bytes, # every frame in the cartridge, for one kept to one frame
              per_pose: per_pose,    # stride to the next pose's tiles
              pose: node.pose,     # the run-time pose selector (which pose to show)
              pose_count: node.poses.length, # how long one piece's row of the pose table is
              # Every pose trimmed the same way is the ordinary case — a walk cycle drawn
              # inside one outline — and it keeps the plain draw: one size in the sprite's
              # own entry, one stride between poses. Poses that came out DIFFERENT sizes, or
              # that are another pose mirrored, carry a table instead (#object_pose_table),
              # read once a frame.
              alike: alike,
              mirrors: mirrors, # which poses are drawn backwards, so the draw knows to say so
              pose_table: alike ? nil : :"__poses_#{name}",
              pose_words: alike ? nil : object_pose_table(name, boxes, starts, mirrors, tile_index,
                                                          pictures.pieces),
              # Where the first pose sits inside the canvas it was drawn on. The sprite is
              # drawn that much further along so the picture does not move; for poses that
              # differ it comes out of the table instead.
              offset_x: boxes.first.first[0], offset_y: boxes.first.first[1],
              width: pictures.width, height: pictures.height,
              x: node.x, y: node.y, active: node.active, # the live position/visibility operands
              angle: node.angle,   # the rotation operand (a constant 0 unless the sprite turns)
              scale: node.scale,   # the size operand (the "as drawn" constant unless it resizes)
              transformed: object_transformed?(node), # draw it through an affine group rather than upright?
              scales: object_scales?(node),           # ...and does that group need a size worked out?
              affine_slot: affine_slot,               # ...which group, or nothing for an upright one
              # A sprite in the see-through layer carries the blend in its own entry, so it
              # rides here rather than costing anything at draw time.
              attr0_base: (place.narrow? ? 0 : OBJ_256_COLOR) | (shape << 14) |
                (see_through_object?(node) ? LayerBlend::OBJ_SEMI_TRANSPARENT : 0),
              attr1_base: size << 14,
              # attr2's top bits carry how deep the sprite sits, and — for a sprite stored
              # the small way — which bank of sixteen colors it draws from. The depth stays
              # 0 (the front) in every picture where the sprites are over all the scenery,
              # which is every picture that names no layers.
              attr2_base: (hardware_priority(name) << OBJ_PRIORITY_SHIFT) |
                (place.narrow? && node.recolors.empty? ? place.bank << OBJ_BANK_SHIFT : 0),
              recolor: node.recolor, recolor_banks: sprite_recolor_bank_table(node),
            )
          end

          def object_pose_table(name, boxes, starts, mirrors, tile_unit, pieces)
            blob = :"__poses_#{name}"
            words = (0...pieces).flat_map do |piece|
              boxes.each_with_index.map do |list, k|
                x0, y0, w, h = list[piece]
                shape, size = OBJ_SIZES.fetch([w, h])
                (tile_unit + starts[k][piece]) | (shape << 10) | (size << 12) | (x0 << 14) | (y0 << 22) |
                  (mirrors[k] ? POSE_MIRRORED : 0)
              end
            end
            @blobs[blob] = words.pack("V*")
            # Kept unpacked: the draw reads one word straight out of the middle of this,
            # picked by the pose the game is showing, and there is no seeking into a
            # compressed stream.
            keep_unpacked!(blob)
            words
          end

          # A POSE THAT DRAWS LESS THAN ANOTHER HAS FEWER PIECES TO DRAW IT WITH, and the
          # frame must not have to test how many. So the short poses are filled out with a
          # piece that draws NOTHING: one blank tile the whole sprite shares, sitting in the
          # table like any other piece and composited by the console as nothing at all. That
          # costs one tile of picture memory once, against a test on every piece of every
          # frame — and it means the draw is the same code for every piece.
          def pad_object_pieces(boxes, starts, tiles, place, pieces)
            return unless boxes.any? { |list| list.size < pieces }

            blank = tiles.bytesize / 32
            tiles << ("\0" * (place.narrow? ? 32 : 64)).b
            boxes.each_with_index do |list, k|
              (pieces - list.size).times do
                list << [0, 0, TILE_PX, TILE_PX].freeze # one tile at the corner, drawing nothing
                starts[k] << blank
              end
            end
          end

          # One piece's poses, as the map above. A sprite whose poses all trimmed alike was moved one
          # distance whatever it is showing and carries no words at all; one whose poses differ
          # carries a word each, with the distance in there among the rest of what changes (see
          # #object_pose_table).
          def pose_offsets(sprite, piece)
            words = sprite.pose_words&.slice(piece * sprite.pose_count, sprite.pose_count)
            alike = [sprite.offset_x, sprite.offset_y]
            (0...sprite.pose_count).to_h do |pose|
              word = words&.at(pose)
              [pose_key(sprite, pose, word), word ? decode_pose_offset(word) : alike]
            end
          end

          # WHAT TELLS ONE POSE FROM ANOTHER once the cartridge is built, which has two answers.
          #
          # For nearly every sprite it is what the console's own row says — the first tile it draws
          # and whether it is drawn backwards — because every pose has a place in sprite memory of
          # its own: poses that trimmed alike sit an even stride apart, so the tile is worked out,
          # and poses that differ carry their tile in their word. Two poses in one place answering
          # to the same tile and the same direction are the same stored picture and were moved the
          # same distance, so nothing is lost where those collapse together.
          #
          # A sprite KEPT TO ONE FRAME at a time has no such place, and that is the whole of what
          # this used to get wrong. Every pose of one is copied into the same room, so the row says
          # that one tile whichever pose is in it and all of them collapsed onto a single entry —
          # every pose then answered to whichever trim was written down last, and the position read
          # back was out by the difference for all the others. Right on most frames of a cycle and
          # wrong on a few, which is the worst way for a number to be wrong. So it is known by its
          # pose NUMBER instead; GBA#streamed_sprite_pose_vars says where that number is read from.
          def pose_key(sprite, pose, word)
            return pose if sprite.frames
            return decode_pose_tile(word) if word

            [sprite.tile_index + (pose * sprite.per_pose), false]
          end

          def decode_pose_tile(word) = [word & 0x3FF, word.anybits?(POSE_MIRRORED)]

          def decode_pose_offset(word) = [(word >> 14) & 0xFF, (word >> 22) & 0xFF]

          # What the sprites cost out of the 128 the console draws at once. Worth a line only
          # where it is not simply one each: a picture too big for a single object is drawn as
          # several, and a fade placed in the stack shadows a sprite with a window per object.
          def object_count_report
            return nil if @objects.empty?

            big = @picture.objects.filter_map do |node|
              pieces = @objects[node.name].pieces
              [node.poses.first, pieces] if pieces > 1
            end
            twins = twin_object_count
            return nil if big.empty? && twins.zero?

            RubyGBA::Diagnostics::VideoMemory::Objects.new(used: object_count(@picture.objects) + twins,
                                              capacity: MAX_SPRITES, big: big, twins: twins)
          end

          def sprite_memory_report
            return nil if @objects.empty?

            small = @objects.count { |name, _obj| @obj_pictures.fetch(name).place.narrow? }
            # A sprite that stores no pictures of its own is either showing another sprite's or
            # keeping one frame here at a time, and those are different savings to report.
            one_frame = @objects.count { |_name, obj| obj.frames }
            shared = @objects.count { |_name, obj| obj.tiles.nil? && obj.frames.nil? }
            RubyGBA::Diagnostics::VideoMemory::Area.new(used: @sprite_art.bytes, capacity: OBJ_TILE_CAPACITY,
                                           small: small, big: @objects.size - small,
                                           saved: sprite_memory_saved, shared: shared,
                                           one_frame: one_frame, repeats: @sprite_art.repeats)
          end

          # What the same pictures would have cost stored the old way: a small one is exactly
          # half the size, so the saving is its own size again. A sprite sharing another's
          # pictures costs nothing either way and is not counted twice — what sharing saved
          # is its own number.
          def sprite_memory_saved
            @objects.sum do |name, obj|
              # A sprite showing another's pictures costs nothing either way. One keeping a
              # frame at a time does take room here, and its room is half the size too.
              next 0 if (obj.tiles.nil? && obj.frames.nil?) || !@obj_pictures.fetch(name).place.narrow?

              obj.tile_units * 32
            end
          end

          # The tiles' half of the scenery's memory. What is LEFT is the number that matters
          # and it is not a fixed budget any more: the maps come down from the top of the
          # same 64K, so what a tileset has is what the maps did not take.
          def tile_memory_report
            return nil if @bg_shared.nil?

            used = @bg_shared.tile_bytes
            RubyGBA::Diagnostics::VideoMemory::Area.new(used: used, capacity: used + @vram.free_bytes,
                                           small: @bg_shared.small, big: @bg_shared.big,
                                           saved: @bg_shared.saved, shared: @bg_shared.shared,
                                           skipped: @bg_shared.skipped)
          end
        end
      end
    end
  end
end
