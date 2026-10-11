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
        #
        # Sound is ignored for now rather than refused: a game's sound changes nothing it draws
        # or keeps, so the rest of the game can be built and checked while the sound is written.
        module Picture
          # The kinds of screen, as rg_screen.h numbers them.
          SCREEN_KINDS = Ractor.make_shareable({ bitmap: 0, tiled: 1, rotozoom: 2 })

          # rg_screen.h's own numbers for whose a background is, and how many there can be.
          EVERY_SCENE = -1
          NEVER_ARRIVES = -2
          MAX_BACKGROUNDS = 64

          # The kinds the interpreter's picture would rebuild whole every frame for (see
          # Reference#collect_definitions). The C only has that way of moving sprites.
          REBUILT_FOR = %i[tile_run scroll_background scroll_rows affine_background set_tile show_map].freeze

          private

          def prepare_picture
            @stacking = Stacking.picture(@program)
            @handover = SceneHandover.of(@program)
            @fading = Fading.resolve(@program)
            @backgrounds = @stacking.scenery.each_with_index.to_h { |bg, id| [bg.name, id] }
            @objects = by_name(@program.walk, :object)
            @images = {} # picture name -> its number in rg_game_images
            @drawing_arrays = [] # constant arrays the drawing statements need, written before the routines
            refuse_unsupported_picture!
          end

          # --- what this backend cannot draw yet, said before anything is written ---

          def refuse_unsupported_picture!
            nodes = @program.walk.to_a
            refuse_picture!("a stack of named layers") if nodes.any? { |n| n.kind == :layers }
            refuse_picture!("a tear-free screen") if nodes.any? { |n| n.kind == :screen && (n.buffered || !Array(n.colors).empty?) }
            refuse_picture!("a fade placed in the stack (fade ... under:)") if nodes.any? { |n| n.kind == :fade && n.under }
            refuse_picture!("more than #{MAX_BACKGROUNDS} backgrounds") if @backgrounds.size > MAX_BACKGROUNDS
            @stacking.scenery.each { |bg| refuse_unsupported_background!(bg) }
            @objects.each_value { |obj| refuse_unsupported_object!(obj) }
            return if @objects.empty? || rebuilt_every_frame?

            refuse_picture!("sprites over a picture that is not rebuilt every frame")
          end

          def refuse_unsupported_background!(bg)
            refuse_picture!("a background drawn in other colors (#{bg.name})") unless Array(bg.recolors).empty?
            refuse_picture!("a background with several maps (#{bg.name})") if Array(bg.maps).length > 1
            refuse_picture!("a background bigger than the console's grid (#{bg.name})") if bg.streams?
          end

          def refuse_unsupported_object!(obj)
            refuse_picture!("a sprite drawn in other colors (#{obj.declared})") unless Array(obj.recolors).empty?
            refuse_picture!("a sprite that changes layer (#{obj.declared})") unless Array(obj.layers).empty?
            return if constant?(obj.angle, 0) && constant?(obj.scale, Build::SCALE_ONE)

            refuse_picture!("a sprite that turns or resizes (#{obj.declared})")
          end

          def refuse_picture!(what)
            raise LoweringError, "this program uses #{what}, which the desktop build cannot draw yet. " \
                                 "The cartridge build can."
          end

          def constant?(node, value) = node.kind == :int && node.value == value

          # Reference#collect_definitions and #run: whether the whole view is rebuilt every
          # frame rather than sprites moved over a picture that stays.
          def rebuilt_every_frame?
            @program.walk.any? { |node| REBUILT_FOR.include?(node.kind) || (node.kind == :fade && node.under) } ||
              Stacking.scenery_over_objects?(@stacking.depths, scenery: @stacking.scenery, objects: @stacking.objects)
          end

          # --- the art, for rg_screen.c ---

          def picture_data
            [*image_arrays, *background_arrays,
             runtime_array("picture_sizes", "int32_t",
                    [@backgrounds.size, @stacking.depths.count, @handover.always_up.scenery.length]),
             runtime_array("always_up", "int32_t", @handover.always_up.scenery.map { |bg| @backgrounds.fetch(bg.name) }),
             runtime_array("sines", "int32_t", (0...450).map { |degrees| Affine.sine(degrees) }),
             runtime_array("turn_rules", "int32_t", [Build::SCALE_ONE, Affine::ONE_TH, Affine::MAX, Affine::MIN_SCALE])]
          end

          # An array of numbers rg_screen.c reads by name (rg_game_ and +what+).
          def runtime_array(what, type, values) = C::ConstArray.new(name: @names.own(what), type: type, values: values, exported: true)

          # Every picture a sprite can show: pixels as stored, see-through color or -1.
          def image_arrays
            pixels = []
            info = []
            @images.each_key do |name|
              image = Assets::Image.of(@data.fetch(name))
              info.push(pixels.length, image.width, image.height, image.transparent || -1)
              pixels.concat(image.pixels.unpack("v*"))
            end
            [runtime_array("image_pixels", "uint16_t", pixels), runtime_array("images", "int32_t", info)]
          end

          # Every background in the order the stack draws them, its tiles as colors with
          # RG_SEE_THROUGH where the layer behind shows (Reference#tile_colors), and its map.
          def background_arrays
            tile_pixels = []
            cells = []
            fields = @stacking.scenery.flat_map do |bg|
              tiles_start = tile_pixels.length
              bg.tiles.each { |tile| tile_pixels.concat(tile_colors(tile)) }
              map = bg.map
              cols = map.map(&:length).max || 0
              map_start = cells.length
              map.each { |row| cells.concat(Array.new(cols) { |c| row[c] || -1 }) }
              grid_cols, grid_rows = TileMap.grid(map)
              [bg.tile_w, bg.tile_h, cols, map.length, grid_cols, grid_rows, map_start, tiles_start,
               bg.scene ? @scenes.fetch(bg.scene, NEVER_ARRIVES) : EVERY_SCENE, @stacking.depths[bg.name],
               @handover.on_arrival?(bg) ? 1 : 0]
            end
            [runtime_array("tile_pixels", "uint16_t", tile_pixels), runtime_array("backgrounds", "int32_t", fields),
             runtime_array("map_cells", "int16_t", cells)]
          end

          def tile_colors(name)
            image = Assets::Image.of(@data.fetch(name))
            Array.new(image.width * image.height) { |i| image.tile_see_through_at?(i) ? 0xFFFF : image.color_at(i) }
          end

          def image_number(name) = @images[name] ||= @images.size

          # --- the drawing statements ---

          def lower_screen(node) = [eval_call("rg_screen_set", C::Int.new(SCREEN_KINDS.fetch(node.mode)))]
          def lower_clear_screen(node) = [eval_call("rg_screen_clear", color(node.color))]

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

            id = C::Int.new(@backgrounds.fetch(node.name))
            [eval_call("rg_screen_paint_owed_rebuild"), eval_call(node.scene ? "rg_background_stamp" : "rg_background_put_up", id)]
          end

          def lower_affine_background(node)
            [eval_call("rg_background_turn", C::Int.new(@backgrounds.fetch(node.name)), value(node.angle),
                       value(node.scale), C::Int.new(node.around_x), C::Int.new(node.around_y))]
          end

          # Reference#exec_present_objects and #objects_on_screen: each sprite that is switched
          # on and whose pose names one of its pictures, where it is now.
          def lower_present_objects(node)
            placed = node.names.map do |name|
              obj = @objects.fetch(name) { raise LoweringError, "present of undeclared object #{name.inspect}" }
              poses = drawing_array("poses", "int32_t", obj.poses.map { |pose| image_number(pose) })
              pose = local_name("pose")
              in_range = call("rg_both", call("rg_ge", pose, C::Int.new(0)), call("rg_lt", pose, C::Int.new(obj.poses.length)))
              add = eval_call("rg_objects_add", C::Index.new(poses, pose), value(obj.x), value(obj.y),
                              C::Int.new(@stacking.depths[obj.name]))
              C::If.new(condition: call("rg_eq", value(obj.active), C::Int.new(1)),
                        body: [C::Block.new([C::Local.new(name: pose, value: value(obj.pose)),
                                             C::If.new(condition: in_range, body: [add])])])
            end
            [eval_call("rg_objects_begin"), *placed, eval_call("rg_objects_end")]
          end

          # Reference#exec_fade, for a fade over the whole screen.
          def lower_fade(node)
            [eval_call("rg_screen_fade", C::Int.new(node.toward == :white ? 1 : 0), fade_steps(node), walks_colors(node))]
          end

          # Reference#exec_tint: counted in thirty-seconds however it reaches the screen.
          def lower_tint(node)
            steps = fade_steps(node)
            steps = call("rg_mul", steps, C::Int.new(2)) if walks_colors(node).value.zero?
            [eval_call("rg_screen_tint", color(node.color), steps)]
          end

          # 1 where this fade or tint walks the colors in thirty-seconds rather than having the
          # display blend in sixteenths, which the whole program decides (see IR::Fading).
          def walks_colors(node) = C::Int.new(@fading.palette_walk?(node) ? 1 : 0)

          def fade_steps(node)
            call("rg_fade_steps", value(node.amount), C::Int.new(node.fraction_bits || -1), walks_colors(node))
          end

          # A sound statement, written as nothing: sound changes nothing a game draws or keeps, so
          # for now it is not played at all. (lower_nothing is for declarations, which run nowhere
          # on any backend; this is for statements that will one day be played here.)
          def lower_sound_unplayed(_node) = []

          # --- a scene taking the screen over (Reference#take_over) ---

          def scene_arrival(scene)
            arrival = @handover.arrival(scene)
            unless (arrival.painted_tiles + arrival.painted_pictures).empty?
              refuse_picture!("tiles or pictures painted from a list")
            end

            screen = if arrival.screen
                       lower_screen(arrival.screen)
                     else
                       mode = Modes::SCREEN_OF_MODE.fetch(arrival.mode)
                       refuse_picture!("a tear-free screen") if arrival.mode == Modes::BUFFERED
                       [eval_call("rg_screen_cross_to", C::Int.new(SCREEN_KINDS.fetch(mode)))]
                     end
            [eval_call("rg_scene_enter", C::Int.new(@scenes.fetch(scene))), *screen,
             eval_call("rg_scene_take_down", C::Int.new(arrival.scenery.empty? ? 0 : 1)),
             *arrival.map_choices.map { |var| assign(var, C::Int.new(0)) },
             *arrival.scenery.map { |bg| eval_call("rg_background_put_up", C::Int.new(@backgrounds.fetch(bg.name))) }]
          end

          # --- small pieces ---

          def color(name) = C::Int.new(Graphics::Color.resolve(name))

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
