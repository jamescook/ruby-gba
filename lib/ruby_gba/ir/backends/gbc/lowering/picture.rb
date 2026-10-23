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
                                                 show_map: :emit_show_map, set_tile: :emit_set_tile,
                                                 background_colors: :emit_background_colors,
                                                 scroll_rows: :emit_scroll_rows, camera: :emit_camera,
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

            # Where a game that draws a background with other colours keeps the colours its pictures
            # are drawn in now, every palette's (Runtime::Picture#emit_background_colors), or nil for
            # a game that never does.
            attr_reader :drawn_palettes

            # Where a game with a map bigger than the grid keeps its copy of the grid and its list of
            # cells for the blank, [copy, list] (Runtime::BigMaps), or nil for a game with none.
            attr_reader :big_map_places

            private

            def prepare_picture
              @stacking = Stacking.picture(@program)
              @objects = by_name(@program.walk, :object)
              @color_lists = by_name(@program.walk, :color_list)
              @pictures = by_name(@program.walk, :data, :bitmap)
              @paint_colors = paint_colors
              @art = Art.new(paint_colors: @paint_colors&.first(Art::PLACES), lends: @lends_sprite_colors)
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
              painting = @program.walk.select do |node|
                PAINTING.key?(node.kind) || PUTTING_DOWN.key?(node.kind) || (node.kind == :background && painted_screen_for?(node))
              end
              return nil if painting.empty?

              [0, *colors_painted.map { |name| Graphics::Color.resolve(name) & 0x7FFF }].uniq
            end

            def colors_painted
              @program.walk.flat_map do |node|
                if PAINTING.key?(node.kind)
                  PAINTING.fetch(node.kind).filter_map { |field| node.public_send(field) }
                elsif PUTTING_DOWN.key?(node.kind)
                  Array(node.public_send(PUTTING_DOWN.fetch(node.kind))).flat_map { |name| picture_named(name).colors_drawn }
                elsif node.kind == :background && painted_screen_for?(node)
                  background_colors_painted(node)
                else
                  []
                end
              end
            end

            # The colours a background painted into the picture paints: its tiles' drawn pixels.
            def background_colors_painted(bg)
              bg.map.flatten.compact.reject(&:negative?).uniq.flat_map do |tile|
                image = Assets::Image.of(@pictures.fetch(bg.tiles.fetch(tile)))
                (image.width * image.height).times.reject { |at| image.tile_see_through_at?(at) }.map { |at| image.color_at(at) }
              end.uniq
            end

            # THE SETS GIVEN TO `colors_in_use` HAVE TO FIT IN THE EIGHT. The lists a set names are
            # shown together, so each takes turns in a list of its own (IR::Nodes::ColorList
            # .shared_name), and the sprites of a scene and the sprites every scene shows are drawn
            # through as many of those as its biggest set has lists. More than eight of them cannot
            # all borrow one of the console's eight at once, and some of the set's things would be
            # drawn in another list's colours, so it is refused, naming that set.
            def refuse_lists_in_use_past_eight!
              @objects.each_value.map(&:scene).uniq.each do |scene|
                shared = @objects.each_value.select { |obj| obj.scene.nil? || obj.scene == scene }
                                 .flat_map { |obj| Array(obj.recolors).grep(Symbol) }
                                 .select { |name| Nodes::ColorList.shared?(name) }.uniq
                next if shared.length <= Art::PALETTES

                whose = scene ? "The sprites of the scene #{scene.inspect}" : "The game's sprites"
                raise LoweringError, "#{whose} draw with the sets given to `colors_in_use`, and the biggest set " \
                                     "needs #{shared.length} lists of colours at once. A Game Boy Color holds " \
                                     "#{Art::PALETTES} lists for sprites. The biggest set is " \
                                     "#{@color_lists.fetch(shared.first).busiest_set}. To fix this, give that " \
                                     "set #{Art::PALETTES} lists or fewer."
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
              # Tiles its scenery and its sprites paint from a list show the list as it is now, changed
              # or not.
              arrival.painted_pictures.each { |run| emit_run_copy(run) }
              scenery = arrival.scenery.empty? ? @handover.always_up.scenery : arrival.scenery
              return runtime_call("rt_background_put_up", [Build.int(0)]) if scenery.empty?

              scenery.each { |bg| background_put_up(bg) }
              painted = arrival.scenery.empty? ? @handover.always_up.painted_tiles : arrival.painted_tiles
              painted.each { |run| emit_run_copy(run) }
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
            # any other is put up each time this runs. On a painted screen it is painted into the
            # picture here instead, as the interpreter stamps it (#paint_background).
            def emit_background(node)
              return paint_background(node) if painted_screen_for?(node)

              background_put_up(node) unless @handover.on_arrival?(node)
            end

            # Whether a background is declared where the screen is painted: its scene's screen, or the
            # game's for one in no scene.
            def painted_screen_for?(bg) = Modes::SCREEN_OF_MODE.fetch(Modes.resolve(@program).mode_of(bg.scene)) == :bitmap

            # Reference#stamp_background on a painted screen: each cell's tile painted where the cell
            # is, its see-through pixels leaving what is there, and nothing past the screen's edge.
            def paint_background(bg)
              width = Console::GBCHardware::SCREEN_WIDTH
              height = Console::GBCHardware::SCREEN_HEIGHT
              bg.map.each_with_index do |row, r|
                Array(row).each_with_index do |tile, c|
                  x = c * bg.tile_w
                  y = r * bg.tile_h
                  next if tile.nil? || tile.negative? || x >= width || y >= height

                  image = Assets::Image.of(@pictures.fetch(bg.tiles.fetch(tile)))
                  points = Hash.new { |by_color, color| by_color[color] = [] }
                  (image.width * image.height).times do |at|
                    points[image.color_at(at)] << at.divmod(image.width).reverse unless image.tile_see_through_at?(at)
                  end
                  points.each { |color, drawn| paint_bits(Build.int(x), Build.int(y), Build.int(@art.paint_place(color)), drawn) }
                end
              end
            end

            # A background goes up as its grid, or as a map bigger than the grid (Runtime::BigMaps).
            def background_put_up(bg)
              return big_put_up(bg, 0, "rt_big_put_up") if big?(bg)

              runtime_call("rt_background_put_up", [Build.int(grid_of(bg))])
            end

            # Whether any of a background's maps is bigger than the Color's grid of 32×32 cells.
            def big?(bg)
              bg.every_map.any? do |map|
                cols, rows = TileMap.size_of(map)
                cols > Art::GRID_CELLS || rows > Art::GRID_CELLS
              end
            end

            # A background's map number +which+ kept whole, for a background one of whose maps is
            # bigger than the grid (GBC::Art#big_map): every map of it is kept that way, so each stops
            # at its own edge.
            def big_map_of(bg, which = 0)
              @big_maps ||= {}
              @big_maps[[bg, which]] ||= begin
                refuse_background!(bg)
                @art.big_map(bg.every_map.fetch(which).map do |row|
                  Array(row).map { |tile| tile.nil? || tile.negative? ? nil : background_tile_named(bg.tiles.fetch(tile)) }
                end)
              end
            end

            def emit_scroll_background(node)
              declared_background!(node)
              runtime_call("rt_background_scroll", [node.x, node.y])
            end

            def declared_background!(node)
              @backgrounds.fetch(node.name) { raise LoweringError, "#{node.kind} of undeclared background #{node.name.inspect}" }
            end

            # Reference#exec_show_map: the background handed map number +which+ whole, as it was
            # declared — its grid put up — and a number naming no map leaves it as it is. A number
            # written in the program is looked up here; one worked out as the game runs, in a table
            # of the maps' grids.
            #
            # A background bigger than the grid hands over its map kept whole (#big_map_of) and keeps
            # its view where it is (Runtime::BigMaps's rt_big_show).
            def emit_show_map(node)
              bg = declared_background!(node)
              return emit_show_changed_big_map(bg, node) if big?(bg) && changed_big?(bg)

              routine = big?(bg) ? "rt_big_show" : "rt_background_put_up"
              grids = bg.every_map.each_index.map { |which| big?(bg) ? big_map_of(bg, which) : grid_of(bg, which) }
              known = folded(node.which)
              return (runtime_call(routine, [Build.int(grids.fetch(known))]) if known.between?(0, grids.length - 1)) if known

              table = drawing_table("map_grids", 1, grids)
              past = fresh("past_the_map")
              value(node.which)
              @asm.load(:a, :b)
              @asm.or_a(:c)
              @asm.or_a(:d)
              @asm.jump(:nz, past) # below nought, or far past the maps
              @asm.load(:a, :e)
              @asm.cp_a(grids.length)
              @asm.jump(:nc, past)
              @asm.load(:hl, table)
              @asm.load(:d, 0)
              @asm.add_hl(:de)
              @asm.load(:a, [:hl])
              @asm.load(:e, :a)
              2.times { @asm.push(:de) } # the grid's number, as a four-byte argument
              @asm.call(routine)
              @asm.add_sp(4)
              @asm.label(past)
            end

            # ...a big background the game changes: the map named copied in as declared and handed
            # over, by number, and a number naming none leaves it as it is.
            def emit_show_changed_big_map(bg, node)
              which = keep_local(:map)
              value(node.which)
              store(which)
              bg.every_map.each_index do |at|
                other = fresh("not_map")
                jump_unless(Build.binop(:==, Build.var_ref(which), Build.int(at)), other)
                big_put_up(bg, at, "rt_big_show")
                @asm.label(other)
              end
            end

            # Reference#exec_camera: the view moved over the painted picture. The picture is the
            # screen's size, the console's grid of tiles holding it with nothing past its edge, so
            # the grid is scrolled (Runtime::Picture's rt_background_scroll), and black shows past
            # the picture, as the interpreter shows it.
            def emit_camera(node) = runtime_call("rt_background_scroll", [node.x, node.y])

            # A BACKGROUND BENT ROW BY ROW (Reference#exec_scroll_rows): a standing declaration, so
            # reaching it switches the bending on (Runtime::Picture's rt_bends_on) and the rows are
            # worked out at every frame boundary (#emit_bends).
            def emit_scroll_rows(node)
              declared_background!(node)
              @asm.call("rt_bends_on")
            end

            # Reference#work_out_bends, where the pass's wait ends: every row of the screen, its
            # number in the bend's variable, the bend's own steps, and how far along it sits kept for
            # the frame after (Runtime::Picture::BENDS_NEXT); then the variable left past the last row.
            # +painting+ is the interpreter painting a game that never waits, row by row
            # (Reference#bend_offset_at), which leaves the variable at the last row.
            def emit_bends(painting: false)
              bend = bend_of or return

              height = Console::GBCHardware::SCREEN_HEIGHT
              row = fresh("bend_row")
              statement(Build.set(bend.row, 0))
              @asm.label(row)
              bend.children.each { |child| statement(child) }
              emit_bend_row(BendRow.new(row: bend.row, offset: bend.offset))
              statement(Build.add(bend.row, 1))
              value(bend.row) # rows from nought to the last, so the low byte is all there is to ask
              @asm.load(:a, :e)
              @asm.cp_a(height)
              @asm.jump(:c, row)
              statement(Build.set(bend.row, height - 1)) if painting
            end

            # The one bend the game declares, or nil. The Color shows one background, so it bends one.
            def bend_of
              return @bend if defined?(@bend)

              bends = @program.walk.select { |node| node.kind == :scroll_rows }.uniq(&:name)
              if bends.length > 1
                raise LoweringError, "this game bends #{bends.length} backgrounds row by row, which #{build_name} cannot make yet."
              end

              @bend = bends.first
            end

            # One row's bend, kept: its row's place in BENDS_NEXT, the low byte of how far along.
            BendRow = Data.define(:row, :offset)

            def emit_bend_row(node)
              value(node.row)
              @asm.load(:a, :e)
              @asm.push(:af)
              value(node.offset)
              @asm.pop(:af)
              @asm.load(:l, :a)
              @asm.load(:h, 0)
              @asm.load(:bc, @memory[Runtime::Picture::BENDS_NEXT])
              @asm.add_hl(:bc)
              @asm.load([:hl], :e)
            end

            # Reference#exec_set_tile: one cell of the background given another of its tiles — or
            # none, the backdrop — written into the console's grid (Runtime::Picture's
            # rt_background_cell), and a cell off the map changing nothing. Its maps must be one size,
            # so the edge is the same whichever is showing.
            #
            # A big map's cell is changed where the map is kept while it is up (Runtime::BigMaps's
            # rt_big_set).
            def emit_set_tile(node)
              bg = declared_background!(node)
              tile = node.tile
              number, palette = tile.nil? || tile.negative? ? [0, 0] : background_tile_named(bg.tiles.fetch(tile))
              colours = palette | (number >= 256 ? Console::GBCHardware::ATTR_TILE_BANK : 0)
              cell = Build.int((number & 0xFF) | (colours << 8))
              return runtime_call("rt_big_set", [node.col, node.row, cell]) if big?(bg)

              refuse_background!(bg, as_grid: true)
              cols, rows = map_size_of(bg)
              runtime_call("rt_background_cell", [node.col, node.row, Build.int(cols | (rows << 8)), cell])
            end

            # Whether the game changes a big background's cells as it runs, so it is kept in work
            # memory while it is up.
            def changed_big?(bg) = @reachable.any? { |node| node.kind == :set_tile && node.name == bg.name }

            # A big background put up — or handed map number +which+ (+routine+ rt_big_show) — from its
            # map kept whole; one the game changes copied into work memory first.
            def big_put_up(bg, which, routine)
              return runtime_call(routine, [Build.int(big_map_of(bg, which))]) unless changed_big?(bg)

              runtime_call("rt_big_copy_in", [Build.int(big_map_of(bg, which)), Build.int(changed_big_place(bg))])
              cols, rows = TileMap.size_of(bg.every_map.fetch(which))
              runtime_call(routine, [Build.int(@art.big_map_in_memory(cols, rows, changed_big_place(bg)))])
            end

            # Where a big background the game changes is kept: room for the biggest of its maps.
            def changed_big_place(bg)
              @changed_big_places ||= {}
              @changed_big_places[bg] ||= begin
                bytes = bg.every_map.map { |map| TileMap.size_of(map).reduce(:*) * 2 }.max
                @memory.reserve("the changed map of #{bg.name.inspect}", bytes)
              end
            end

            # Room for every palette's colours as drawn now, in a game that draws a background in
            # other colours anywhere a run can reach, or whose sprites' lists borrow the eight.
            def keep_drawn_palettes
              return unless @art.lends? || @reachable.any? { |node| node.kind == :background_colors }

              @drawn_palettes = @memory.reserve("the colours drawn now", 128)
            end

            # The copy of the grid a map bigger than it is worked out into — at an address that is a
            # multiple of 16, which the console's copying reads from — and the list for the blank.
            def keep_big_map_places
              return unless @backgrounds.each_value.any? { |bg| big?(bg) }

              copy = @memory.reserve("the copy of a big map's grid", Runtime::BigMaps::BUFFER_BYTES + 15)
              @big_map_places = [(copy + 15) & ~15, @memory.reserve("the cells for the blank", Runtime::BigMaps::STAGED_BYTES)]
            end

            # Reference#exec_background_colors: the background's tiles drawn from another of its lists
            # of colours, by a number the game works out — or its own, for a number naming none. The
            # Color draws a tile in one of its palettes, so the background's palettes are written
            # with the colours its tiles show now (#background_colors_table), into the colours the
            # pictures are drawn in now, and the fade in force moves them from there.
            def emit_background_colors(node)
              bg = declared_background!(node)
              steps = Array(bg.recolors)
              own = drawing_table("background_colors", 1, background_colors_table(bg, nil))
              tables = steps.each_index.map { |step| drawing_table("background_colors", 1, background_colors_table(bg, step)) }
              chosen = fresh("background_colors_chosen")
              value(node.which)
              @asm.load(:hl, own)
              @asm.load(:a, :b)
              @asm.or_a(:c)
              @asm.or_a(:d)
              @asm.jump(:nz, chosen) # below nought, or far past the lists
              @asm.load(:a, :e)
              tables.each_with_index do |table, step|
                other = fresh("not_colors_#{step}")
                @asm.cp_a(step)
                @asm.jump(:nz, other)
                @asm.load(:hl, table)
                @asm.jump(chosen)
                @asm.label(other)
              end
              @asm.label(chosen)
              @asm.call("rt_background_colors")
            end

            # The palettes a background's tiles are drawn in with its lists of colours number +step+
            # (nil for its own), as rt_background_colors reads them: how many, then each palette's
            # number and its four colours. Each tile's list swaps its colours by place
            # (Assets::Recolor), and the Color keeps one palette for each set of colours, so two
            # tiles that share one and are drawn differently are not made yet.
            def background_colors_table(bg, step)
              swaps = step && bg.palettes.zip(bg.recolors.fetch(step)).to_h
              palettes = {}
              bg.tiles.compact.uniq.each do |name|
                _, palette = background_tile_named(name)
                colors = tile_colors_with(name, swaps)
                if palettes.key?(palette) && palettes[palette] != colors
                  raise LoweringError, "the background #{bg.name.inspect} draws two of its tiles from one list of colours " \
                                       "of the Color's and with other colours apart, which #{build_name} cannot make yet."
                end

                palettes[palette] = colors
              end
              [palettes.size, *palettes.flat_map { |palette, colors| [palette, *colors.flat_map { |c| [c & 0xFF, c >> 8] }] }]
            end

            # The four colours tile +name+'s palette holds when drawn with +swaps+ (the list each of
            # the layer's own lists is drawn with, or nil for its own): the backdrop, then the colour
            # each of its own shows.
            def tile_colors_with(name, swaps)
              run = run_painting(name)
              if run
                swapped = swaps && swaps[run.colors]
                own = run.colors.drop(1).first(Art::OWN_COLORS)
                shown = own.each_with_index.map { |color, i| swapped && swapped[i + 1] || color }
                return padded_colors(shown)
              end

              image = Assets::Image.of(@pictures.fetch(name))
              drawn = @art.tile_colors(image)
              swapped = swaps && swaps[image.colors]
              return padded_colors(drawn) unless swapped

              recolor = Assets::Recolor.of(image, swapped)
              shown = drawn.map do |color|
                at = (0...64).select { |i| !image.tile_see_through_at?(i) && (image.color_at(i) & 0x7FFF) == color }
                ways = at.map { |i| recolor.color_for(i, image.color_at(i)) & 0x7FFF }.uniq
                unless ways.one?
                  raise LoweringError, "the tile #{name.inspect} shows one colour in two others when drawn with another list " \
                                       "of colours, which #{build_name} cannot make yet."
                end

                ways.first
              end
              padded_colors(shown)
            end

            def padded_colors(colors) = [Art::BACKDROP, *colors.map { |color| color & 0x7FFF }].fill(Art::BACKDROP, colors.length + 1...Art::PLACES)

            def map_size_of(bg)
              sizes = bg.every_map.map { |map| TileMap.size_of(map) }.uniq
              return sizes.first if sizes.one?

              raise LoweringError, "the background #{bg.name.inspect} has maps of different sizes and a cell changed with " \
                                   "`set_tile`, which #{build_name} cannot make yet."
            end

            # A background's cells as the Color's grid of 32×32 holds them, for its map number
            # +which+: each cell's tile and palette, and nothing — the backdrop — where the map has
            # no tile or does not reach.
            def grid_of(bg, which = 0)
              @grids[[bg, which]] ||= begin
                refuse_background!(bg, as_grid: true)
                map = bg.every_map.fetch(which)
                cells = Array.new(Art::GRID_CELLS) do |row|
                  Array.new(Art::GRID_CELLS) do |col|
                    tile = map[row] && map[row][col]
                    next nil if tile.nil? || tile.negative?

                    background_tile_named(bg.tiles.fetch(tile))
                  end
                end
                @art.grid(cells)
              end
            end

            # What a background has that this build does not make yet: tiles other than 8×8, and — as a
            # grid, for a step that changes the grid (`set_tile`, `show_map`) — a map bigger than it.
            def refuse_background!(bg, as_grid: false)
              sizes = bg.every_map.map { |map| TileMap.size_of(map) }
              cols, rows = sizes.max
              what = if bg.tile_w != 8 || bg.tile_h != 8 then "tiles of #{bg.tile_w}×#{bg.tile_h}"
                     elsif as_grid && big?(bg) then "a map of #{cols}×#{rows} cells changed as the game runs"
                     end
              return unless what

              raise LoweringError, "the background #{bg.name.inspect} has #{what}, which #{build_name} cannot make yet."
            end

            # --- sprites ---

            # Reference#exec_present_objects: every sprite the frame draws, written into the console's
            # sprite table front-most first — the order the Color draws them in, where the
            # interpreter paints the back-most first.
            #
            # A run the game puts in order as it runs (`draw_in_order`, Reference#names_in_draw_order)
            # stands at its place among the rest, and its sprites are placed in the order its list
            # holds them, read from the front: each sprite's placing is a routine of the frame's own,
            # called by the number the list holds.
            def emit_present_objects(node)
              object = ->(name) { @objects.fetch(name) { raise LoweringError, "present of undeclared object #{name.inspect}" } }
              changing = node.names.map(&object).select { |obj| Stacking.levels_of(@stacking.depths, obj).uniq.length > 1 }
              return emit_layer_changing_sprites(node, node.names.map(&object)) unless changing.empty?

              items = present_items(node).map { |item| item.is_a?(Build::DrawOrder) ? item : object.call(item) }
              front_first = items.each_with_index.sort_by { |item, at| [item_level(item, object), at] }.map(&:first).reverse
              placings = {}
              @asm.call("rt_sprites_begin")
              front_first.each do |item|
                next sprite_placement(item) unless item.is_a?(Build::DrawOrder)

                item.objects.each { |name| placings[name] ||= fresh("place_sprite") }
                emit_ordered_run(item, placings)
              end
              @asm.call("rt_sprites_end")
              return if placings.empty?

              past = fresh("past_the_placings")
              @asm.jump(past)
              placings.each do |name, label|
                @asm.label(label)
                sprite_placement(object.call(name))
                @asm.ret
              end
              @asm.label(past)
            end

            # A FRAME WITH SPRITES THAT CHANGE LAYER as the game runs (`put_in_layer`,
            # Reference#object_level): every depth any of them can be at, front-most first, and at
            # each, every sprite that can be there, placed when the layer it is in now is that one —
            # so a sprite is placed once, among the sprites of its layer now, behind the background
            # or not as that layer is.
            def emit_layer_changing_sprites(node, objects)
              unless Array(node.orders).empty?
                raise LoweringError, "this program puts sprites in order as the game runs (`draw_in_order`) and moves a " \
                                     "sprite to another layer, which #{build_name} cannot make yet."
              end

              @asm.call("rt_sprites_begin")
              objects.flat_map { |obj| Stacking.levels_of(@stacking.depths, obj) }.uniq.sort.reverse_each do |level|
                objects.reverse_each do |obj|
                  there = at_level(obj, level)
                  next if there.nil?
                  next sprite_placement(obj, level) if there == true

                  elsewhere = fresh("sprite_elsewhere")
                  jump_unless(there, elsewhere)
                  sprite_placement(obj, level)
                  @asm.label(elsewhere)
                end
              end
              @asm.call("rt_sprites_end")
            end

            # When a sprite is at depth +level+: always (true), never (nil), or a test of the number
            # that picks its layer — one naming a layer at that depth, or, for its own layer's depth,
            # one naming none of them.
            def at_level(obj, level)
              own = @stacking.depths[obj.name] == level
              layers = Array(obj.layers)
              return (own ? true : nil) if layers.empty?

              pick = Build.var_ref(obj.layer_pick)
              tests = layers.each_index.select { |i| @stacking.depths[Stacking.choice_name(obj, layers[i])] == level }
                            .map { |i| Build.binop(:==, pick, Build.int(i)) }
              if own
                tests << Build.binop(:or, Build.binop(:<, pick, Build.int(0)), Build.binop(:>=, pick, Build.int(layers.length)))
              end
              tests.reduce { |either, test| Build.binop(:or, either, test) }
            end

            # The frame's sprites back to front, each a name — or, for a run the game orders, the run.
            def present_items(node)
              Array(node.orders).reduce(node.names.dup) do |names, run|
                first = names.index(run.objects.first)
                names[0...first] + [run] + names[(first + run.objects.length)..]
              end
            end

            # How deep an item sits: a sprite's level, and a run's, which its sprites share.
            def item_level(item, object)
              return sprite_level(item) unless item.is_a?(Build::DrawOrder)

              levels = item.objects.map { |name| sprite_level(object.call(name)) }.uniq
              return levels.first if levels.one?

              raise LoweringError, "sprites put in order as the game runs (`draw_in_order`) sit at different depths, which " \
                                   "#{build_name} cannot make yet."
            end

            # A run's sprites front-most first: the list's last entry first, each the number of the
            # sprite of the run to place.
            def emit_ordered_run(run, placings)
              (run.objects.length - 1).downto(0) do |k|
                past = fresh("past_the_ordered")
                value(Build.list_get(run.order, Build.int(k)))
                @asm.load(:a, :b)
                @asm.or_a(:c)
                @asm.or_a(:d)
                @asm.jump(:nz, past)
                @asm.load(:a, :e)
                run.objects.each_with_index do |name, at|
                  other = fresh("not_sprite")
                  @asm.cp_a(at)
                  @asm.jump(:nz, other)
                  @asm.call(placings.fetch(name))
                  @asm.jump(past)
                  @asm.label(other)
                end
                @asm.label(past)
              end
            end

            # How deep a sprite sits: the one level it is declared at, for a sprite that never changes
            # layer (one that does is placed by #emit_layer_changing_sprites).
            def sprite_level(obj)
              levels = Stacking.levels_of(@stacking.depths, obj).uniq
              return levels.first if levels.one?

              raise LoweringError, "the sprite #{obj.declared.inspect} changes layer as the game runs, and #{build_name} " \
                                   "places it only among the sprites of a frame."
            end

            # Reference#objects_on_screen: a sprite is drawn when it is switched on and its pose names
            # one of its pictures. It is drawn behind the background when the background's layer is
            # in front of its own; the background's see-through pixels still show it.
            #
            # +level+ is the depth it is placed at: its own, or for a sprite that changes layer as
            # the game runs, the one this placing is for (#emit_layer_changing_sprites).
            def sprite_placement(obj, level = sprite_level(obj))
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
              unless fixed_sprite(obj, said, level)
                out_of_range = said ? nil : fresh("pose_out_of_range")
                if out_of_range
                  value(pose)
                  @asm.load(:hl, constant_label(obj.poses.length))
                  @asm.call("rt_cmpu32")
                  @asm.cp_a(1)
                  @asm.jump(:nz, out_of_range)
                end
                if said.nil? || said.between?(0, obj.poses.length - 1)
                  picture, attributes, lent = picture_and_attributes_drawn(obj, pose, level)
                  runtime_call("rt_sprite", [*lent, picture, obj.x, obj.y, attributes])
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
            def fixed_sprite(obj, pose, level)
              x = folded(obj.x)
              y = folded(obj.y)
              # In a game that lends its sprites' lists, which of the eight a sprite is drawn in is
              # known only as it runs, so even a letter of text takes the slower way, through
              # rt_lend_colors, every pass.
              return false if @art.lends?
              return false unless pose && x && y && Array(obj.recolors).empty? && pose.between?(0, obj.poses.length - 1)

              name = obj.poses.fetch(pose)
              attributes = said_attributes(obj, name, palette_of(name, nil), level)
              record = [picture_number(name), x, y, attributes & 0xFFFF, attributes >> 16]
              runtime_call("rt_sprite_fixed", [Address.new(drawing_table("fixed_sprite", 2, record))])
              true
            end

            # Whether a sprite at depth +level+ is behind the scenery: a background sits in front of it.
            def behind_scenery?(level) = @stacking.scenery.any? { |bg| @stacking.depths[bg.name] > level }

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
            # ones it was declared with first (Reference#colors_held_by). In a game whose sprites' lists
            # borrow the console's eight (Art#lends?), the attributes name none of the eight, and a
            # third entry is the game's number for the list the row is drawn in, which rt_sprite
            # borrows one of the eight for as the sprite's first piece goes in; nil otherwise.
            def picture_and_attributes_drawn(obj, pose, level)
              lists = Array(obj.recolors)
              sets = [[nil], *lists.map { |colors| colors.is_a?(Symbol) ? sets_held_by(colors) : [colors] }]
              rows = sets.flatten(1).flat_map do |colors|
                obj.poses.map do |name|
                  palette = palette_of(name, colors)
                  PoseRow.new(picture: picture_number(name), palette: palette,
                              attributes: said_attributes(obj, name, @art.lends? ? 0 : palette, level))
                end
              end
              pictures = drawing_table("pose_pictures", 2, rows.map(&:picture))
              palettes = drawing_table("pose_attributes", 4, rows.map(&:attributes))
              at = lists.empty? ? pose : Sum.new(:+, Sum.new(:*, row_drawn_with(obj, lists, sets), Build.int(obj.poses.length)), pose)
              lent = @art.lends? ? Entry.new(drawing_table("pose_lent_palettes", 1, rows.map(&:palette)), 1, false, at) : nil
              [Entry.new(pictures, 2, true, at), Entry.new(palettes, 4, true, at), lent]
            end

            # One row of a sprite's tables: the picture a pose is drawn from in one list of colours,
            # the palette that list makes of it, and the attributes rt_sprite is handed for it.
            PoseRow = Data.define(:picture, :palette, :attributes)

            # Which row of its pictures a sprite is on: the first row of the list it is drawn with now,
            # and for a list that holds other colours, as many rows further as the set it holds.
            def row_drawn_with(obj, lists, sets)
              choice = RuntimeValue.new("rt_place_of_choice", [value_node(obj.recolor), Build.int(lists.length)])
              return choice if lists.none?(Symbol)

              first_rows = sets.each_with_object([0]) { |held, starts| starts << (starts.last + held.length) }
              # For each list, as rt_row_drawn_with reads it: its first row, where the number saying
              # which set it holds is kept (nought for a list that holds one set only), and how many
              # sets it holds besides the one it was declared with.
              entries = sets.each_index.flat_map do |at|
                name = at.zero? ? nil : lists[at - 1]
                held = name.is_a?(Symbol) ? place_of(@held_colors.fetch(name)) : 0
                others = name.is_a?(Symbol) ? sets_held_by(name).length - 1 : 0
                [first_rows[at] | (held << 16), others]
              end
              RuntimeValue.new("rt_row_drawn_with", [choice, Address.new(drawing_table("rows_drawn_with", 4, entries))])
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

            def picture_number(name)
              run = picture_painting(name)
              return @art.painted_sprite_picture(name, run.width, run.height).number if run

              @art.sprite_picture(name, picture_named(name)).number
            end

            # A sprite's attributes as rt_sprite takes them: in the low byte, its palette and
            # whether it is behind the background, as the sprite table keeps them; above that, the
            # numbers a run says it by — whose it is, one up so nought is nobody's, and which picture
            # it is showing.
            def said_attributes(obj, picture, palette, level)
              behind = behind_scenery?(level) ? Console::GBCHardware::OBJ_BEHIND : 0
              whose = @drawn_sprites.name_number(obj.declared) + 1
              palette | behind | (whose << 8) | (@drawn_sprites.picture_number(picture) << 16)
            end

            # The palette picture +name+ is drawn in with the list +colors+ (nil for its own): the
            # colour each of its places shows, as the interpreter draws it.
            def palette_of(name, colors)
              run = picture_painting(name)
              return @art.painted_sprite_palette(name, painted_colors(run, colors)) if run

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
