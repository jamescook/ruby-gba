# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Native
        # THE PICTURE, written as C: the drawing statements, a scene taking the screen over, and
        # the art they draw with. Mixed into Lowering, beside the logic.
        #
        # The drawing itself is done by runtime/rg_screen.c, a port of the interpreter's picture;
        # what this half does is say it in the interpreter's order and hand over the art. All of
        # the art is worked out HERE, in Ruby, with the interpreter's own readings of it — which
        # pixel of a tile shows what is behind, which color a pixel of a picture is — so the C
        # never has a second opinion about a pixel.
        module Picture
          # The kinds of screen, as rg_screen.h numbers them.
          SCREEN_KINDS = Ractor.make_shareable({ bitmap: 0, tiled: 1, rotozoom: 2 })

          # rg_screen.h's own numbers: whose a background is (RG_EVERY_SCENE, RG_NEVER_ARRIVES),
          # a background that named no layer, a pixel of a sprite's picture that is not drawn,
          # a cell of a map with no tile, and how many backgrounds and sprites there is room for.
          EVERY_SCENE = -1
          NEVER_ARRIVES = -2
          NO_LAYER = -1
          NOT_DRAWN = -1
          # The most a drawn pixel can be: fifteen bits of colour, so a picture's pixels fit in
          # sixteen signed bits beside NOT_DRAWN.
          MAX_COLOR = 0x7FFF
          CELL_EMPTY = -1
          # How many numbers say one map (RG_MAP_FIELDS): where its cells start, its columns, its
          # rows, and the columns and rows of the grid it comes round at.
          MAP_FIELDS = 5
          MAX_BACKGROUNDS = 64
          MAX_SPRITES = 512
          # A thing in no see-through layer (RG_SOLID), and how many of those layers there is
          # room for (RG_MAX_SEE_THROUGH).
          SOLID = -1
          MAX_SEE_THROUGH = 16

          # The kinds the interpreter's picture is rebuilt whole every frame for (see
          # Reference#collect_definitions and #run, and #rebuilt_every_frame? for the rest of the
          # rule).
          REBUILT_FOR = %i[tile_run scroll_background scroll_rows affine_background set_tile show_map
                           background_colors pixelate].freeze

          # A sprite the game leaves as drawn whatever size the picture's blocks are (RG_NOT_IN_BLOCKS).
          NOT_IN_BLOCKS = -1
          # A tile that is a picture and not one the game paints, and a background with no
          # painted tile (RG_NOT_PAINTED).
          NOT_PAINTED = -1
          # How many places a run's colors have: a painted pixel is four bits.
          PLACES_IN_RUN_COLORS = 16
          # A painted tile's side, and how many pixels that makes (Reference::RUN_TILE_BYTES is
          # half of them, two pixels to a byte).
          RUN_TILE_SIDE = 8
          RUN_TILE_PIXELS = RUN_TILE_SIDE * RUN_TILE_SIDE

          private

          def prepare_picture
            @stacking = Stacking.picture(@program)
            @handover = SceneHandover.of(@program)
            @fading = Fading.resolve(@program)
            # A background's name -> the entry that keeps what the game does to it. That is the
            # last one declared by the name, in the order the program declares them, as the
            # interpreter's @bg_by_name keeps it; the stack's order can differ once layers are named.
            @last_declared = @program.walk.select { |node| node.kind == :background }.to_h { |bg| [bg.name, bg] }
            @backgrounds = @last_declared.transform_values { |bg| entry_of(bg) }
            @objects = by_name(@program.walk, :object)
            @sprites = @objects.each_key.with_index.to_h # sprite name -> the number rg_screen.c knows it by
            @drawn_sprites = DrawnSprites.new(@program) # the names a run says its sprites by
            @left_out_of_blocks = names_left_out_of_blocks
            # The runs of tiles and the pictures the game paints from lists as it runs, and the
            # number rg_screen.c knows each by.
            @tile_runs = by_name(@program.walk, :tile_run)
            @run_numbers = @tile_runs.each_key.with_index.to_h
            # The lists of sprite colors that hold other colors as the game runs.
            @color_lists = by_name(@program.walk, :color_list)
            # The layers the game can be seen through, and the number rg_screen.c knows each by.
            @see_through = SeeThrough.layers(@program)
            @see_through_numbers = @see_through.each_with_index.to_h { |layer, number| [layer.name, number] }
            # By name, the furthest forward anything of that name was declared (see #fade_place).
            @fade_places = (@stacking.scenery + @stacking.objects).group_by(&:name).transform_values do |named|
              named.filter_map { |thing| @stacking.stack.index(thing.layer) }.max || NO_LAYER
            end
            # The patches of picture saved under sprites on a painted screen, as the program
            # declared them, and the number rg_screen.c knows each by.
            @patches = by_name(@program.walk, :backing_buffer)
            @patch_numbers = @patches.each_key.with_index.to_h
            @images = {} # [picture name, the list of colors it is drawn with or nil] -> its number in rg_game_images
            @drawing_arrays = [] # constant arrays the drawing statements need, written before the routines
            refuse_unsupported_picture!
          end

          # --- what this backend cannot draw yet, said before anything is written ---

          def refuse_unsupported_picture!
            nodes = @program.walk.to_a
            refuse_picture!("more than #{MAX_SEE_THROUGH} see-through layers") if @see_through.size > MAX_SEE_THROUGH
            refuse_picture!("more than #{MAX_BACKGROUNDS} backgrounds") if @stacking.scenery.length > MAX_BACKGROUNDS
            # Two backgrounds with one name share the colors they are told (RG_BG_KEPT_BY). The
            # interpreter works out what a number names from the first of the two it paints and
            # keeps that for both (Reference#background_swap), where the C works it out for each.
            shared = @stacking.scenery.map(&:name).tally.select { |_, times| times > 1 }.keys
            told = nodes.select { |n| n.kind == :background_colors }.map(&:name) & shared
            refuse_picture!("two backgrounds with one name told other colors (#{told.first})") unless told.empty?
            refuse_picture!("more than #{MAX_SPRITES} sprites") if @sprites.size > MAX_SPRITES
          end

          # Reference#place_blocks: where this program's blocks stop. A program that pixelates
          # gets one place for them, and one that names two is refused in the words every backend
          # refuses it in. What comes back is the names of everything in the layer its statements
          # are placed under and in front of it, which stay as drawn whatever the size; no names
          # for a program that pixelates the whole picture; and nil for one that never pixelates.
          def names_left_out_of_blocks
            places = Blocks.places(@program)
            raise LoweringError, Blocks.several_places_message(places) if places.size > 1
            return nil if places.empty?

            places.first ? Stacking.at_or_above(@stacking, places.first).map(&:name) : []
          end

          # Reference#in_blocks?, all of it but the size: is this background or sprite drawn in
          # blocks while the picture is shown in them? By its name, as the interpreter asks.
          def shown_in_blocks?(thing) = !@left_out_of_blocks.nil? && !@left_out_of_blocks.include?(thing.name)

          def refuse_picture!(what)
            raise LoweringError, "this program uses #{what}, which #{build_name} cannot draw yet. " \
                                 "The cartridge build can."
          end

          def constant?(node, value) = node.kind == :int && node.value == value

          # Reference#collect_definitions and #run: whether the whole view is rebuilt every
          # frame — for scenery that can look different next frame, a fade placed in the stack,
          # what is seen through a layer changing while nothing moves, or scenery a named layer
          # puts in front of a sprite — rather than sprites drawn straight onto a picture that
          # stays.
          def rebuilt_every_frame?
            @program.walk.any? { |node| REBUILT_FOR.include?(node.kind) || (node.kind == :fade && node.under) } ||
              see_through_picture_changes? ||
              Stacking.scenery_over_objects?(@stacking.depths, scenery: @stacking.scenery, objects: @stacking.objects)
          end

          # Reference#see_through_picture_changes?: an amount the game works out, or a fade the
          # display itself does, which holds a see-through layer solid for as long as it is on.
          def see_through_picture_changes?
            return false if @see_through.empty?

            @program.walk.any? do |node|
              node.kind == :see_through || (node.kind == :fade && !@fading.palette_walk?(node))
            end
          end

          # --- the art, for rg_screen.c ---

          def picture_data
            [*image_arrays, *background_arrays, *see_through_arrays, sprite_fade_places_array, *sprite_block_arrays,
             *run_arrays,
             runtime_array("picture_sizes", "int32_t",
                    [@stacking.scenery.length, @stacking.depths.count, @handover.always_up.scenery.length,
                     rebuilt_every_frame? ? 1 : 0, @see_through.size,
                     Modes.resolve(@program).crosses_display_systems? ? 1 : 0, Blocks::LARGEST,
                     @tile_runs.size, @tile_runs.each_value.sum { |run| run_pixels(run) }, @images.size]),
             runtime_array("always_up", "int32_t", @handover.always_up.scenery.map { |bg| entry_of(bg) }),
             runtime_array("sines", "int32_t", (0...450).map { |degrees| Affine.sine(degrees) }),
             runtime_array("turn_rules", "int32_t", [Build::SCALE_ONE, Affine::ONE_TH, Affine::MAX, Affine::MIN_SCALE])]
          end

          # An array of numbers rg_screen.c reads by name (rg_game_ and +what+).
          def runtime_array(what, type, values) = C::ConstArray.new(name: @names.own(what), type: type, values: values, exported: true)

          # Every picture a sprite can show, once for each list of colors it is drawn with. A pixel
          # is fifteen bits of colour or -1 for see-through, so sixteen signed bits hold it: a
          # game's pictures are most of its program, and four bytes a pixel doubled them.
          def image_arrays
            pixels = []
            info = []
            @images.each_key do |name, colors|
              image = picture_named(name)
              info.push(pixels.length, image.width, image.height)
              drawn = sprite_pixels(image, colors)
              if drawn.any? { |pixel| pixel > MAX_COLOR }
                raise LoweringError, "picture #{name.inspect} holds a pixel past the fifteen bits a colour has, " \
                                     "so #{build_name} cannot make it."
              end
              pixels.concat(drawn)
            end
            [runtime_array("image_pixels", "int16_t", pixels), runtime_array("images", "int32_t", info), *sprite_name_arrays]
          end

          # Reference#sprites says each sprite it drew by two names: the one the game declared it
          # under, and the one the author gave the picture it shows, whatever colors that is
          # drawn in. So each sprite and each picture has the number of its name (DrawnSprites),
          # for a run to say what it drew.
          def sprite_name_arrays
            [runtime_array("sprite_names", "int32_t", @objects.each_value.map { |obj| @drawn_sprites.name_number(obj.declared) }),
             runtime_array("image_pictures", "int32_t", @images.each_key.map { |name, _| @drawn_sprites.picture_number(name) })]
          end

          # For every sprite, where the boxes it is put into blocks by start, or NOT_IN_BLOCKS for
          # one the game leaves as drawn; and the boxes themselves (see rg_screen.h for the layout).
          def sprite_block_arrays
            boxes = []
            starts = @objects.each_value.map do |obj|
              next NOT_IN_BLOCKS unless shown_in_blocks?(obj)

              boxes.length.tap { boxes.concat(boxes_by_picture(obj)) }
            end
            [runtime_array("sprite_blocks", "int32_t", starts), runtime_array("sprite_boxes", "int32_t", boxes)]
          end

          # Reference#paint_object_in_blocks and #object_boxes: one sprite's pictures, each with
          # the boxes a console draws it as, which is the cut every backend asks SpriteCut for. A
          # sprite that turns or resizes is put into blocks whole and lists none. The interpreter
          # finds a pose's boxes by the first place its picture has among the sprite's poses, so
          # a picture is listed once.
          def boxes_by_picture(obj)
            return [0] if turns_or_resizes?(obj)

            canvas = picture_named(obj.poses.first)
            whole = obj.poses.any? { |pose| painted_picture?(pose) }
            cut = SpriteCut.new(sprite_pictures).cut(obj.poses, width: canvas.width, height: canvas.height, whole: whole)[:boxes]
            pictures = obj.poses.uniq
            [pictures.length, *pictures.flat_map do |pose|
              boxes = cut.fetch(obj.poses.index(pose))
              [@drawn_sprites.picture_number(pose), boxes.length, *boxes.flatten]
            end]
          end

          # Every picture the program defines, as SpriteCut reads one.
          def sprite_pictures
            @sprite_pictures ||= @data.select { |_, node| node.kind == :bitmap }.transform_values { |node| Assets::Image.of(node) }
          end

          # Reference#painted_picture?: is this picture one the game paints from a list as it runs?
          def painted_picture?(name) = @program.walk.any? { |node| node.kind == :tile_run && node.picture == name }

          # A sprite picture's pixels as the interpreter draws them (Reference#blit_image): the
          # number the picture stores, the color +colors+ puts in its place when the sprite is
          # drawn with that list (Assets::Recolor), or NOT_DRAWN where it is see-through.
          def sprite_pixels(image, colors)
            recolor = colors && Assets::Recolor.of(image, colors)
            Array.new(image.width * image.height) do |at|
              next NOT_DRAWN unless image.drawn_at?(at)

              recolor ? recolor.color_for(at, image.raw_at(at)) : image.raw_at(at)
            end
          end

          # A picture the game paints from a list is see-through all over until its first copy
          # (Reference#collect_definitions), which is the picture written into the game for it.
          def picture_named(name)
            painted = @tile_runs.each_value.find { |run| run.picture == name }
            return painted_image(painted, Array.new(run_pixels(painted), 0), width: painted.width, height: painted.height) if painted

            Assets::Image.of(@data.fetch(name) { raise LoweringError, "a sprite shows the picture #{name.inspect}, which is not defined" })
          end

          # --- tiles and pictures the game paints from a list (Reference#copy_run_tiles) ---

          # How many pixels a run keeps: its picture's, or its tiles'.
          def run_pixels(run) = run.picture ? run.width * run.height : run.tiles.length * RUN_TILE_PIXELS

          # Reference#run_picture_from_places: a painted picture as everything that draws one
          # reads it, +places+ being each pixel's place in the run's colors. It keeps the run's
          # list as its own, which is how a swap of colors finds it.
          def painted_image(run, places, width:, height:)
            pixels = places.map { |place| place.zero? ? Graphics::Image::TRANSPARENT : run.colors.fetch(place, 0) }
            Assets::Image.new(width: width, height: height, transparent: Graphics::Image::TRANSPARENT,
                              pixels: pixels.pack("v*"), colors: run.colors, places: places.pack("C*"))
          end

          # A strip with one pixel at each place a run's colors have. What a painted pixel shows
          # depends on its place and nothing else, so reading this strip the way a tile or a
          # sprite's picture is read gives the color of every place at once, by the same rules
          # as art that was drawn ahead of time.
          def every_place_of(run) = painted_image(run, (0...PLACES_IN_RUN_COLORS).to_a, width: PLACES_IN_RUN_COLORS, height: 1)

          # The run that paints the tile +name+, or nil for a tile that is a picture.
          def run_painting(name) = @tile_runs.each_value.find { |run| run.tiles.include?(name) }

          # Each run as rg_screen.h's fields, and for each run that is a sprite's picture the
          # images that are that picture, one for each list of colors it is drawn with, with the
          # color each place shows in it (#sprite_pixels, asked of every place at once).
          def run_arrays
            pixels = 0
            images = []
            runs = @tile_runs.each_value.flat_map do |run|
              start = pixels
              pixels += run_pixels(run)
              next [run.tiles.length, 0, 0, start, 0, 0] unless run.picture

              first = images.length / (PLACES_IN_RUN_COLORS + 1)
              shown_as = @images.select { |(name, _), _| name == run.picture }
              shown_as.each { |(_, colors), number| images.push(number, *sprite_pixels(every_place_of(run), colors)) }
              [0, run.width, run.height, start, first, shown_as.size]
            end
            [runtime_array("tile_runs", "int32_t", runs), runtime_array("run_images", "int32_t", images)]
          end

          # Reference#exec_copy_tiles and what a scene arriving does with each run it shows.
          def tile_copy(run)
            eval_call("rg_tiles_copy", C::Int.new(@run_numbers.fetch(run.name)), C::AddressOf.new(list(run.list)))
          end

          def lower_copy_tiles(node)
            [tile_copy(@tile_runs.fetch(node.name)), eval_call("rg_screen_request_rebuild")]
          end

          # Reference#exec_copy_owed_tiles: every run whose bit is set in the game's own
          # variables, in the order the statement lists them, and then the rebuild whether any
          # was or not.
          def lower_copy_owed_tiles(node)
            per = Nodes::CopyOwedTiles::RUNS_PER_MASK
            copies = node.runs.each_with_index.map do |name, i|
              bit = call("rg_and", call("rg_shr", variable(node.masks.fetch(i / per)), C::Int.new(i % per)), C::Int.new(1))
              C::If.new(condition: call("rg_eq", bit, C::Int.new(1)), body: [tile_copy(@tile_runs.fetch(name))])
            end
            [*copies, eval_call("rg_screen_request_rebuild")]
          end

          # Every background in the order the stack draws them, its tiles as colors with
          # RG_SEE_THROUGH where the layer behind shows (Reference#tile_colors), and every map
          # it can show, the one it starts with first. A background that can be drawn from other
          # lists of colors has its tiles written again for each step it can be told, after the
          # ones in the colors they were drawn in.
          def background_arrays
            tile_pixels = []
            cells = []
            maps = []
            painted_tiles = []
            run_colors = []
            fields = @stacking.scenery.flat_map do |bg|
              tiles_start = tile_pixels.length
              steps = color_swaps(bg)
              [nil, *steps].each do |swaps|
                bg.tiles.each { |tile| tile_pixels.concat(tile_colors(tile, swaps)) }
              end
              painted_start, colors_start = painted_tiles_of(bg, steps, painted_tiles, run_colors)
              first_map = maps.length / MAP_FIELDS
              bg.every_map.each do |map|
                # A background that never comes round again has no grid to come round at.
                maps.push(cells.length, *TileMap.size_of(map), *(bg.streams? ? [0, 0] : TileMap.grid(map)))
                cells.concat(map_cells(map))
              end
              [bg.tile_w, bg.tile_h, first_map, Array(bg.maps).length, @backgrounds.fetch(bg.name),
               bg.streams? ? 1 : 0, tiles_start,
               bg.scene ? @scenes.fetch(bg.scene, NEVER_ARRIVES) : EVERY_SCENE, @stacking.depths[bg.name],
               @handover.on_arrival?(bg) ? 1 : 0, stack_place(bg.layer),
               see_through_number(bg), @bends.key?(bg.name) ? 1 : 0, fade_place(bg),
               bg.tiles.length, steps.length, shown_in_blocks?(bg) ? 1 : 0, bg.affine ? 1 : 0,
               painted_start, colors_start]
            end
            [runtime_array("tile_pixels", "uint16_t", tile_pixels), runtime_array("backgrounds", "int32_t", fields),
             runtime_array("maps", "int32_t", maps), runtime_array("map_cells", "int16_t", cells),
             runtime_array("painted_tiles", "int32_t", painted_tiles), runtime_array("run_colors", "uint16_t", run_colors)]
          end

          # A background's tiles the game paints, added to the two arrays rg_screen.c finds them
          # by, and where each of its two parts starts there; NOT_PAINTED twice for a background
          # with none. First, for each of its tiles, the run that paints it and which of the
          # run's tiles it is. Then the color each place of each run shows on this background,
          # in the colors its tiles were drawn in and again for each step it can be told
          # (Reference#tile_colors, asked of every place at once).
          def painted_tiles_of(bg, steps, painted_tiles, run_colors)
            runs = bg.tiles.map { |tile| run_painting(tile) }
            return [NOT_PAINTED, NOT_PAINTED] if runs.none?

            starts = [painted_tiles.length, run_colors.length]
            bg.tiles.zip(runs) do |tile, run|
              painted_tiles.concat(run ? [@run_numbers.fetch(run.name), run.tiles.index(tile)] : [NOT_PAINTED, 0])
            end
            [nil, *steps].each do |swaps|
              @tile_runs.each_value { |run| run_colors.concat(colors_as_tile(every_place_of(run), swaps)) }
            end
            starts
          end

          # Each see-through layer as rg_screen.h's three flags (Reference#fixed_see_through?,
          # SeeThroughLayer#split, and the half of Reference#layer_has_anything? that asks
          # about sprites), and for every sprite the see-through layer it was declared in.
          def see_through_arrays
            flags = @see_through.flat_map do |layer|
              [layer.shows.kind == :int && layer.behind.kind == :int, layer.split,
               @objects.each_value.any? { |obj| obj.layer == layer.name }].map { |flag| flag ? 1 : 0 }
            end
            [runtime_array("see_through", "int32_t", flags),
             runtime_array("sprite_see_through", "int32_t", @objects.each_value.map { |obj| see_through_number(obj) })]
          end

          # For every sprite, whether a fade placed in the stack reaches it (see #fade_place).
          def sprite_fade_places_array
            runtime_array("sprite_fade_places", "int32_t", @objects.each_value.map { |obj| fade_place(obj) })
          end

          # How far forward a layer is among the layers the game declared, or NO_LAYER for a name
          # that is none of them, and for a thing that named no layer.
          def stack_place(layer) = @stacking.stack.index(layer) || NO_LAYER

          # IR::Stacking.at_or_above, asked of one thing ahead of time: the furthest forward a
          # placed fade's layer can be and still leave +thing+ as drawn, or NO_LAYER when every
          # placed fade reaches it.
          #
          # The interpreter takes the NAMES of everything declared in the fade's layer or in
          # front of it, scenery and sprites in one list, and leaves a thing as drawn when its
          # name is among them (Reference#set_blend_for). So two things with one name are left or
          # reached together, by whichever of them was declared further forward, and that is the
          # place given here.
          def fade_place(thing) = @fade_places.fetch(thing.name, NO_LAYER)

          # Reference#see_through_layer_of: the see-through layer a background or a sprite was
          # declared in, by its number, or SOLID. The interpreter asks by name, and a name is
          # first the last background declared by it, so two backgrounds of one name, or a sprite
          # named like a background, are both drawn as that background's layer is.
          def see_through_number(thing)
            @see_through_numbers.fetch(@last_declared.fetch(thing.name, thing).layer, SOLID)
          end

          # The routine rg_screen.c calls for a see-through layer's two amounts as they are now
          # (Reference#live_see_through_weights), answering for the layer it is asked about.
          def see_through_amounts
            answers = @see_through.each_with_index.map do |layer, number|
              C::If.new(condition: call("rg_see_through_asked", C::Int.new(number)),
                        body: [eval_call("rg_see_through_answer", value(layer.shows), value(layer.behind))])
            end
            C::Function.new(name: @names.own("see_through_amounts"), body: answers, exported: true)
          end

          # Reference#exec_see_through
          def lower_see_through(node)
            [eval_call("rg_see_through_told", C::Int.new(@see_through_numbers.fetch(node.layer)))]
          end

          # The routine rg_screen.c calls for how far across one row of a bent background sits
          # (Reference#run_bend_for_row), answering for the background it is asked about: the row
          # goes into the bend's variable, what its block says to run runs, and the offset is
          # worked out from there.
          def bend_offsets
            answers = @bends.each_value.map do |bend|
              C::If.new(condition: call("rg_bend_asked", C::Int.new(@backgrounds.fetch(bend.name))),
                        body: [assign(bend.row, call("rg_bend_line")), *body_of(bend),
                               eval_call("rg_bend_answer", value(bend.offset))])
            end
            C::Function.new(name: @names.own("bend_offsets"), body: answers, exported: true)
          end

          # Reference#work_out_bends: every bend's line 0, then the rest of each bend in turn,
          # which leaves each bend's row one past the bottom of the screen. Called last in every
          # frame boundary (rg_screen_work_out_bends).
          def work_out_bends
            first_lines = @bends.each_key.map { |name| work_out_bend_lines(name, 0, 1) }
            the_rest = @bends.flat_map do |name, bend|
              [work_out_bend_lines(name, 1, Screen::HEIGHT), assign(bend.row, C::Int.new(Screen::HEIGHT))]
            end
            C::Function.new(name: @names.own("work_out_bends"), body: first_lines + the_rest, exported: true)
          end

          # The routines rg_screen.c calls to work the game's light out (Reference#work_out_shade):
          # where the lit span of one row starts and ends, the row going into the light's
          # variable first, and then how dark the rest of every row goes. Empty for a game with
          # no light, which never calls them.
          def shade_span
            body = if @shade
                     [assign(@shade.row, call("rg_shade_line")), *body_of(@shade),
                      eval_call("rg_shade_left", value(@shade.left)),
                      eval_call("rg_shade_right", value(@shade.right))]
                   else
                     []
                   end
            C::Function.new(name: @names.own("shade_span"), body: body, exported: true)
          end

          def shade_amount
            body = @shade ? [eval_call("rg_shade_darkness", value(@shade.amount))] : []
            C::Function.new(name: @names.own("shade_amount"), body: body, exported: true)
          end

          def work_out_bend_lines(name, first, past)
            eval_call("rg_bend_work_out", C::Int.new(@backgrounds.fetch(name)), C::Int.new(first), C::Int.new(past))
          end

          # Reference#exec_scroll_rows: the bend stands from power-on, so where it is written
          # only asks for the picture to be built again — which is what shows the bend in a game
          # that never waits for the screen, whose lines are worked out as they are painted.
          def lower_scroll_rows(_node) = [eval_call("rg_screen_request_rebuild")]

          # A map's cells, row after row: the number of the tile, or CELL_EMPTY where the map
          # has none. A map is a rectangle (the builder refuses any other).
          def map_cells(map)
            cols, = TileMap.size_of(map)
            map.flat_map { |row| Array.new(cols) { |col| row[col] || CELL_EMPTY } }
          end

          # Reference#background_swap, for every step a background can be told: each of the lists
          # its tiles were drawn from, to the list that step draws it with instead, or to nil
          # where that list stays as drawn.
          def color_swaps(bg) = Array(bg.recolors).map { |step| bg.palettes.zip(step).to_h }

          # Reference#tile_colors: a tile's pixels as colors, or as the colors +swaps+ gives the
          # list it was drawn from. A swap goes by place, and is read off the pixel as drawn, so
          # what is see-through stays see-through whatever the other list holds there.
          def tile_colors(name, swaps = nil) = colors_as_tile(tile_image(name), swaps)

          # A tile's picture. One the game paints is see-through all over until its first copy
          # (Reference#blank_run_tile), and that is what is written into the game for it: the C
          # reads what was painted in its place.
          def tile_image(name)
            run = run_painting(name)
            run ? painted_image(run, Array.new(RUN_TILE_PIXELS, 0), width: RUN_TILE_SIDE, height: RUN_TILE_SIDE) : Assets::Image.of(@data.fetch(name))
          end

          def colors_as_tile(image, swaps)
            swapped = swaps && swaps[image.colors]
            recolor = swapped && Assets::Recolor.of(image, swapped)
            Array.new(image.width * image.height) do |i|
              next 0xFFFF if image.tile_see_through_at?(i)

              recolor ? recolor.color_for(i, image.color_at(i)) : image.color_at(i)
            end
          end

          # The number of the picture +name+ as drawn with the list +colors+, or with its own.
          def image_number(name, colors = nil) = @images[[name, colors]] ||= @images.size

          # --- the drawing statements ---

          # A tear-free screen is two pages. The list of colors one can be given changes nothing
          # that is drawn: a color is still named, and the build has already refused one the
          # list does not hold.
          def lower_screen(node) = screen_change("rg_screen_set", node.mode, node.buffered)

          # A change of screen, by `screen` or by a scene arriving on its own. The C says when
          # that put the scenery every screen shows up again as declared, and what says which
          # map each of those backgrounds shows then goes back to the first, and what every
          # screen shows that the game paints is copied in from its list as it is now, as
          # Reference#put_up_always_up does both.
          def screen_change(function, screen, two_pages)
            change = call(function, C::Int.new(SCREEN_KINDS.fetch(screen)), yes_or_no(two_pages))
            always = @handover.always_up
            put_back = [*always.map_choices.map { |var| assign(var, C::Int.new(0)) },
                        *(always.painted_tiles + always.painted_pictures).map { |run| tile_copy(run) }]
            return [C::Eval.new(change)] if put_back.empty?

            [C::If.new(condition: change, body: put_back)]
          end

          def lower_clear_screen(node) = [eval_call("rg_screen_clear", color(node.color))]

          # Reference#exec_inside: the edges are numbers written in the program.
          def lower_inside(node)
            [eval_call("rg_screen_inside", *[node.x, node.y, node.w, node.h].map { |edge| C::Int.new(edge) }),
             *body_of(node), eval_call("rg_screen_inside_ended")]
          end

          def lower_camera(node) = [eval_call("rg_screen_camera", value(node.x), value(node.y))]

          def lower_blit(node)
            [eval_call("rg_screen_blit", C::Int.new(image_number(node.name)), value(node.x), value(node.y))]
          end

          def lower_blit_pose(node)
            pictures = drawing_array("poses", "int32_t", node.poses.map { |name| image_number(name) })
            [eval_call("rg_screen_blit_pose", pictures, C::Int.new(node.poses.length), value(node.index),
                       value(node.x), value(node.y))]
          end

          def lower_draw_column_at(node)
            [eval_call("rg_screen_column", C::Int.new(image_number(node.name)), value(node.slice), value(node.x),
                       value(node.top), value(node.height), C::Int.new(node.width || 1))]
          end

          def lower_save_region(node) = [patch_statement("rg_patch_save", node)]
          def lower_restore_region(node) = [patch_statement("rg_patch_restore", node)]

          # Reference#backing_for: a patch is kept in the buffer the program declared for it,
          # which says how big it is.
          def patch_statement(function, node)
            buffer = @patches.fetch(node.buffer) do
              raise LoweringError, "backing buffer #{node.buffer.inspect} is used and never declared"
            end
            eval_call(function, C::Int.new(@patch_numbers.fetch(node.buffer)), C::Int.new(buffer.width),
                      C::Int.new(buffer.height), value(node.x), value(node.y))
          end

          def lower_fill_rect(node)
            [eval_call("rg_screen_fill_rect", *[node.x, node.y, node.w, node.h].map { |n| value(n) }, color(node.color))]
          end

          alias lower_dma_fill_rect lower_fill_rect
          alias lower_draw_rect_at lower_fill_rect

          def lower_pixel(node) = [eval_call("rg_screen_pixel", value(node.x), value(node.y), color(node.color))]

          # The pixels of a line of text are known when the game is built, so they are handed
          # over as points rather than worked out from the font as it runs.
          def lower_draw_text(node)
            points = node.fonts.get(node.font).enum_for(:each_pixel, node.text).flat_map { |dx, dy| [dx, dy] }
            name = drawing_array("text_points", "int16_t", points)
            ink = node.picked ? call("rg_pick_color", value(node.showing), color(node.color), color(node.picked)) : color(node.color)
            [eval_call("rg_screen_points", value(node.x), value(node.y), ink, name, C::Int.new(points.length / 2))]
          end

          # A live digit: the ten digits' points, and where each begins.
          def lower_draw_digit(node)
            font = node.fonts.get(node.font)
            per_digit = (0..9).map { |d| font.enum_for(:each_pixel, d.to_s).flat_map { |dx, dy| [dx, dy] } }
            starts = per_digit.each_with_object([0]) { |points, at| at << (at.last + (points.length / 2)) }
            [eval_call("rg_screen_digit", value(node.value), value(node.x), value(node.y), color(node.color),
                       drawing_array("digit_points", "int16_t", per_digit.flatten), drawing_array("digit_starts", "int32_t", starts))]
          end

          # Reference#exec_background: a scene's own scenery on a screen drawn from tiles goes up
          # as the scene arrives, not here; any other is put up (or, inside a scene, stamped into
          # the picture like any drawing) each time this runs.
          def lower_background(node)
            return [] if @handover.on_arrival?(node)

            id = C::Int.new(entry_of(node))
            [eval_call("rg_screen_paint_owed_rebuild"), eval_call(node.scene ? "rg_background_stamp" : "rg_background_put_up", id)]
          end

          def lower_scroll_background(node)
            [eval_call("rg_background_scroll", background_number(node), value(node.x), value(node.y))]
          end

          def lower_set_tile(node)
            [eval_call("rg_background_set_tile", background_number(node), value(node.col), value(node.row),
                       C::Int.new(node.tile))]
          end

          def lower_show_map(node) = [eval_call("rg_background_show_map", background_number(node), value(node.which))]

          # Reference#exec_background_colors
          def lower_background_colors(node)
            [eval_call("rg_background_draw_with", background_number(node), value(node.which))]
          end

          # The number rg_screen.c knows the background a statement names by: the entry that
          # keeps what the game does to that name (see #entry_of for one declaration's own).
          def background_number(node)
            C::Int.new(@backgrounds.fetch(node.name) do
              raise LoweringError, "#{node.kind} of undeclared background #{node.name.inspect}"
            end)
          end

          def lower_affine_background(node)
            [eval_call("rg_background_turn", background_number(node), value(node.angle),
                       value(node.scale), C::Int.new(node.around_x), C::Int.new(node.around_y))]
          end

          # Reference#exec_present_objects: every sprite the frame draws is taken off the picture,
          # then each one that is shown is put where it is now.
          def lower_present_objects(node)
            drawn = node.names.map { |name| presented_object(name) }
            [eval_call("rg_objects_begin"), *drawn.map { |obj| sprite_removal(obj) },
             *placements_in_draw_order(node), eval_call("rg_objects_end")]
          end

          def presented_object(name)
            @objects.fetch(name) { raise LoweringError, "present of undeclared object #{name.inspect}" }
          end

          # Reference#names_in_draw_order: the frame's sprites placed as listed, except that each
          # run the game puts in order is placed in the order its list holds now. A run stands
          # where its first sprite is listed and takes the place of as many names as it has.
          def placements_in_draw_order(node)
            runs = Array(node.orders)
            runs.each { |run| refuse_scattered_run!(node, run) }
            refuse_sprite_in_two_runs!(runs)
            starts = runs.to_h { |run| [run.objects.first, run] }
            inside_a_run = runs.flat_map(&:objects)
            node.names.flat_map do |name|
              next [ordered_run_placement(starts.fetch(name))] if starts.key?(name)
              next [] if inside_a_run.include?(name)

              [sprite_placement(presented_object(name))]
            end
          end

          # The interpreter swaps a run in by position: as many names as the run has, from where
          # its first is listed, and one run after another. In every program the builder makes
          # those names are the run's own sprites and no sprite is in two runs, and only then is
          # placing each run's sprites by name, as the C below does, the same thing. So a tree
          # that is not like that is refused, by this and by #refuse_sprite_in_two_runs!.
          def refuse_scattered_run!(node, run)
            first = node.names.index(run.objects.first)
            return if first && node.names[first, run.objects.length] == run.objects

            raise LoweringError, "a run of sprites drawn in a worked-out order (#{run.order.inspect}) is not " \
                                 "side by side in the frame's draw list"
          end

          def refuse_sprite_in_two_runs!(runs)
            shared, = runs.flat_map(&:objects).tally.find { |_, times| times > 1 }
            return unless shared

            raise LoweringError, "sprite #{shared.inspect} is in two runs drawn in a worked-out order"
          end

          # One run: for each place the order list holds, back to front, the sprite it names is
          # placed.
          def ordered_run_placement(run)
            order = C::AddressOf.new(list(run.order))
            count = local_name("count")
            index = local_name("index")
            place = local_name("place")
            placed = run.objects.each_with_index.map do |name, at|
              C::If.new(condition: call("rg_eq", place, C::Int.new(at)), body: [sprite_placement(presented_object(name))])
            end
            read_place = call("rg_place_in_ordered_run", call("rg_list_get", order, index), C::Int.new(run.objects.length))
            C::Block.new([C::Local.new(name: count, value: call("rg_list_length", order)),
                          C::Local.new(name: index, value: C::Int.new(0)),
                          C::While.new(condition: call("rg_lt", index, count),
                                       body: [C::Local.new(name: place, value: read_place), *placed,
                                              C::Assign.new(index, call("rg_add", index, C::Int.new(1)))])])
          end

          # Any of a sprite's pictures says how big a patch it covered; the interpreter reads
          # the first (Reference#restore_scene_rect). One that turns or resizes covered more,
          # and how much more depends on whether its size ever changes.
          def sprite_removal(obj)
            patch = [sprite_number(obj), C::Int.new(image_number(obj.poses.first))]
            return eval_call("rg_object_take_off", *patch) unless turns_or_resizes?(obj)

            eval_call("rg_object_take_off_turned", *patch, yes_or_no(!constant?(obj.scale, Build::SCALE_ONE)))
          end

          # Reference#objects_on_screen: a sprite is drawn when it is switched on and its pose
          # names one of its pictures.
          def sprite_placement(obj)
            pose = local_name("pose")
            in_range = call("rg_both", call("rg_ge", pose, C::Int.new(0)), call("rg_lt", pose, C::Int.new(obj.poses.length)))
            placed = [sprite_number(obj), picture_drawn(obj, pose), value(obj.x), value(obj.y), level_drawn_at(obj)]
            add = if turns_or_resizes?(obj)
                    eval_call("rg_objects_add_turned", *placed, value(obj.angle), value(obj.scale),
                              yes_or_no(!constant?(obj.scale, Build::SCALE_ONE)))
                  else
                    eval_call("rg_objects_add", *placed)
                  end
            C::If.new(condition: call("rg_eq", value(obj.active), C::Int.new(1)),
                      body: [C::Block.new([C::Local.new(name: pose, value: value(obj.pose)),
                                           C::If.new(condition: in_range, body: [add])])])
          end

          # Reference#object_transformed?: a sprite turns or resizes unless both its angle and
          # its size are still the numbers every sprite starts with.
          def turns_or_resizes?(obj) = !(constant?(obj.angle, 0) && constant?(obj.scale, Build::SCALE_ONE))

          def sprite_number(obj) = C::Int.new(@sprites.fetch(obj.name))

          # Reference#object_level: how deep a sprite sits now. One that can be put in other
          # layers has a level for each, after the one it was declared at, and the number its
          # layer variable holds picks among them.
          def level_drawn_at(obj)
            levels = Stacking.levels_of(@stacking.depths, obj)
            return C::Int.new(levels.first) if levels.one?

            pick = call("rg_place_of_choice", variable(obj.layer_pick), C::Int.new(levels.length - 1))
            C::Index.new(drawing_array("levels", "int32_t", levels), pick)
          end

          # Which picture a sprite showing pose number +pose+ (one of its poses, already checked)
          # is DRAWN from, in the colors it is drawn with now. Its pictures are a row of poses in
          # its own colors, then a row for each list it can be drawn with
          # (Reference#object_recolor), and rg_place_of_choice says which row it is on.
          #
          # A list that holds other colors as the game runs (a name where the colors would be)
          # has a row for every set it can hold, the ones it was declared with first, and the
          # set it holds now says which of those rows (Reference#colors_held_by).
          def picture_drawn(obj, pose)
            lists = Array(obj.recolors)
            sets = [[nil], *lists.map { |colors| colors.is_a?(Symbol) ? sets_held_by(colors) : [colors] }]
            rows = sets.flatten(1).flat_map { |colors| obj.poses.map { |name| image_number(name, colors) } }
            pictures = drawing_array("pose_rows", "int32_t", rows)
            return C::Index.new(pictures, pose) if lists.empty?

            row = row_drawn_with(obj, lists, sets)
            C::Index.new(pictures, call("rg_add", call("rg_mul", row, C::Int.new(obj.poses.length)), pose))
          end

          # Which row of its pictures a sprite is on: the first row of the list it is drawn with
          # now, and for a list that holds other colors, as many rows further as the set it holds.
          def row_drawn_with(obj, lists, sets)
            choice = call("rg_place_of_choice", value(obj.recolor), C::Int.new(lists.length))
            return choice if lists.none?(Symbol)

            first_rows = sets.each_with_object([0]) { |held, starts| starts << (starts.last + held.length) }
            row = C::Index.new(drawing_array("first_rows", "int32_t", first_rows.first(sets.length)), choice)
            lists.each_with_index.select { |colors, _| colors.is_a?(Symbol) }.reduce(row) do |so_far, (name, at)|
              held = call("rg_place_of_choice", held_colors(name), C::Int.new(sets_held_by(name).length - 1))
              call("rg_add", so_far, call("rg_mul", call("rg_eq", choice, C::Int.new(at + 1)), held))
            end
          end

          # Reference#colors_held_by: every set of colors a named list can hold, the ones it was
          # declared with first, which is also what a number naming none of the others means.
          def sets_held_by(name)
            list = @color_lists.fetch(name) { raise LoweringError, "a sprite is drawn with the list of colors #{name.inspect}, which is not declared" }
            [list.colors, *list.recolors]
          end

          # Which of its other sets each such list holds now (Reference @held_colors): a number
          # of the game's own for each, starting at the one that means the colors it was
          # declared with.
          def held_colors(name) = @names.of(:colors, name)

          def held_colors_globals
            @color_lists.each_key.map { |name| C::Global.new(name: held_colors(name), value: Build::NO_RECOLOR) }
          end

          # Reference#exec_color_list_holds. Nothing is painted here: everything drawn with the
          # list reads what it holds as it is next drawn.
          def lower_color_list_holds(node) = [C::Assign.new(held_colors(node.name), value(node.which))]

          # Reference#pixels_overlap?: each side's picture now, and where it is.
          def value_of_pixels_overlap(node)
            call("rg_pixels_overlap", picture_collided(node.a_poses, node.a_pose), value(node.a_x), value(node.a_y),
                 picture_collided(node.b_poses, node.b_pose), value(node.b_x), value(node.b_y))
          end

          # Which picture a sprite COLLIDES as: the one of +poses+ its pose names, in its own
          # colors whatever it is drawn with, since a swap of colors moves no pixel. The pose is
          # not checked first here; rg_pose_image reads it the way the interpreter does.
          def picture_collided(poses, pose)
            pictures = drawing_array("poses", "int32_t", poses.map { |name| image_number(name) })
            call("rg_pose_image", pictures, C::Int.new(poses.length), value(pose))
          end

          # Reference#exec_fade: over the whole screen, or placed in the stack under a layer, which
          # rg_screen.c knows by how far forward it is (IR::Stacking.at_or_above).
          def lower_fade(node)
            fade = [C::Int.new(node.toward == :white ? 1 : 0), fade_steps(node), walks_colors(node)]
            return [eval_call("rg_screen_fade_in_area", *fade_area(node), *fade.first(2))] if node.reaches
            return [eval_call("rg_screen_fade", *fade)] unless node.under

            [eval_call("rg_screen_fade_under", C::Int.new(stack_place(node.under)), *fade)]
          end

          # Which side of its rectangle a fade reaches, then the rectangle's four edges, as
          # rg_screen_fade_in_area takes them.
          def fade_area(node)
            side = node.reaches == :inside ? "RG_FADE_INSIDE" : "RG_FADE_OUTSIDE"
            [C::Name.new(side), *node.area.map { |edge| C::Int.new(edge) }]
          end

          # Reference#exec_pixelate. Where the blocks stop is not this statement's to say: a
          # program has one place for them, settled before it runs (#names_left_out_of_blocks).
          def lower_pixelate(node) = [eval_call("rg_screen_pixelate", value(node.size))]

          # Reference#exec_tint: counted in thirty-seconds however it reaches the screen. Which way
          # it is mixed follows the screen up, which rg_screen.c knows.
          def lower_tint(node)
            steps = call("rg_fade_steps", value(node.amount), C::Int.new(node.fraction_bits || -1), C::Int.new(1))
            [eval_call("rg_screen_tint", color(node.color), steps)]
          end

          # 1 where this fade or tint walks the colors in thirty-seconds rather than having the
          # display blend in sixteenths, which the whole program decides (see IR::Fading).
          def walks_colors(node) = C::Int.new(@fading.palette_walk?(node) ? 1 : 0)

          def fade_steps(node)
            call("rg_fade_steps", value(node.amount), C::Int.new(node.fraction_bits || -1), walks_colors(node))
          end

          # --- a scene taking the screen over (Reference#take_over) ---

          def scene_arrival(scene)
            arrival = @handover.arrival(scene)
            screen = if arrival.screen
                       lower_screen(arrival.screen)
                     else
                       screen_change("rg_screen_cross_to", Modes::SCREEN_OF_MODE.fetch(arrival.mode),
                                     arrival.mode == Modes::BUFFERED)
                     end
            [eval_call("rg_scene_enter", C::Int.new(@scenes.fetch(scene))), *screen,
             eval_call("rg_scene_take_down", C::Int.new(arrival.scenery.empty? ? 0 : 1)),
             *arrival.map_choices.map { |var| assign(var, C::Int.new(0)) },
             *(arrival.painted_tiles + arrival.painted_pictures).map { |run| tile_copy(run) },
             *arrival.scenery.map { |bg| eval_call("rg_background_put_up", C::Int.new(entry_of(bg))) },
             *(arrival.scenery.empty? ? [] : [eval_call("rg_scene_redraw_sprites")])]
          end

          # The number rg_screen.c knows this one declaration by. A name gives the entry that
          # keeps what the game does to it (RG_BG_KEPT_BY), which is another declaration's when
          # two scenes declare a background by one name, so a declaration is found by itself.
          def entry_of(bg)
            @stacking.scenery.index { |entry| entry.equal?(bg) } or
              raise LoweringError, "background #{bg.name.inspect} is not among the backgrounds the picture draws"
          end

          # --- small pieces ---

          def color(name) = C::Int.new(Graphics::Color.resolve(name))

          # 1 or 0, which is how a yes or a no is handed to the C.
          def yes_or_no(answer) = C::Int.new(answer ? 1 : 0)

          # A constant array for one drawing statement, kept to be written before the routines.
          def drawing_array(what, type, values)
            name = @names.own("#{what}_#{@drawing_arrays.length + 1}")
            @drawing_arrays << C::ConstArray.new(name: name, type: type, values: values)
            name
          end
        end
      end
    end
  end
end
