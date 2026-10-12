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
          CELL_EMPTY = -1
          # How many numbers say one map (RG_MAP_FIELDS): where its cells start, its columns, its rows.
          MAP_FIELDS = 3
          MAX_BACKGROUNDS = 64
          MAX_SPRITES = 512
          # A thing in no see-through layer (RG_SOLID), and how many of those layers there is
          # room for (RG_MAX_SEE_THROUGH).
          SOLID = -1
          MAX_SEE_THROUGH = 16

          # The kinds the interpreter's picture is rebuilt whole every frame for (see
          # Reference#collect_definitions, and #rebuilt_every_frame? for the rest of the rule).
          REBUILT_FOR = %i[tile_run scroll_background scroll_rows affine_background set_tile show_map].freeze

          private

          def prepare_picture
            @stacking = Stacking.picture(@program)
            @handover = SceneHandover.of(@program)
            @fading = Fading.resolve(@program)
            @backgrounds = @stacking.scenery.each_with_index.to_h { |bg, id| [bg.name, id] }
            @objects = by_name(@program.walk, :object)
            @sprites = @objects.each_key.with_index.to_h # sprite name -> the number rg_screen.c knows it by
            # The layers the game can be seen through, and the number rg_screen.c knows each by.
            @see_through = SeeThrough.layers(@program)
            @see_through_numbers = @see_through.each_with_index.to_h { |layer, number| [layer.name, number] }
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
            refuse_picture!("a fade placed in the stack (fade ... under:)") if nodes.any? { |n| n.kind == :fade && n.under }
            refuse_picture!("more than #{MAX_SEE_THROUGH} see-through layers") if @see_through.size > MAX_SEE_THROUGH
            refuse_picture!("more than #{MAX_BACKGROUNDS} backgrounds") if @backgrounds.size > MAX_BACKGROUNDS
            # The interpreter keeps a background's scroll and cells by its name and draws each
            # declaration; rg_screen.c knows a background by one number, which a name here gives.
            shared = @stacking.scenery.map(&:name).tally.select { |_, times| times > 1 }.keys
            refuse_picture!("two backgrounds with one name (#{shared.first})") unless shared.empty?
            refuse_picture!("more than #{MAX_SPRITES} sprites") if @sprites.size > MAX_SPRITES
            if nodes.any? { |n| n.kind == :inside && frame_ends_under?(n) }
              refuse_picture!("a frame that ends inside an `inside` block")
            end
            @stacking.scenery.each { |bg| refuse_unsupported_background!(bg) }
          end

          # Whether a frame can end while +node+ is running: it waits for the screen itself, or
          # calls a routine that does. The interpreter reads the screen through the area an
          # `inside` holds drawing to when it is read while the block is open (Framebuffer#pixel),
          # and the C reads the whole screen, so a game that ends a frame there is refused.
          def frame_ends_under?(node, asked = [])
            statements = statements_under(node)
            return true if statements.any? { |statement| statement.kind == :wait_vblank }

            (routines_named(statements) - asked).any? do |name|
              @funcs.key?(name) && frame_ends_under?(@funcs.fetch(name), asked << name)
            end
          end

          def refuse_unsupported_background!(bg)
            refuse_picture!("a background drawn in other colors (#{bg.name})") unless Array(bg.recolors).empty?
          end

          def refuse_picture!(what)
            raise LoweringError, "this program uses #{what}, which the desktop build cannot draw yet. " \
                                 "The cartridge build can."
          end

          def constant?(node, value) = node.kind == :int && node.value == value

          # Reference#collect_definitions and #run: whether the whole view is rebuilt every
          # frame — for scenery that can look different next frame, a fade placed in the stack,
          # or scenery a named layer puts in front of a sprite — rather than sprites drawn
          # straight onto a picture that stays.
          def rebuilt_every_frame?
            @program.walk.any? { |node| REBUILT_FOR.include?(node.kind) || (node.kind == :fade && node.under) } ||
              Stacking.scenery_over_objects?(@stacking.depths, scenery: @stacking.scenery, objects: @stacking.objects)
          end

          # --- the art, for rg_screen.c ---

          def picture_data
            [*image_arrays, *background_arrays, *see_through_arrays,
             runtime_array("picture_sizes", "int32_t",
                    [@backgrounds.size, @stacking.depths.count, @handover.always_up.scenery.length,
                     rebuilt_every_frame? ? 1 : 0, @see_through.size]),
             runtime_array("always_up", "int32_t", @handover.always_up.scenery.map { |bg| @backgrounds.fetch(bg.name) }),
             runtime_array("sines", "int32_t", (0...450).map { |degrees| Affine.sine(degrees) }),
             runtime_array("turn_rules", "int32_t", [Build::SCALE_ONE, Affine::ONE_TH, Affine::MAX, Affine::MIN_SCALE])]
          end

          # An array of numbers rg_screen.c reads by name (rg_game_ and +what+).
          def runtime_array(what, type, values) = C::ConstArray.new(name: @names.own(what), type: type, values: values, exported: true)

          # Every picture a sprite can show, once for each list of colors it is drawn with.
          def image_arrays
            pixels = []
            info = []
            @images.each_key do |name, colors|
              image = picture_named(name)
              info.push(pixels.length, image.width, image.height)
              pixels.concat(sprite_pixels(image, colors))
            end
            [runtime_array("image_pixels", "int32_t", pixels), runtime_array("images", "int32_t", info)]
          end

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

          def picture_named(name)
            Assets::Image.of(@data.fetch(name) { raise LoweringError, "a sprite shows the picture #{name.inspect}, which is not defined" })
          end

          # Every background in the order the stack draws them, its tiles as colors with
          # RG_SEE_THROUGH where the layer behind shows (Reference#tile_colors), and every map
          # it can show, the one it starts with first.
          def background_arrays
            tile_pixels = []
            cells = []
            maps = []
            fields = @stacking.scenery.flat_map do |bg|
              tiles_start = tile_pixels.length
              bg.tiles.each { |tile| tile_pixels.concat(tile_colors(tile)) }
              first_map = maps.length / MAP_FIELDS
              bg.every_map.each do |map|
                maps.push(cells.length, *TileMap.size_of(map))
                cells.concat(map_cells(map))
              end
              # A background that never comes round again has no grid to come round at.
              grid_cols, grid_rows = bg.streams? ? [0, 0] : TileMap.grid(bg.map)
              [bg.tile_w, bg.tile_h, first_map, Array(bg.maps).length, grid_cols, grid_rows,
               bg.streams? ? 1 : 0, tiles_start,
               bg.scene ? @scenes.fetch(bg.scene, NEVER_ARRIVES) : EVERY_SCENE, @stacking.depths[bg.name],
               @handover.on_arrival?(bg) ? 1 : 0, @stacking.stack.index(bg.layer) || NO_LAYER,
               see_through_number(bg), @bends.key?(bg.name) ? 1 : 0]
            end
            [runtime_array("tile_pixels", "uint16_t", tile_pixels), runtime_array("backgrounds", "int32_t", fields),
             runtime_array("maps", "int32_t", maps), runtime_array("map_cells", "int16_t", cells)]
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

          # Reference#see_through_layer_of: the see-through layer a background or a sprite was
          # declared in, by its number, or SOLID.
          def see_through_number(thing) = @see_through_numbers.fetch(thing.layer, SOLID)

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
          # (Reference#row_bend_offset), answering for the background it is asked about: the row
          # goes into the bend's variable, what its block says to run runs, and the offset is
          # worked out from there. A bend that names no background is never asked for.
          def row_bends
            answers = @bends.values.select { |bend| @backgrounds.key?(bend.name) }.map do |bend|
              C::If.new(condition: call("rg_row_bend_asked", C::Int.new(@backgrounds.fetch(bend.name))),
                        body: [assign(bend.row, call("rg_row_bend_row")), *body_of(bend),
                               eval_call("rg_row_bend_answer", value(bend.offset))])
            end
            C::Function.new(name: @names.own("row_bends"), body: answers, exported: true)
          end

          # Reference#exec_scroll_rows: the bend stands from power-on, so where it is written
          # only asks for the picture to be built again.
          def lower_scroll_rows(_node) = [eval_call("rg_screen_rows_bent")]

          # A map's cells, row after row: the number of the tile, or CELL_EMPTY where the map
          # has none. A map is a rectangle (the builder refuses any other).
          def map_cells(map)
            cols, = TileMap.size_of(map)
            map.flat_map { |row| Array.new(cols) { |col| row[col] || CELL_EMPTY } }
          end

          def tile_colors(name)
            image = Assets::Image.of(@data.fetch(name))
            Array.new(image.width * image.height) { |i| image.tile_see_through_at?(i) ? 0xFFFF : image.color_at(i) }
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
          # map each of those backgrounds shows then goes back to the first, as
          # Reference#put_up_always_up puts it back.
          def screen_change(function, screen, two_pages)
            change = call(function, C::Int.new(SCREEN_KINDS.fetch(screen)), yes_or_no(two_pages))
            choices = @handover.always_up.map_choices
            return [C::Eval.new(change)] if choices.empty?

            [C::If.new(condition: change, body: choices.map { |var| assign(var, C::Int.new(0)) })]
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

            id = C::Int.new(@backgrounds.fetch(node.name))
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

          # The number rg_screen.c knows the background a statement names by.
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
            drawn = node.names.map do |name|
              @objects.fetch(name) { raise LoweringError, "present of undeclared object #{name.inspect}" }
            end
            [eval_call("rg_objects_begin"), *drawn.map { |obj| sprite_removal(obj) },
             *drawn.map { |obj| sprite_placement(obj) }, eval_call("rg_objects_end")]
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
                    eval_call("rg_objects_add_turned", *placed, value(obj.angle), value(obj.scale))
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
          def picture_drawn(obj, pose)
            lists = Array(obj.recolors)
            rows = [nil, *lists].flat_map { |colors| obj.poses.map { |name| image_number(name, colors) } }
            pictures = drawing_array("pose_rows", "int32_t", rows)
            return C::Index.new(pictures, pose) if lists.empty?

            row = call("rg_place_of_choice", value(obj.recolor), C::Int.new(lists.length))
            C::Index.new(pictures, call("rg_add", call("rg_mul", row, C::Int.new(obj.poses.length)), pose))
          end

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

          # --- a scene taking the screen over (Reference#take_over) ---

          def scene_arrival(scene)
            arrival = @handover.arrival(scene)
            unless (arrival.painted_tiles + arrival.painted_pictures).empty?
              refuse_picture!("tiles or pictures painted from a list")
            end

            screen = if arrival.screen
                       lower_screen(arrival.screen)
                     else
                       screen_change("rg_screen_cross_to", Modes::SCREEN_OF_MODE.fetch(arrival.mode),
                                     arrival.mode == Modes::BUFFERED)
                     end
            [eval_call("rg_scene_enter", C::Int.new(@scenes.fetch(scene))), *screen,
             eval_call("rg_scene_take_down", C::Int.new(arrival.scenery.empty? ? 0 : 1)),
             *arrival.map_choices.map { |var| assign(var, C::Int.new(0)) },
             *arrival.scenery.map { |bg| eval_call("rg_background_put_up", C::Int.new(@backgrounds.fetch(bg.name))) }]
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
