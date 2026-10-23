# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        class Lowering
          # THE PICTURE, lowered for a Game Boy Color: the statements that draw, as calls into
          # Runtime::Picture and Runtime::Paint, and the art they draw with, made into tiles and
          # palettes (GBC::Art). Mixed into Lowering.
          #
          # On the Advance's desktop build the runtime paints every pixel; on the Color the console
          # does. So little here is painted: a sprite is entries in the console's sprite table, a
          # background is its grid of cells, and what the game does to either changes those. A
          # painted screen (`screen :bitmap`) is the one exception, 360 tiles the runtime paints
          # into (Runtime::Paint).
          module Picture
            STATEMENTS = Ractor.make_shareable({
                                                 screen: :emit_screen, clear_screen: :emit_clear_screen,
                                                 fill_rect: :emit_fill_rect, dma_fill_rect: :emit_fill_rect,
                                                 draw_rect_at: :emit_fill_rect, pixel: :emit_pixel,
                                                 draw_text: :emit_draw_text, draw_digit: :emit_draw_digit,
                                                 inside: :emit_inside, blit: :emit_blit, blit_pose: :emit_blit_pose,
                                                 draw_column_at: :emit_draw_column_at,
                                                 save_region: :emit_save_region, restore_region: :emit_restore_region,
                                                 background: :emit_background, scroll_background: :emit_scroll_background,
                                                 affine_background: :emit_affine_background,
                                                 present_objects: :emit_present_objects,
                                                 color_list_holds: :emit_color_list_holds,
                                                 fade: :emit_fade, tint: :emit_tint
                                               })

            VALUES = Ractor.make_shareable({ pixels_overlap: :value_of_pixels_overlap })

            # THE KINDS THAT PAINT, and the colour (or colours) each says.
            PAINTING = Ractor.make_shareable({ clear_screen: %i[color], fill_rect: %i[color], dma_fill_rect: %i[color],
                                               draw_rect_at: %i[color], pixel: %i[color], draw_text: %i[color picked],
                                               draw_digit: %i[color] })

            # THE KINDS THAT PUT A PICTURE DOWN, and the field naming the picture (or pictures): each
            # paints in every colour its picture draws.
            PUTTING_DOWN = Ractor.make_shareable({ blit: :name, blit_pose: :poses, draw_column_at: :name })

            # What a column of a picture is handed over in (#emit_draw_column_at), the height first.
            COLUMN = %i[height slice x top width].freeze

            # The art the program's pictures were made into, for the cartridge to keep.
            attr_reader :art

            private

            def prepare_picture
              @stacking = Stacking.picture(@program)
              @objects = by_name(@program.walk, :object)
              @color_lists = by_name(@program.walk, :color_list)
              @pictures = by_name(@program.walk, :data, :bitmap)
              @paint_colors = paint_colors
              @art = Art.new(paint_colors: @paint_colors&.first(Art::PLACES))
              @grids = {} # a background declaration -> its grid's number
              @backgrounds = by_name(@program.walk, :background)
              @drawn_sprites = SpriteNames.new(@program) # the numbers a run says its sprites by
              @patches = by_name(@program.walk, :backing_buffer) # what sprites on a painted screen cover
              @column_routines = {} # a picture drawn a column at a time -> its routine's label
              @drawing_tables = [] # [label, bytes an entry, the entries] for the data
            end

            # Each colour list's own number, saying which of its sets it holds now (Reference
            # @held_colors), from power-on the one it was declared with.
            def keep_held_colors
              @held_colors = @color_lists.keys.to_h { |name| [name, keep_local(:"held_#{name}", start: Build::NO_RECOLOR)] }
            end

            def by_name(nodes, *kinds) = nodes.select { |node| kinds.include?(node.kind) }.to_h { |node| [node.name, node] }

            def build_name = "the Game Boy Color build"

            # --- refusals ---

            # The colours this program paints a screen in, black first — the colour a painted screen
            # starts in — or nil for a program that paints nothing.
            def paint_colors
              painting = @program.walk.select { |node| PAINTING.key?(node.kind) || PUTTING_DOWN.key?(node.kind) }
              return nil if painting.empty?

              [0, *colors_painted.map { |name| Graphics::Color.resolve(name) & 0x7FFF }].uniq
            end

            def colors_painted
              @program.walk.flat_map do |node|
                if PAINTING.key?(node.kind)
                  PAINTING.fetch(node.kind).filter_map { |field| node.public_send(field) }
                elsif PUTTING_DOWN.key?(node.kind)
                  Array(node.public_send(PUTTING_DOWN.fetch(node.kind))).flat_map { |name| picture_named(name).colors_drawn }
                else
                  []
                end
              end
            end

            # A painted screen on a Color holds four colours at once (Runtime::Paint), so a program
            # that paints in more is refused, naming them.
            def refuse_too_many_paint_colors!
              return if @paint_colors.nil? || @paint_colors.length <= Art::PLACES

              names = @paint_colors.drop(1).map do |value|
                name = Graphics::Color.name_for(value)
                name.is_a?(Symbol) ? name.inspect : name
              end
              raise LoweringError, "this program paints its screen in #{@paint_colors.length} colours (black and " \
                                   "#{names.join(', ')}), and a painted Game Boy Color screen holds #{Art::PLACES} " \
                                   "at once, black among them. To fix this, paint it in fewer colours."
            end

            # --- the screen ---

            # A screen drawn from tiles is what a Color has. A turning screen is shown as one that
            # does not turn (Console::GBCFeatures), which the interpreter shows the same way when it
            # plays the game for a Color. A painted screen is 360 tiles of the background's
            # (Runtime::Paint). A change between the two replaces the display (rt_screen), and
            # what every tiled screen shows is put up again then (Reference#put_up_always_up). A
            # tear-free screen is two pages to the interpreter, which changes nothing in how the
            # Color shows it but when a timer's tick draws on it (Runtime::Frame, rt_two_pages).
            def emit_screen(node)
              screen_change(node.mode)
              runtime_call("rt_two_pages", [Build.int(node.buffered ? 1 : 0)])
            end

            def screen_change(mode)
              painted = mode == :bitmap
              runtime_call("rt_screen", [Build.int(painted ? Runtime::Paint::PAINTED : Runtime::Paint::TILED)])
              return if painted

              always = @handover.always_up
              return if always.map_choices.empty? && always.scenery.empty?

              unchanged = fresh("screen_unchanged")
              @asm.call("rt_test32")
              @asm.jump(:z, unchanged)
              always.map_choices.each do |var|
                load_constant(0)
                store(var)
              end
              always.scenery.each { |bg| background_put_up(bg) }
              @asm.label(unchanged)
            end

            # The scene's screen, then its scenery: what it shows goes up as it arrives, and what the
            # scene before it showed of its own comes down — leaving what every screen shows, or
            # nothing (Reference#take_over).
            def emit_scene_arrival(scene)
              arrival = @handover.arrival(scene)
              if arrival.screen
                emit_screen(arrival.screen)
              else
                screen_change(Modes::SCREEN_OF_MODE.fetch(arrival.mode))
                runtime_call("rt_two_pages", [Build.int(arrival.mode == Modes::BUFFERED ? 1 : 0)])
              end
              arrival.map_choices.each do |var|
                load_constant(0)
                store(var)
              end
              scenery = arrival.scenery.empty? ? @handover.always_up.scenery : arrival.scenery
              return runtime_call("rt_background_put_up", [Build.int(0)]) if scenery.empty?

              scenery.each { |bg| background_put_up(bg) }
            end

            # --- painting ---

            def emit_clear_screen(node) = runtime_call("rt_paint_clear", [ink(node.color)])

            # Reference#exec_inside: what the block paints is held to the edges, which are numbers
            # written in the program, and the area held to before is put back after it — a routine
            # with an area of its own can be called from inside another's. A program that paints
            # nothing has no area to hold.
            def emit_inside(node)
              return node.children.each { |child| statement(child) } unless @paint_colors

              outer = keep_local(:area)
              edges = [node.x, node.y, node.x + node.w, node.y + node.h]
              limits = Runtime::Paint::WHOLE_SCREEN.values_at(2, 3, 2, 3)
              area = edges.zip(limits).each_with_index.sum { |(edge, limit), at| edge.clamp(0, limit) << (8 * at) }
              runtime_call("rt_paint_area", [Build.int(Int32.wrap(area))])
              store(outer)
              node.children.each { |child| statement(child) }
              runtime_call("rt_paint_area", [outer])
            end

            # Framebuffer#fill_rect: from the corner up to the corner past the far edge.
            def emit_fill_rect(node)
              runtime_call("rt_paint_rect", [node.x, node.y, Build.binop(:+, node.x, node.w),
                                                 Build.binop(:+, node.y, node.h), ink(node.color)])
            end

            def emit_pixel(node) = paint_bits(node.x, node.y, ink(node.color), [[0, 0]])

            # The pixels of a line of text are known when the game is built, so they are handed over
            # as a picture rather than worked out from the font as it runs (Reference#exec_draw_text).
            def emit_draw_text(node)
              points = node.fonts.get(node.font).enum_for(:each_pixel, node.text).to_a
              return if points.empty?

              color = node.picked ? picked_ink(node.showing, node.color, node.picked) : ink(node.color)
              paint_bits(node.x, node.y, color, points)
            end

            # Reference#exec_draw_digit: each digit's picture, the one the value names drawn; a value
            # outside 0..9 draws nothing.
            def emit_draw_digit(node)
              font = node.fonts.get(node.font)
              digit = keep_local(:digit)
              value(node.value)
              store(digit)
              (0..9).each do |d|
                points = font.enum_for(:each_pixel, d.to_s).to_a
                next if points.empty?

                other = fresh("not_digit")
                jump_unless(Build.binop(:==, Build.var_ref(digit), Build.int(d)), other)
                paint_bits(node.x, node.y, ink(node.color), points)
                @asm.label(other)
              end
            end

            # The call that paints +points+ (pairs across and down from (x, y)) in +color+, as a
            # picture of a bit a pixel (Runtime::Paint's rt_paint_bits): rows of bytes, the
            # leftmost pixel in the top bit, with a byte of nothing either side of each row. A
            # picture whose first pixel is not at its corner is drawn that much further on.
            #
            # A picture at a column written in the program is laid out already lined up with the
            # screen's tiles — moved right within its first byte by as much as it stands past a
            # multiple of eight — so the runtime has no shifting to do.
            def paint_bits(x, y, color, points)
              left = points.map(&:first).min
              top = points.map(&:last).min
              column = folded(x)
              lined_up = column ? (column + left) % 8 : 0
              width = points.map(&:first).max - left + 1 + lined_up
              height = points.map(&:last).max - top + 1
              stride = ((width + 7) / 8) + 2
              bytes = Array.new(stride * height, 0)
              points.each do |dx, dy|
                col = dx - left + lined_up
                bytes[((dy - top) * stride) + 1 + (col / 8)] |= 0x80 >> (col % 8)
              end
              runtime_call("rt_paint_bits", [moved(x, left - lined_up), moved(y, top), color,
                                                 Address.new(drawing_table("bits", 1, bytes)), Build.int(stride), Build.int(height)])
            end

            def moved(place, by) = by.zero? ? place : Build.binop(:+, place, Build.int(by))

            # Reference#blit_image: a picture with its top left at (x, y), its see-through pixels
            # leaving the screen as it was. A pixel of a painted screen is one of four colours, so
            # the picture goes down as one picture of a bit a pixel for each colour it draws.
            def emit_blit(node) = picture_put_down(picture_named(node.name), node.x, node.y)

            def picture_put_down(image, x, y)
              points = Hash.new { |by_color, color| by_color[color] = [] }
              (image.width * image.height).times do |at|
                points[image.color_at(at)] << at.divmod(image.width).reverse if image.drawn_at?(at)
              end
              points.each { |color, drawn| paint_bits(x, y, Build.int(@art.paint_place(color)), drawn) }
            end

            # Reference#exec_blit_pose: the one of the pictures the number names, and none for a
            # number outside them.
            def emit_blit_pose(node)
              which = keep_local(:pose)
              value(node.index)
              store(which)
              node.poses.each_with_index do |name, at|
                other = fresh("not_pose")
                jump_unless(Build.binop(:==, Build.var_ref(which), Build.int(at)), other)
                picture_put_down(picture_named(name), node.x, node.y)
                @asm.label(other)
              end
            end

            # Reference#exec_draw_column_at: one column of a picture stretched to a height worked out
            # as the game runs. What is drawn is handed over in numbers the program keeps once
            # (COLUMN), the height first — a height of nought or less draws nothing, and the others
            # are not worked out — and the picture's own routine walks it (#emit_column_routines).
            def emit_draw_column_at(node)
              column = column_numbers
              label = @column_routines[node.name] ||= "column of #{node.name}"
              value(node.height)
              store(column.fetch(:height))
              done = fresh("no_height")
              jump_unless(Build.binop(:>, Build.var_ref(column.fetch(:height)), Build.int(0)), done)
              %i[slice x top].each do |what|
                value(node.public_send(what))
                store(column.fetch(what))
              end
              load_constant(node.width || 1)
              store(column.fetch(:width))
              call_routine(label)
              @asm.label(done)
            end

            def column_numbers = @column_numbers

            # The numbers a column is handed over in, kept before any routine is made — not the first
            # time one is drawn, which may be in code made only to be measured.
            def keep_column_numbers
              return unless @reachable.any? { |node| node.kind == :draw_column_at }

              @column_numbers = COLUMN.to_h { |what| [what, keep_local(:"column_#{what}")] }
            end

            # The routine that draws a column of each picture drawn so: walked down the screen a row
            # at a time, each row the picture's row the step in 65536ths lands it on, painted across
            # the strip's width, a see-through one left as it was. Only the rows on the screen are
            # walked.
            def column_sections
              @column_routines.map do |name, label|
                image = picture_named(name)
                places = Array.new(image.width * image.height) do |at|
                  image.drawn_at?(at) ? @art.paint_place(image.color_at(at)) : -1
                end
                table = drawing_table("column_places", 2, places)
                routine_section(label, [], routine: "#{name.inspect} drawn a column at a time") { emit_column_walk(image, table) }
              end
            end

            def emit_column_walk(image, table)
              height, x, top, width = column_numbers.values_at(:height, :x, :top, :width).map { |name| Build.var_ref(name) }
              slice, step, row, last, place = %i[slice step row last place].map { |what| keep_local(what) }
              fixed = Build.int(Reference::FIXED)
              value(Build.clamped(Build.var_ref(column_numbers.fetch(:slice)), Build.int(0), Build.int(image.width - 1)))
              store(slice)
              value(Build.binop(:/, Build.int(image.height << Reference::FIXED), height))
              store(step)
              value(Build.clamped(Build.neg(top), Build.int(0), Build.int(Int32::MAX)))
              store(row)
              value(Build.clamped(height, Build.int(Int32::MIN), Build.binop(:-, Build.int(Console::GBCHardware::SCREEN_HEIGHT), top)))
              store(last)
              walk = fresh("row")
              done = fresh("rows_done")
              @asm.label(walk)
              jump_unless(Build.binop(:<, Build.var_ref(row), Build.var_ref(last)), done)
              source = Build.clamped(Build.binop(:>>, Build.binop(:*, Build.var_ref(row), Build.var_ref(step)), fixed),
                                     Build.int(0), Build.int(image.height - 1))
              value(Entry.new(table, 2, true, Build.binop(:+, Build.binop(:*, source, Build.int(image.width)), Build.var_ref(slice))))
              store(place)
              see_through = fresh("see_through")
              jump_unless(Build.binop(:!=, Build.var_ref(place), Build.int(-1)), see_through)
              down = Build.binop(:+, top, Build.var_ref(row))
              runtime_call("rt_paint_rect", [x, down, Build.binop(:+, x, width), Build.binop(:+, down, Build.int(1)),
                                                 Build.var_ref(place)])
              @asm.label(see_through)
              add_in_place(place_of(row), 1)
              @asm.jump(walk)
              @asm.label(done)
            end

            # Reference#exec_save_region and #exec_restore_region: a patch of the picture kept in the
            # memory set aside for it, and painted back (Runtime::Paint's rt_paint_save and
            # rt_paint_restore).
            def emit_save_region(node) = patch_call("rt_paint_save", node)
            def emit_restore_region(node) = patch_call("rt_paint_restore", node)

            def patch_call(routine, node)
              buffer = @patches.fetch(node.buffer) { raise LoweringError, "backing buffer #{node.buffer.inspect} is used and never declared" }
              runtime_call(routine, [Build.int(@patch_places.fetch(node.buffer)), Build.int(buffer.width), Build.int(buffer.height),
                                     node.x, node.y])
            end

            # The memory each patch is kept in, a byte a pixel after a header's room (the runtime
            # takes its patches as it takes a list's storage), starting cleared: nothing kept.
            def keep_patches
              @patch_places = @patches.values.to_h do |buffer|
                [buffer.name, @memory.reserve("the patch #{buffer.name.inspect}", Runtime::Lists::HEADER + (buffer.width * buffer.height))]
              end
            end

            # The place a painted colour is kept at (GBC::Art#paint_place).
            def ink(name) = Build.int(@art.paint_place(Graphics::Color.resolve(name)))

            # +picked+ while +showing+ is not nought, +color+ otherwise.
            def picked_ink(showing, color, picked)
              plain = @art.paint_place(Graphics::Color.resolve(color))
              other = @art.paint_place(Graphics::Color.resolve(picked))
              Build.binop(:+, Build.int(plain), Build.binop(:*, Build.binop(:!=, showing, Build.int(0)), Build.int(other - plain)))
            end

            # --- backgrounds ---

            # Reference#exec_background: a scene's own scenery goes up as the scene arrives, not here;
            # any other is put up each time this runs.
            def emit_background(node)
              background_put_up(node) unless @handover.on_arrival?(node)
            end

            def background_put_up(bg) = runtime_call("rt_background_put_up", [Build.int(grid_of(bg))])

            def emit_scroll_background(node)
              declared_background!(node)
              runtime_call("rt_background_scroll", [node.x, node.y])
            end

            # A background turned or resized: a Color cannot do either, so it is shown as drawn, as
            # the interpreter shows it for a console that cannot turn a layer (Console::GBCFeatures).
            def emit_affine_background(node) = declared_background!(node)

            def declared_background!(node)
              @backgrounds.fetch(node.name) { raise LoweringError, "#{node.kind} of undeclared background #{node.name.inspect}" }
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
                    @art.background_tile(name, Assets::Image.of(@pictures.fetch(name)))
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
            def emit_present_objects(node)
              refuse_ordered_runs!(node)
              objects = node.names.map { |name| @objects.fetch(name) { raise LoweringError, "present of undeclared object #{name.inspect}" } }
              front_first = objects.each_with_index.sort_by { |obj, at| [sprite_level(obj), at] }.map(&:first).reverse
              @asm.call("rt_sprites_begin")
              front_first.each { |obj| sprite_placement(obj) }
              @asm.call("rt_sprites_end")
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
            # one of its pictures. It is drawn behind the background when the background's layer is
            # in front of its own; the background's see-through pixels still show it.
            def sprite_placement(obj)
              refuse_turning_sprite!(obj)
              hidden = fresh("sprite_hidden")
              jump_unless(Build.binop(:==, value_node(obj.active), Build.int(1)), hidden)
              # A pose the program never changes is used as it is, so the build can see it is in range.
              said = folded(obj.pose)
              pose = said ? Build.int(said) : Build.var_ref(keep_local(:pose))
              unless said
                value(obj.pose)
                store(pose.name)
              end
              unless fixed_sprite(obj, said)
                out_of_range = said ? nil : fresh("pose_out_of_range")
                if out_of_range
                  value(pose)
                  @asm.load(:hl, constant_label(obj.poses.length))
                  @asm.call("rt_cmpu32")
                  @asm.cp_a(1)
                  @asm.jump(:nz, out_of_range)
                end
                if said.nil? || said.between?(0, obj.poses.length - 1)
                  picture, attributes = picture_and_attributes_drawn(obj, pose)
                  runtime_call("rt_sprite", [picture, obj.x, obj.y, attributes])
                end
                @asm.label(out_of_range) if out_of_range
              end
              @asm.label(hidden)
            end

            # A sprite's field as a value: a node, or a variable named by a Symbol.
            def value_node(operand) = operand.is_a?(Symbol) ? Build.var_ref(operand) : operand

            # A sprite whose picture, place and colours are all written in the program — a letter of
            # tiled text — is placed from a record of the four kept in the cartridge
            # (rt_sprite_fixed), with nothing worked out as the game runs. True when it was.
            def fixed_sprite(obj, pose)
              x = folded(obj.x)
              y = folded(obj.y)
              return false unless pose && x && y && Array(obj.recolors).empty? && pose.between?(0, obj.poses.length - 1)

              name = obj.poses.fetch(pose)
              attributes = said_attributes(obj, name, palette_of(name, nil))
              record = [picture_number(name), x, y, attributes & 0xFFFF, attributes >> 16]
              runtime_call("rt_sprite_fixed", [Address.new(drawing_table("fixed_sprite", 2, record))])
              true
            end

            def behind_scenery?(obj)
              level = sprite_level(obj)
              @stacking.scenery.any? { |bg| @stacking.depths[bg.name] > level }
            end

            # Reference#object_transformed?: a sprite turns or resizes unless both its angle and its
            # size are still the numbers every sprite starts with.
            def refuse_turning_sprite!(obj)
              return if folded(obj.angle)&.zero? && folded(obj.scale) == Build::SCALE_ONE

              raise LoweringError, "the sprite #{obj.declared.inspect} turns or changes size, which #{build_name} cannot " \
                                   "make yet."
            end

            # Which picture a sprite showing pose number +pose+ is drawn from, and the attributes its
            # pieces are drawn with — which palette, and whether behind the background — now. Its
            # pictures are a row of poses in its own colours, then a row for each list it can be
            # drawn with (Reference#object_recolor), so the two tables are read at the same place. A
            # list that holds other colours as the game runs has a row for every set it can hold, the
            # ones it was declared with first (Reference#colors_held_by).
            def picture_and_attributes_drawn(obj, pose)
              lists = Array(obj.recolors)
              sets = [[nil], *lists.map { |colors| colors.is_a?(Symbol) ? sets_held_by(colors) : [colors] }]
              rows = sets.flatten(1).flat_map do |colors|
                obj.poses.map { |name| [picture_number(name), said_attributes(obj, name, palette_of(name, colors))] }
              end
              pictures = drawing_table("pose_pictures", 2, rows.map(&:first))
              palettes = drawing_table("pose_attributes", 4, rows.map(&:last))
              at = lists.empty? ? pose : Sum.new(:+, Sum.new(:*, row_drawn_with(obj, lists, sets), Build.int(obj.poses.length)), pose)
              [Entry.new(pictures, 2, true, at), Entry.new(palettes, 4, true, at)]
            end

            # Which row of its pictures a sprite is on: the first row of the list it is drawn with now,
            # and for a list that holds other colours, as many rows further as the set it holds.
            def row_drawn_with(obj, lists, sets)
              choice = RuntimeValue.new("rt_place_of_choice", [value_node(obj.recolor), Build.int(lists.length)])
              return choice if lists.none?(Symbol)

              first_rows = sets.each_with_object([0]) { |held, starts| starts << (starts.last + held.length) }
              row = Entry.new(drawing_table("first_rows", 4, first_rows.first(sets.length)), 4, true, choice)
              lists.each_with_index.select { |colors, _| colors.is_a?(Symbol) }.reduce(row) do |so_far, (name, at)|
                held = RuntimeValue.new("rt_place_of_choice", [Build.var_ref(@held_colors.fetch(name)),
                                                                 Build.int(sets_held_by(name).length - 1)])
                Sum.new(:+, so_far, Sum.new(:*, Sum.new(:==, choice, Build.int(at + 1)), held))
              end
            end

            # Reference#colors_held_by: every set of colours a named list can hold, the ones it was
            # declared with first, which is also what a number naming none of the others means.
            def sets_held_by(name)
              list = @color_lists.fetch(name) { raise LoweringError, "a sprite is drawn with the list of colors #{name.inspect}, which is not declared" }
              [list.colors, *list.recolors]
            end

            # Reference#exec_color_list_holds. Nothing is painted here: everything drawn with the list
            # reads what it holds as it is next drawn.
            def emit_color_list_holds(node)
              value(node.which)
              store(@held_colors.fetch(node.name))
            end

            def picture_number(name) = @art.sprite_picture(name, picture_named(name)).number

            # A sprite's attributes as rt_sprite takes them: in the low byte, its palette and
            # whether it is behind the background, as the sprite table keeps them; above that, the
            # numbers a run says it by — whose it is, one up so nought is nobody's, and which picture
            # it is showing.
            def said_attributes(obj, picture, palette)
              behind = behind_scenery?(obj) ? Console::GBCHardware::OBJ_BEHIND : 0
              whose = @drawn_sprites.name_number(obj.declared) + 1
              palette | behind | (whose << 8) | (@drawn_sprites.picture_number(picture) << 16)
            end

            # The palette picture +name+ is drawn in with the list +colors+ (nil for its own): the
            # colour each of its places shows, as the interpreter draws it.
            def palette_of(name, colors)
              image = picture_named(name)
              @art.sprite_palette(name, image, sprite_pixels(image, colors))
            end

            # A sprite picture's pixels as the interpreter draws them (Reference#blit_image): the
            # number the picture stores, the colour +colors+ puts in its place when the sprite is
            # drawn with that list (Assets::Recolor), or Art::NOT_DRAWN where it is see-through.
            def sprite_pixels(image, colors)
              recolor = colors && Assets::Recolor.of(image, colors)
              Array.new(image.width * image.height) do |at|
                next Art::NOT_DRAWN unless image.drawn_at?(at)

                recolor ? recolor.color_for(at, image.raw_at(at)) : image.raw_at(at)
              end
            end

            def picture_named(name)
              Assets::Image.of(@pictures.fetch(name) { raise LoweringError, "a sprite shows the picture #{name.inspect}, which is not defined" })
            end

            # Reference#pixels_overlap?: each side's picture now, and where the second stands from the
            # first.
            def value_of_pixels_overlap(node)
              runtime_call("rt_pixels_overlap", [picture_collided(node.a_poses, node.a_pose),
                                                     picture_collided(node.b_poses, node.b_pose),
                                                     Build.binop(:-, node.b_x, node.a_x), Build.binop(:-, node.b_y, node.a_y)])
            end

            # Which picture a sprite collides as: the one of +poses+ its pose names, counted back from
            # the last for a pose below nought (Reference#collision_sprite).
            def picture_collided(poses, pose)
              pictures = drawing_table("collision_pictures", 2, poses.map { |name| picture_number(name) })
              Entry.new(pictures, 2, true, RuntimeValue.new("rt_pose_place", [value_node(pose), Build.int(poses.length)]))
            end

            # --- fades and tints ---

            # Reference#exec_fade, as a fade that walks the colours (IR::Fading walks every fade on a
            # console that cannot blend): toward black or white by the thirty-seconds the amount
            # comes to. A fade placed in the stack, or held to part of the screen, needs the blend.
            def emit_fade(node)
              if node.under || node.reaches
                raise LoweringError, "this program fades #{node.under ? 'under a layer (`under:`)' : "part of the screen (`#{node.reaches}:`)"}, " \
                                     "and a Game Boy Color can only fade the whole screen. To fix this, leave it out."
              end

              toward = node.toward == :white ? Runtime::Picture::TOWARD_WHITE : Runtime::Picture::TOWARD_BLACK
              runtime_call("rt_tint", [Build.int(toward), Build.int(0), walk_steps(node)])
            end

            # Reference#exec_tint: toward the colour, in thirty-seconds.
            def emit_tint(node)
              runtime_call("rt_tint", [Build.int(Runtime::Picture::TOWARD_COLOR),
                                           Build.int(Graphics::Color.resolve(node.color)), walk_steps(node)])
            end

            # FadeSteps.steps for a fade that walks the colours: the amount (0..100, or a fraction of
            # +fraction_bits+) as thirty-seconds — finely for a fraction, in whole sixteenths
            # otherwise — held to 0..32. The runtime holds it there too.
            def walk_steps(node)
              amount = node.amount
              if node.fraction_bits
                Build.binop(:/, Build.binop(:*, amount, Build.int(Runtime::Picture::STEPS)), Build.int(100 << node.fraction_bits))
              else
                sixteenths = Build.clamped(Build.binop(:/, Build.binop(:*, amount, Build.int(16)), Build.int(100)),
                                           Build.int(0), Build.int(16))
                Build.binop(:*, sixteenths, Build.int(2))
              end
            end

            # --- tables of the drawing's numbers ---

            # A table of numbers one drawing step reads, kept in the data, and its label: +bytes+ an
            # entry, each kept as its low bytes (an Entry reading it says whether with its sign).
            def drawing_table(what, bytes, entries)
              label = "#{what} #{@drawing_tables.length + 1}"
              @drawing_tables << [label, bytes, entries]
              label
            end
          end
        end
      end
    end
  end
end
