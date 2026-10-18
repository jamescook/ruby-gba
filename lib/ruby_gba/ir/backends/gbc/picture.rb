# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        # THE PICTURE, said for a Game Boy Color: the statements that draw, as calls into
        # Runtime::Picture, and the art they draw with, made into tiles and palettes (GBC::Art).
        # Mixed into Lowering, over Native's picture, which it borrows from where the two agree —
        # which picture a sprite shows now, in which colours (Native::Picture#picture_drawn and the
        # rest) — and replaces where the Color draws for itself.
        #
        # On the Advance's desktop build the runtime paints every pixel; on the Color the console
        # does. So nothing here is painted: a sprite is entries in the console's sprite table, a
        # background is its grid of cells, and what the game does to either changes those.
        module Picture
          C = Native::C

          # The art the program's pictures were made into, for the cartridge to keep.
          def art = @art

          private

          def prepare_picture
            @stacking = Stacking.picture(@program)
            @handover = SceneHandover.of(@program)
            @objects = by_name(@program.walk, :object)
            @color_lists = by_name(@program.walk, :color_list)
            @tile_runs = {} # Native's picture_named asks; the Color build refuses a painted tile first
            @art = Art.new
            @grids = {} # a background declaration -> its grid's number
            @drawing_arrays = []
          end

          # --- the screen ---

          # A screen drawn from tiles is what a Color has. A turning screen is shown as one that
          # does not turn (Console::GBCFeatures), which the interpreter shows the same way when it
          # plays the game for a Color. A painted screen is not made yet.
          def lower_screen(node)
            return [] unless node.mode == :bitmap

            raise LoweringError, "this program paints its screen (`screen :bitmap`), which #{build_name} cannot make yet."
          end

          # --- backgrounds ---

          # Reference#exec_background: a scene's own scenery goes up as the scene arrives, not here;
          # any other is put up each time this runs.
          def lower_background(node)
            return [] if @handover.on_arrival?(node)

            [background_put_up(node)]
          end

          def background_put_up(bg) = eval_call("rg_gbc_background_put_up", C::Int.new(grid_of(bg)))

          def lower_scroll_background(node)
            background_number(node) # refuses a background nobody declared
            [eval_call("rg_gbc_background_scroll", value(node.x), value(node.y))]
          end

          # A background's cells as the Color's grid of 32×32 holds them: each cell's tile and
          # palette, and nothing — the backdrop — where the map has no tile or does not reach.
          def grid_of(bg)
            @grids[bg] ||= begin
              refuse_background!(bg)
              map = bg.every_map.first
              cells = Array.new(Art::GRID_CELLS) do |row|
                Array.new(Art::GRID_CELLS) do |col|
                  tile = map[row] && map[row][col]
                  next nil if tile.nil? || tile.negative?

                  name = bg.tiles.fetch(tile)
                  @art.background_tile(name, Assets::Image.of(@data.fetch(name)))
                end
              end
              @art.grid(cells)
            end
          end

          def refuse_background!(bg)
            cols, rows = TileMap.size_of(bg.every_map.first)
            what = if bg.every_map.length > 1 then "several maps"
                   elsif cols > Art::GRID_CELLS || rows > Art::GRID_CELLS then "a map of #{cols}×#{rows} cells"
                   elsif bg.tile_w != 8 || bg.tile_h != 8 then "tiles of #{bg.tile_w}×#{bg.tile_h}"
                   elsif !Array(bg.recolors).empty? then "other colours to draw it with"
                   elsif bg.streams? then "a map that streams"
                   end
            return unless what

            raise LoweringError, "the background #{bg.name.inspect} has #{what}, which #{build_name} cannot make yet."
          end

          # --- sprites ---

          # Reference#exec_present_objects: every sprite the frame draws, written into the console's
          # sprite table front-most first — the order the Color draws them in, where the
          # interpreter paints the back-most first.
          def lower_present_objects(node)
            refuse_ordered_runs!(node)
            objects = node.names.map { |name| presented_object(name) }
            front_first = objects.each_with_index.sort_by { |obj, at| [sprite_level(obj), at] }.map(&:first).reverse
            [eval_call("rg_gbc_sprites_begin"), *front_first.map { |obj| sprite_placement(obj) },
             eval_call("rg_gbc_sprites_end")]
          end

          def refuse_ordered_runs!(node)
            return if Array(node.orders).empty?

            raise LoweringError, "this program draws sprites in an order worked out as it runs (`draw_in_order`), " \
                                 "which #{build_name} cannot make yet."
          end

          # How deep a sprite sits: the one level it is declared at. One that changes layer as the
          # game runs is not made yet.
          def sprite_level(obj)
            levels = Stacking.levels_of(@stacking.depths, obj)
            return levels.first if levels.one?

            raise LoweringError, "the sprite #{obj.declared.inspect} changes layer as the game runs, which #{build_name} " \
                                 "cannot make yet."
          end

          # Reference#objects_on_screen: a sprite is drawn when it is switched on and its pose names
          # one of its pictures. It is drawn behind the background when the background's layer is in
          # front of its own; the background's see-through pixels still show it.
          def sprite_placement(obj)
            refuse_turning_sprite!(obj)
            pose = local_name("pose")
            in_range = call("rg_both", call("rg_ge", pose, C::Int.new(0)), call("rg_lt", pose, C::Int.new(obj.poses.length)))
            picture, palette = picture_and_palette_drawn(obj, pose)
            add = eval_call("rg_gbc_sprite", picture, value(obj.x), value(obj.y), palette, yes_or_no(behind_scenery?(obj)))
            C::If.new(condition: call("rg_eq", value(obj.active), C::Int.new(1)),
                      body: [C::Block.new([C::Local.new(name: pose, value: value(obj.pose)),
                                           C::If.new(condition: in_range, body: [add])])])
          end

          def behind_scenery?(obj)
            level = sprite_level(obj)
            @stacking.scenery.any? { |bg| @stacking.depths[bg.name] > level }
          end

          def refuse_turning_sprite!(obj)
            return unless turns_or_resizes?(obj)

            raise LoweringError, "the sprite #{obj.declared.inspect} turns or changes size, which #{build_name} cannot " \
                                 "make yet."
          end

          # Native::Picture#picture_drawn, for the Color: which picture a sprite showing pose number
          # +pose+ is drawn from and which palette it is drawn in, now. Its pictures are a row of
          # poses in its own colours, then a row for each list it can be drawn with, so the two
          # tables are read at the same place.
          def picture_and_palette_drawn(obj, pose)
            lists = Array(obj.recolors)
            sets = [[nil], *lists.map { |colors| colors.is_a?(Symbol) ? sets_held_by(colors) : [colors] }]
            rows = sets.flatten(1).flat_map { |colors| obj.poses.map { |name| [picture_number(name), palette_of(name, colors)] } }
            pictures = drawing_array("pose_pictures", "int16_t", rows.map(&:first))
            palettes = drawing_array("pose_palettes", "uint8_t", rows.map(&:last))
            at = if lists.empty?
                   pose
                 else
                   call("rg_add", call("rg_mul", row_drawn_with(obj, lists, sets), C::Int.new(obj.poses.length)), pose)
                 end
            [C::Index.new(pictures, at), C::Index.new(palettes, at)]
          end

          def picture_number(name) = @art.sprite_picture(name, picture_named(name)).number

          # The palette picture +name+ is drawn in with the list +colors+ (nil for its own): the
          # colour each of its places shows, as the interpreter draws it (Native's #sprite_pixels).
          def palette_of(name, colors)
            image = picture_named(name)
            @art.sprite_palette(name, image, sprite_pixels(image, colors))
          end

          # Reference#pixels_overlap?: each side's picture now, and where the second stands from
          # the first.
          def value_of_pixels_overlap(node)
            call("rg_gbc_pixels_overlap", picture_collided(node.a_poses, node.a_pose),
                 picture_collided(node.b_poses, node.b_pose),
                 call("rg_sub", value(node.b_x), value(node.a_x)), call("rg_sub", value(node.b_y), value(node.a_y)))
          end

          # Which picture a sprite collides as: the one of +poses+ its pose names, counted back
          # from the last for a pose below nought (Reference#collision_sprite).
          def picture_collided(poses, pose)
            pictures = drawing_array("collision_pictures", "int16_t", poses.map { |name| picture_number(name) })
            C::Index.new(pictures, call("rg_pose_place", value(pose), C::Int.new(poses.length)))
          end

          # --- a scene taking the screen over (Reference#take_over) ---

          # The scenery a scene shows goes up as it arrives.
          def scene_arrival(scene)
            arrival = @handover.arrival(scene)
            [*arrival.map_choices.map { |var| assign(var, C::Int.new(0)) },
             *arrival.scenery.map { |bg| background_put_up(bg) }]
          end
        end
      end
    end
  end
end
