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
            @paint_colors = paint_colors
            @art = Art.new(paint_colors: @paint_colors&.first(Art::PLACES))
            @grids = {} # a background declaration -> its grid's number
            # Every background's name, for a statement naming one (Native's #background_number).
            @backgrounds = @program.walk.select { |node| node.kind == :background }.to_h { |bg| [bg.name, 0] }
            @drawing_arrays = []
          end

          # --- the screen ---

          # THE KINDS THAT PAINT, and the colour (or colours) each says.
          PAINTING = Ractor.make_shareable({ clear_screen: %i[color], fill_rect: %i[color], dma_fill_rect: %i[color],
                                             draw_rect_at: %i[color], pixel: %i[color], draw_text: %i[color picked],
                                             draw_digit: %i[color] })

          # The colours this program paints a screen in, black first — the colour a painted screen
          # starts in — or nil for a program that paints nothing.
          def paint_colors
            painting = @program.walk.select { |node| PAINTING.key?(node.kind) }
            return nil if painting.empty?

            [0, *colors_painted.map { |name| Graphics::Color.resolve(name) & 0x7FFF }].uniq
          end

          def colors_painted
            painting = @program.walk.select { |node| PAINTING.key?(node.kind) }
            painting.flat_map { |node| PAINTING.fetch(node.kind).filter_map { |field| node.public_send(field) } }
          end

          # A painted screen on a Color holds four colours at once (Runtime::Paint), so a program
          # that paints in more is refused, naming them.
          def refuse_too_many_paint_colors!
            return if @paint_colors.nil? || @paint_colors.length <= Art::PLACES

            names = colors_painted.uniq.map { |name| name.is_a?(Symbol) ? name.inspect : name.to_s }
            raise LoweringError, "this program paints its screen in #{@paint_colors.length} colours (black and " \
                                 "#{names.join(', ')}), and a painted Game Boy Color screen holds #{Art::PLACES} " \
                                 "at once, black among them. To fix this, paint it in fewer colours."
          end

          # A screen drawn from tiles is what a Color has. A turning screen is shown as one that
          # does not turn (Console::GBCFeatures), which the interpreter shows the same way when it
          # plays the game for a Color. A painted screen is 360 tiles of the background's
          # (Runtime::Paint). A change between the two replaces the display (rg_gbc_screen), and
          # what every tiled screen shows is put up again then (Reference#put_up_always_up).
          def lower_screen(node) = screen_change(node.mode)

          def screen_change(mode)
            painted = mode == :bitmap
            change = call("rg_gbc_screen", C::Int.new(painted ? Runtime::Paint::PAINTED : Runtime::Paint::TILED))
            put_back = painted ? [] : always_up_put_up
            return [C::Eval.new(change)] if put_back.empty?

            [C::If.new(condition: change, body: put_back)]
          end

          def always_up_put_up
            always = @handover.always_up
            [*always.map_choices.map { |var| assign(var, C::Int.new(0)) }, *always.scenery.map { |bg| background_put_up(bg) }]
          end

          # --- painting ---

          def lower_clear_screen(node) = [eval_call("rg_gbc_paint_clear", ink(node.color))]

          # Framebuffer#fill_rect: from the corner up to the corner past the far edge.
          def lower_fill_rect(node)
            x = value(node.x)
            y = value(node.y)
            [eval_call("rg_gbc_paint_rect", x, y, call("rg_add", value(node.x), value(node.w)),
                       call("rg_add", value(node.y), value(node.h)), ink(node.color))]
          end

          alias lower_dma_fill_rect lower_fill_rect
          alias lower_draw_rect_at lower_fill_rect

          def lower_pixel(node) = [paint_bits(node.x, node.y, ink(node.color), [[0, 0]])]

          # The pixels of a line of text are known when the game is built, so they are handed
          # over as a picture rather than worked out from the font as it runs (Reference#exec_draw_text).
          def lower_draw_text(node)
            points = node.fonts.get(node.font).enum_for(:each_pixel, node.text).to_a
            return [] if points.empty?

            color = node.picked ? picked_ink(node.showing, node.color, node.picked) : ink(node.color)
            [paint_bits(node.x, node.y, color, points)]
          end

          # Reference#exec_draw_digit: each digit's picture, the one the value names drawn; a value
          # outside 0..9 draws nothing.
          def lower_draw_digit(node)
            font = node.fonts.get(node.font)
            digit = local_name("digit")
            draws = (0..9).map do |d|
              points = font.enum_for(:each_pixel, d.to_s).to_a
              C::If.new(condition: call("rg_eq", digit, C::Int.new(d)),
                        body: points.empty? ? [] : [paint_bits(node.x, node.y, ink(node.color), points)])
            end
            [C::Block.new([C::Local.new(name: digit, value: value(node.value)), *draws])]
          end

          # The call that paints +points+ (pairs across and down from (x, y)) in +color+, as a
          # picture of a bit a pixel (Runtime::Paint's rg_gbc_paint_bits): rows of bytes, the
          # leftmost pixel in the top bit, with a byte of nothing either side of each row. A
          # picture whose first pixel is not at its corner is drawn that much further on.
          #
          # A picture at a column written in the program is laid out already lined up with the
          # screen's tiles — moved right within its first byte by as much as it stands past a
          # multiple of eight — so the runtime has no shifting to do.
          def paint_bits(x, y, color, points)
            left = points.map(&:first).min
            top = points.map(&:last).min
            across = value(x)
            lined_up = across.is_a?(C::Int) ? (across.value + left) % 8 : 0
            width = points.map(&:first).max - left + 1 + lined_up
            height = points.map(&:last).max - top + 1
            stride = ((width + 7) / 8) + 2
            bytes = Array.new(stride * height, 0)
            points.each do |dx, dy|
              col = dx - left + lined_up
              bytes[((dy - top) * stride) + 1 + (col / 8)] |= 0x80 >> (col % 8)
            end
            eval_call("rg_gbc_paint_bits", moved(across, left - lined_up), moved(value(y), top), color,
                      drawing_array("bits", "uint8_t", bytes), C::Int.new(stride), C::Int.new(height))
          end

          def moved(place, by) = by.zero? ? place : call("rg_add", place, C::Int.new(by))

          # The place a painted colour is kept at (GBC::Art#paint_place).
          def ink(name) = C::Int.new(@art.paint_place(Graphics::Color.resolve(name)))

          # rg_pick_color: +picked+ while +showing+ is not nought, +color+ otherwise.
          def picked_ink(showing, color, picked)
            plain = @art.paint_place(Graphics::Color.resolve(color))
            other = @art.paint_place(Graphics::Color.resolve(picked))
            call("rg_add", C::Int.new(plain), call("rg_mul", call("rg_ne", value(showing), C::Int.new(0)), C::Int.new(other - plain)))
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

          # A background turned or resized: a Color cannot do either, so it is shown as drawn, as the
          # interpreter shows it for a console that cannot turn a layer (Console::GBCFeatures).
          def lower_affine_background(node)
            background_number(node) # refuses a background nobody declared
            []
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
            # A pose the program never changes is used as it is, so the build can see it is in range.
            said = value(obj.pose)
            pose = said.is_a?(C::Int) ? said : local_name("pose")
            in_range = call("rg_below", pose, C::Int.new(obj.poses.length))
            picture, attributes = picture_and_attributes_drawn(obj, pose)
            add = fixed_sprite(obj, pose) ||
                  eval_call("rg_gbc_sprite", picture, value(obj.x), value(obj.y), attributes)
            kept = said.is_a?(C::Int) ? [] : [C::Local.new(name: pose, value: said)]
            C::If.new(condition: call("rg_eq", value(obj.active), C::Int.new(1)),
                      body: [C::Block.new([*kept, C::If.new(condition: in_range, body: [add])])])
          end

          # A sprite whose picture, place and colours are all written in the program — a letter of
          # tiled text — is placed from a record of the four kept in the cartridge
          # (rg_gbc_sprite_fixed), with nothing worked out as the game runs.
          def fixed_sprite(obj, pose)
            x = value(obj.x)
            y = value(obj.y)
            return nil unless [x, y, pose].all?(C::Int) && Array(obj.recolors).empty?

            name = obj.poses.fetch(pose.value)
            attributes = palette_of(name, nil) | (behind_scenery?(obj) ? Console::GBCHardware::OBJ_BEHIND : 0)
            record = [picture_number(name), x.value, y.value, attributes]
            eval_call("rg_gbc_sprite_fixed", drawing_array("fixed_sprite", "int16_t", record))
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
          # +pose+ is drawn from, and the attributes its pieces are drawn with — which palette, and
          # whether behind the background — now. Its pictures are a row of poses in its own colours,
          # then a row for each list it can be drawn with, so the two tables are read at the same
          # place.
          def picture_and_attributes_drawn(obj, pose)
            lists = Array(obj.recolors)
            sets = [[nil], *lists.map { |colors| colors.is_a?(Symbol) ? sets_held_by(colors) : [colors] }]
            behind = behind_scenery?(obj) ? Console::GBCHardware::OBJ_BEHIND : 0
            rows = sets.flatten(1).flat_map do |colors|
              obj.poses.map { |name| [picture_number(name), palette_of(name, colors) | behind] }
            end
            pictures = drawing_array("pose_pictures", "int16_t", rows.map(&:first))
            palettes = drawing_array("pose_attributes", "uint8_t", rows.map(&:last))
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

          # --- fades and tints ---

          # Reference#exec_fade, as a fade that walks the colours (IR::Fading walks every fade on a
          # console that cannot blend): toward black or white by the thirty-seconds the amount
          # comes to. A fade placed in the stack, or held to part of the screen, needs the blend.
          def lower_fade(node)
            if node.under || node.reaches
              raise LoweringError, "this program fades #{node.under ? "under a layer (`under:`)" : "part of the screen (`#{node.reaches}:`)"}, " \
                                   "and a Game Boy Color can only fade the whole screen. To fix this, leave it out."
            end

            toward = node.toward == :white ? Runtime::Picture::TOWARD_WHITE : Runtime::Picture::TOWARD_BLACK
            [eval_call("rg_gbc_tint", C::Int.new(toward), C::Int.new(0), walk_steps(node))]
          end

          # Reference#exec_tint: toward the colour, in thirty-seconds.
          def lower_tint(node)
            [eval_call("rg_gbc_tint", C::Int.new(Runtime::Picture::TOWARD_COLOR), color(node.color), walk_steps(node))]
          end

          # FadeSteps.steps for a fade that walks the colours: the amount (0..100, or a fraction
          # of +fraction_bits+) as thirty-seconds — finely for a fraction, in whole sixteenths
          # otherwise — held to 0..32. The runtime holds it there too.
          def walk_steps(node)
            amount = value(node.amount)
            if node.fraction_bits
              call("rg_div", call("rg_mul", amount, C::Int.new(Runtime::Picture::STEPS)), C::Int.new(100 << node.fraction_bits))
            else
              sixteenths = call("rg_clamp", call("rg_div", call("rg_mul", amount, C::Int.new(16)), C::Int.new(100)),
                                C::Int.new(0), C::Int.new(16))
              call("rg_mul", sixteenths, C::Int.new(2))
            end
          end

          # --- a scene taking the screen over (Reference#take_over) ---

          # The scene's screen, then its scenery: what it shows goes up as it arrives, and what
          # the scene before it showed of its own comes down — leaving what every screen shows, or
          # nothing.
          def scene_arrival(scene)
            arrival = @handover.arrival(scene)
            screen = arrival.screen ? lower_screen(arrival.screen) : screen_change(Modes::SCREEN_OF_MODE.fetch(arrival.mode))
            scenery = arrival.scenery.empty? ? @handover.always_up.scenery : arrival.scenery
            up = scenery.empty? ? [eval_call("rg_gbc_background_put_up", C::Int.new(0))] : scenery.map { |bg| background_put_up(bg) }
            [*screen, *arrival.map_choices.map { |var| assign(var, C::Int.new(0)) }, *up]
          end
        end
      end
    end
  end
end
