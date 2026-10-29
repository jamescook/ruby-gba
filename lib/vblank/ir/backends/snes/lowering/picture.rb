# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        class Lowering
          # THE PICTURE, lowered for a Super Nintendo: the statements that draw, as calls into
          # Runtime::Picture, and the game's pictures made into tiles, palettes and maps (SNES::Art)
          # while the program is built.
          #
          # A TILED SCREEN. Each background the game declares is given one of the console's two
          # layers of sixteen-colour tiles, the one declared last in front (BG1), as the interpreter
          # paints the one declared last over the rest. Each map it can show is made into a grid of
          # 32 or 64 cells each way (IR::TileMap), kept whole in the cartridge and copied onto its
          # layer when it is put up. Each sprite is made of the console's 8×8 sprite pieces, placed
          # in the sprite table every pass the game places its sprites.
          module Picture
            STATEMENTS = Ractor.make_shareable({
                                                 screen: :emit_screen, background: :emit_background,
                                                 scroll_background: :emit_scroll_background,
                                                 set_tile: :emit_set_tile, show_map: :emit_show_map,
                                                 present_objects: :emit_present_objects,
                                                 hide_sprites: :emit_hide_sprites, fade: :emit_fade, tint: :emit_tint,
                                                 place_bar: :emit_place_bar, scroll_rows: :emit_scroll_rows,
                                                 copy_tiles: :emit_copy_tiles, copy_owed_tiles: :emit_copy_owed_tiles
                                               })

            # Whether +program+ has a status bar, which the runtime then carries what places
            # (Runtime::Picture's rt_bar_place).
            def self.status_bar?(program) = program.walk.any? { |node| node.kind == :background && node.bar? }

            # Whether +program+ bends a background row by row, which the runtime then keeps the rows
            # and line tables of (Runtime::Picture's rt_bends_prepare).
            def self.bends?(program) = program.walk.any? { |node| node.kind == :scroll_rows }

            # The runs of tiles +program+ paints from lists (Builder::TileRuns), each once, in the order
            # they were declared: the order the runtime numbers them in.
            def self.tile_runs(program) = program.walk.select { |node| node.kind == :tile_run }.uniq(&:name)

            # The bytes each run's tiles take in the console's form, which the runtime stages a copy in.
            def self.tile_run_bytes(program)
              tile_runs(program).map { |run| (run.picture ? (run.width / 8) * (run.height / 8) : run.tiles.length) * 32 }
            end

            # The SNES::Art the game's pictures were made into.
            attr_reader :art

            def prepare_picture
              @art = Art.new
              @pictures = by_kind(:bitmap)
              @objects = by_kind(:object)
              @backgrounds = by_kind(:background)
              @sprite_names = SpriteNames.new(@program)
              @grids = {}
              @pose_tables = {}
              @tile_runs = Picture.tile_runs(@program)
              @run_cells = {} # a run's tile's image name -> [tile, palette]
              @run_places = [] # each run's first tile's word in video RAM
            end

            # Each piece of the picture this lowering does not make yet, refused by name: the
            # build makes a tiled screen of 8×8 tiles, at most two backgrounds, and plain sprites,
            # or a painted screen (Lowering::Paint) with nothing drawn from tiles over it.
            def refuse_unmade_picture!
              screens = @program.walk.select { |node| node.kind == :screen }.map(&:mode).uniq
              others = screens - %i[tiled bitmap]
              refuse_unmade!("a `screen :#{others.first}`") unless others.empty?
              refuse_unmade!("both a painted (bitmap) screen and a tiled one") if screens.include?(:tiled) && painted?
              if painted?
                refuse_unmade!("a background on a painted (bitmap) screen") unless @backgrounds.empty?
                refuse_unmade!("a hardware sprite on a painted (bitmap) screen") unless @objects.empty?
              end
              @program.walk.select { |node| node.kind == :background }.each do |bg|
                refuse_unmade!("background tiles of #{bg.tile_w}×#{bg.tile_h}") unless bg.tile_w == 8 && bg.tile_h == 8
                refuse_unmade!("a background drawn with other colours") unless Array(bg.recolors).empty? && Array(bg.palettes).empty?
                refuse_unmade!("a background drawn from several sets of tiles") if bg.several_sets?
                refuse_unmade!("a background whose maps are of different sizes or too big to hold") if bg.streams?
              end
              @objects.each_value do |obj|
                refuse_unmade!("a sprite put in another layer as the game runs (`put_in_layer`)") if obj.layer_pick
                refuse_unmade!("a sprite drawn with other colours") unless obj.recolors.empty?
              end
              ordered = @reachable.any? { |node| node.kind == :present_objects && !Array(node.orders).empty? }
              refuse_unmade!("sprites drawn in an order the game works out (`draw_in_order`)") if ordered
            end

            # Every picture a sprite can show, made into sprite pieces in the order SpriteNames numbers
            # them, a canvas's picture among them (#make_run_art), so the number a picture is made
            # with is the one a reader of the drawn sprites turns back into its name.
            #
            # The pictures of a see-through layer's sprites are drawn from the console's last four
            # sprite palettes, and every other picture from the first four (Art#split_sprite_palettes!),
            # so a picture both kinds of sprite show would need to be made twice, which is not made yet.
            def make_sprite_art
              @art.split_sprite_palettes! unless see_through_sprites.empty?
              @sprite_pictures = @objects.values.flat_map(&:poses).uniq.sort_by { |name| @sprite_names.picture_number(name) }
              mixed = see_through_sprites.flat_map { |name| @objects.fetch(name).poses }.uniq
              solid = (@objects.values.reject { |obj| see_through_sprites.include?(obj.name) }.flat_map(&:poses) +
                       @tile_runs.filter_map(&:picture)).uniq
              refuse_unmade!("a picture shown both by a see-through sprite and by another") if mixed.intersect?(solid)

              painted = @tile_runs.filter_map(&:picture)
              @sprite_pictures.each do |name|
                if painted.include?(name)
                  make_run_art(@tile_runs.index { |run| run.picture == name })
                else
                  @art.sprite_picture(name, Assets::Image.of(picture_named(name)), mixed: mixed.include?(name))
                end
              end
              @tile_runs.each_index { |number| make_run_art(number) unless @run_places[number] }
            end

            # Run +number+'s tiles (SNES::Art#background_run, #sprite_run_picture), and where in video
            # RAM the first is: tiles are 16 words each (Runtime::Picture's layout).
            def make_run_art(number)
              run = @tile_runs.fetch(number)
              if run.picture
                picture = @art.sprite_run_picture(run.picture, run.width, run.height, run.colors)
                @run_places[number] = Runtime::Picture::SPRITE_TILES + (picture.pieces.first.tile * Art::TILE_BYTES / 2)
              else
                first, palette = @art.background_run(run.colors, run.tiles.length)
                run.tiles.each_with_index { |image, k| @run_cells[image] = [first + k, palette] }
                @run_places[number] = Runtime::Picture::BG_TILES + (first * Art::TILE_BYTES / 2)
              end
            end

            def refuse_unmade!(what)
              raise NotMadeYet.new("This game has #{what}. The Super Nintendo build does not make that yet. To fix " \
                                   "this, build the game for the Game Boy Advance alone for now (`consoles: %i[gba]`).",
                                   part: "the picture")
            end

            # The two layers a background can be given.
            BACKGROUND_LAYERS = 2

            # The art, and each sprite's table of pictures, as sections for the Linker.
            def art_sections
              data = W65816.new("art", holds: ART)
              data.label("art background tiles bytes")
              data.data_words(@art.background_tile_data.bytesize)
              data.label("art sprite tiles bytes")
              data.data_words(@art.sprite_tile_data.bytesize)
              unless painted? # Lowering::Paint's colours, then
                data.label("art colors")
                data.data_bytes(@art.cgram.bytes)
              end
              data.label("art sprite pictures")
              data.data_longs(@art.sprite_pictures.each_value.map { |picture| pieces_label(picture.number) })
              @art.sprite_pictures.each_value do |picture|
                data.label(pieces_label(picture.number))
                data.data_words(picture.pieces.length)
                picture.pieces.each do |piece|
                  data.data_words(piece.dx, piece.dy,
                                  piece.tile | (piece.palette << 9) | SPRITE_IN_FRONT)
                end
              end
              data.label("art grids")
              @art.grids.each do |grid|
                data.data_longs(grid_label(grid.number))
                data.data_bytes(0)
                data.data_words(grid.bytes.bytesize, grid.size_bits, grid.columns)
              end
              data.label("art tile runs")
              @tile_runs.each_with_index do |run, number|
                list = @lists.fetch(run.list).first
                staging = @memory[Runtime::Picture.tile_run_staging(number)]
                data.data_words(list & 0xFFFF, list >> 16, staging & 0xFFFF, staging >> 16, @run_places[number],
                                Picture.tile_run_bytes(@program)[number] / 32, Picture.tile_run_bytes(@program)[number], 0)
              end
              @pose_tables.each do |obj, label|
                data.label(label)
                # Each picture by the number Art made it with ("art sprite pictures"' order).
                data.data_words(obj.poses.length, *obj.poses.map { |pose| @art.sprite_pictures.fetch(pose).number })
              end
              [data.section, *bytes_section("art background tiles", @art.background_tile_data),
               *bytes_section("art sprite tiles", @art.sprite_tile_data),
               *@art.grids.map { |grid| bytes_section(grid_label(grid.number), grid.bytes) },
               *(painted? ? paint_sections : []), *collision_sections]
            end

            ART = W65816::Holding.new(what: "the game's pictures", fix: "use fewer different pictures and maps")

            # A sprite row's attributes, the high byte of its tile word: in front of every background
            # (priority 3). A sprite behind a background has the difference from its own priority
            # (#sprite_depths) taken off as it is placed.
            SPRITE_IN_FRONT = 0x3000

            # The priority bits of a sprite row.
            SPRITE_PRIORITY_SHIFT = 12

            # SPRITES IN LAYERS, among the backgrounds (#assign_background_layers has put each
            # background on its layer): each sprite's priority, by its name, from the backgrounds
            # in front of it on the screens it is on (IR::Stacking's depths, per screenful) — 3 for
            # none, 2 for BG1 alone, which is then drawn high (Art::CELL_IN_FRONT), 1 for BG2. Empty when
            # every sprite is in front of every background, as in a game that names no layers.
            def sprite_depths
              @sprite_depths ||= begin
                found = {}
                Stacking.screenfuls(@program).each do |screenful|
                  scenery = screenful.scenery.reject(&:bar?)
                  screenful.objects.each do |obj|
                    level = screenful.depths[obj.name]
                    front = scenery.select { |bg| screenful.depths.of_scenery(bg) > level }.map { |bg| layer_of(bg) }
                    priority = if front.include?(1) then 1
                               elsif front.include?(0) then 2
                               else 3
                               end
                    if found.fetch(obj.name, priority) != priority
                      refuse_unmade!("a sprite behind a background on one screen and in front of it on another")
                    end
                    found[obj.name] = priority
                  end
                end
                found.reject! { |_, priority| priority == 3 }
                refuse_unmade!("a status bar beside a sprite behind a background") if !found.empty? && @backgrounds.each_value.any?(&:bar?)
                found
              end
            end

            # Whether +bg+'s cells are drawn high, in front of the sprites of priority 2.
            def cells_in_front?(bg) = layer_of(bg).zero? && sprite_depths.value?(2)

            def pieces_label(number) = "art pieces #{number}"
            def grid_label(number) = "art grid #{number}"

            def bytes_section(label, bytes)
              asm = W65816.new(label, holds: ART)
              asm.label(label)
              asm.data_bytes(bytes.bytes)
              asm.section
            end

            # The colour math a see-through layer needs (#refuse_unmade_see_through!), as
            # [the layers it mixes, the layers behind them] a bit each, BG1's first; nil for none.
            attr_reader :see_through_layers

            # The layers bent, in #bends' order, whose line tables the runtime makes.
            def bent_layers = painted? ? [] : bends.map { |bend| layer_of(background_declared_for(bend)) }

            private

            def by_kind(kind) = @program.walk.select { |node| node.kind == kind }.to_h { |node| [node.name, node] }

            def picture_named(name)
              @pictures.fetch(name) { raise LoweringError, "the picture #{name.inspect} is drawn and never declared" }
            end

            # --- the screen and the backgrounds ---

            # A tiled screen is the one the console is set up for at power-on.
            def emit_screen(_node) = nil

            # Reference#exec_background: put up, showing from its corner (Reference#put_up_background).
            # A scene's own goes up as the scene takes over instead (#emit_scene_arrival).
            def emit_background(node)
              return if @handover.on_arrival?(node)

              emit_put_up(node)
            end

            def emit_put_up(bg)
              runtime_call("rt_background_put_up", [Build.int(layer_of(bg)), Build.int(grid_of(bg, 0).number), Build.int(1)])
              # A status bar put up shows from the top it was declared with (Reference#bar_top_shown).
              runtime_call("rt_bar_place", [Build.int(layer_of(bg)), Build.int(bg.bar_top)]) if bg.bar?
            end

            # WHICH OF THE TWO LAYERS EACH BACKGROUND IS ON (#assign_background_layers). A scene's own
            # scenery is in front of the scenery every screen shows, as the interpreter paints it over
            # what is up already, and within each the one drawn last is in front — the one declared
            # last, or the one in the front-most layer the game's `layers` name (IR::Stacking, which
            # IR::SceneHandover hands the scenery over in the order of): so the scenes' own take the
            # front layers, BG1 first, as many as the scene with the most has, and the scenery every
            # screen shows the layers behind those. So a stack that puts a scene's own background
            # behind one every screen shows is not made yet. (Every sprite is in front of every
            # background, SPRITE_IN_FRONT: a background in front of a sprite needs the sprite in a
            # layer, which #refuse_unmade_picture! refuses.)
            def assign_background_layers
              @layers = {}.compare_by_identity
              always = @handover.always_up.scenery
              own = @scenes.keys.map { |scene| @handover.arrival(scene).scenery }
              @scene_layers = own.map(&:length).max || 0
              if always.length + @scene_layers > BACKGROUND_LAYERS
                refuse_unmade!("more than two backgrounds on the screen at once")
              end
              refuse_unmade!("a status bar that a scene puts up") if own.flatten.any?(&:bar?)
              refuse_unmade_stacking!(always)
              refuse_unmade_bends!(always)
              always.each_with_index { |bg, i| @layers[bg] = @scene_layers + (always.length - 1 - i) }
              own.each { |scenery| scenery.each_with_index { |bg, i| @layers[bg] = scenery.length - 1 - i } }
              refuse_unmade_see_through!(always)
            end

            def layer_of(bg) = @layers.fetch(bg) { raise LoweringError, "the background #{bg.name.inspect} is on no layer" }

            # A stack the layers' order cannot show: a scene's own background behind one every screen
            # shows (see #assign_background_layers).
            def refuse_unmade_stacking!(always)
              @scenes.each_key do |scene|
                own = @handover.arrival(scene).scenery
                drawn = @handover.showing(scene).select { |bg| (always + own).any? { |up| up.equal?(bg) } }
                next if drawn.map(&:object_id) == (always + own).map(&:object_id)

                refuse_unmade!("a scene's own background in a layer behind a background every screen shows")
              end
            end

            # THE DECLARED BACKGROUND a scroll, a changed cell or a map handed over names: the one by
            # that name, or — where several scenes each declare their own by one name — the one of the
            # scene whose routine is being lowered, or the one every screen shows.
            def background_declared_for(node)
              declared = @program.walk.select { |bg| bg.kind == :background && bg.name == node.name }
              raise LoweringError, "#{node.kind} of undeclared background #{node.name.inspect}" if declared.empty?
              return declared.first if declared.length == 1

              own = @lowering_scene && @handover.arrival(@lowering_scene).scenery.find { |bg| bg.name == node.name }
              own || @handover.always_up.scenery.find { |bg| bg.name == node.name }
            end

            # +node+'s change made to the background it names (#background_declared_for), yielded
            # to the block. Where that is not known while the game is built — a change outside every
            # scene's routine, to a name several scenes declare — the change is made to the one of
            # the scene up when it runs, each scene's its own branch.
            def for_background(node)
              bg = background_declared_for(node)
              return yield(bg) if bg

              @scenes.each do |scene, number|
                own = @handover.arrival(scene).scenery.find { |declared| declared.name == node.name }
                next unless own

                other = fresh("not_scene")
                jump_unless(Build.binop(:==, Build.var_ref(@scene), Build.int(number)), other)
                yield own
                @asm.label(other)
              end
            end

            # A scene taking over (Lowering#emit_scene): the tiles its scenery and its sprites paint
            # from lists copied in again, as each list is now; what it shows of its own goes up from
            # its corner, as declared, with every map it chooses back at the first; and the layers its
            # own scenery does not use, which the scene before may have used, come down
            # (IR::SceneHandover). The scenery every screen shows stays as it is.
            def emit_scene_arrival(scene)
              return if painted?

              arrival = @handover.arrival(scene)
              (arrival.painted_tiles + arrival.painted_pictures).each { |run| emit_tile_run_copy(run.name) }
              return if @scene_layers.zero?

              arrival.map_choices.each { |var| store_number(place_of(var), 0) }
              arrival.scenery.each { |bg| emit_put_up(bg) }
              ((0...@scene_layers).to_a - arrival.scenery.map { |bg| layer_of(bg) }).each do |layer|
                runtime_call("rt_background_put_up", [Build.int(layer), Build.int(empty_grid.number), Build.int(1)])
              end
            end

            # A grid of nothing, put up on a layer to take down what was there.
            def empty_grid = @empty_grid ||= @art.grid(Array.new(32) { Array.new(32) }, 32, 32)

            # The background's map number +which+ as a grid of cells (SNES::Art#grid).
            def grid_of(bg, which)
              @grids[[bg.object_id, which]] ||= begin
                map = bg.every_map.fetch(which)
                columns, rows = TileMap.grid(map)
                cells = map.map { |row| Array(row).map { |tile| cell_of(bg, tile) } }
                @art.grid(cells, columns, rows, in_front: cells_in_front?(bg))
              end
            end

            # A cell showing tile +tile+ of +bg+'s, as [tile number, palette], or nil for none.
            def cell_of(bg, tile)
              return nil if tile.nil? || tile.negative?

              name = bg.tiles.fetch(tile)
              @run_cells.fetch(name) { @art.background_cell(Assets::Image.of(picture_named(name))) }
            end

            # Reference#exec_scroll_background.
            def emit_scroll_background(node) = for_background(node) { |bg| emit_scroll_background_on(node, bg) }

            def emit_scroll_background_on(node, bg)
              runtime_call("rt_background_scroll", [Build.int(layer_of(bg)), node.x, node.y])
            end

            # Reference#exec_set_tile: a tile the background does not have changes nothing, and nor
            # does a place outside its map.
            def emit_set_tile(node) = for_background(node) { |bg| emit_set_tile_on(node, bg) }

            def emit_set_tile_on(node, bg)
              return if node.tile && node.tile >= bg.tiles.length

              columns, rows = TileMap.size_of(bg.every_map.first)
              column = keep_local(:column)
              row = keep_local(:row)
              value(node.col)
              store(column)
              value(node.row)
              store(row)
              outside = fresh("cell_outside")
              inside = Build.binop(:and, Build.binop(:and, Build.binop(:>=, Build.var_ref(column), Build.int(0)),
                                                         Build.binop(:<, Build.var_ref(column), Build.int(columns))),
                                   Build.binop(:and, Build.binop(:>=, Build.var_ref(row), Build.int(0)),
                                               Build.binop(:<, Build.var_ref(row), Build.int(rows))))
              jump_unless(inside, outside)
              tile, palette = cell_of(bg, node.tile)
              word = tile ? tile | (palette << Art::PALETTE_SHIFT) | (cells_in_front?(bg) ? Art::CELL_IN_FRONT : 0) : 0
              runtime_call("rt_set_cell", [Build.int(layer_of(bg)), Build.var_ref(column), Build.var_ref(row), Build.int(word)])
              @asm.label(outside)
            end

            # Reference#exec_place_bar: a background that is not a status bar has no top to place.
            def emit_place_bar(node)
              for_background(node) do |bg|
                runtime_call("rt_bar_place", [Build.int(layer_of(bg)), node.top]) if bg.bar?
              end
            end

            # --- tiles painted from a list ---

            # Reference#exec_copy_tiles: the run's list copied into its tiles, shown with this pass.
            def emit_copy_tiles(node) = emit_tile_run_copy(node.name)

            # The run named +name+ copied from its list (Runtime::Picture's rt_tile_run_copy), by the
            # number the runtime knows it by.
            def emit_tile_run_copy(name)
              runtime_call("rt_tile_run_copy", [Build.int(@tile_runs.index { |run| run.name == name })])
            end

            # Reference#exec_copy_owed_tiles: every run whose bit of the masks is set, in the order
            # they were declared.
            def emit_copy_owed_tiles(node)
              per = Nodes::CopyOwedTiles::RUNS_PER_MASK
              node.runs.each_with_index do |name, i|
                skip = fresh("run_not_owed")
                owed = Build.binop(:&, Build.var_ref(node.masks.fetch(i / per)), Build.int(1 << (i % per)))
                jump_unless(Build.binop(:!=, owed, Build.int(0)), skip)
                emit_tile_run_copy(name)
                @asm.label(skip)
              end
            end

            # --- a layer half see-through ---

            # THE LAYER SEEN THROUGH (`layer ..., transparency:`), on the console's colour math: every
            # layer on the main screen as ever, the layers behind the see-through one on the sub
            # screen too, and the math told to add the sub screen to the see-through layer's pixels
            # and halve the sum, on its pixels alone (Runtime::Picture's power-on). So a sprite in
            # front of it, and its own see-through pixels (where what is behind is on top of the main
            # screen, with no math) stay solid, as on the interpreter. The console only halves, so
            # the amounts must come to an even half, eight sixteenths each (IR::SeeThrough.weights),
            # which #refuse_see_through_amounts! has seen to; and where the sub screen has nothing,
            # the console adds its fixed colour instead and does not halve, so a background that
            # covers every pixel must be behind the layer.
            def refuse_unmade_see_through!(always)
              layers = SeeThrough.layers(@program)
              return if layers.empty?

              layer = layers.first
              picture = Stacking.picture(@program)
              scenery = picture.scenery.reject(&:bar?)
              seen_through = scenery.select { |bg| bg.layer == layer.name }
              @see_through_sprites = picture.objects.select { |obj| obj.layer == layer.name }.map(&:name)
              return if seen_through.empty? && @see_through_sprites.empty?
              refuse_unmade!("a see-through layer of both backgrounds and sprites") unless seen_through.empty? || @see_through_sprites.empty?

              at = picture.stack.index(layer.name)
              behind = scenery.select { |bg| bg.layer.nil? || picture.stack.index(bg.layer) < at }
              unless (seen_through + behind).all? { |bg| always.any? { |up| up.equal?(bg) } }
                refuse_unmade!("a see-through layer over a background that a scene puts up")
              end
              raise LoweringError, see_through_uncovered_message(layer) unless behind.any? { |bg| covers_screen?(bg) }

              bits = ->(bgs) { bgs.sum { |bg| 1 << layer_of(bg) } }
              @see_through_layers = if seen_through.empty?
                                      # The sprites' pixels mixed, with the scenery alone behind them.
                                      [SPRITES_BIT, bits.call(behind)]
                                    else
                                      # The backgrounds' pixels mixed, with the scenery and the
                                      # sprites behind them; a sprite in front is not on top of a
                                      # mixed pixel anywhere it is drawn, so has no say.
                                      [bits.call(seen_through), bits.call(behind) | SPRITES_BIT]
                                    end
            end

            # The sprites' bit of the colour math's registers (TS, CGADSUB).
            SPRITES_BIT = 0x10

            # The names of the sprites in the see-through layer, drawn from the palettes the
            # colour math reaches (Art#split_sprite_palettes!).
            def see_through_sprites = @see_through_sprites || []

            HALF = [SeeThrough::STEPS / 2, SeeThrough::STEPS / 2].freeze

            # The amounts of the game's see-through layer, asked before the kinds a Super Nintendo
            # cannot do (Lowering#refuse_what_snes_lacks!), so the framework's step that tells the
            # console an amount again (`:see_through`, put in for an amount worked out as the game
            # runs, or for more than one see-through layer) is refused in words about the amount.
            def refuse_see_through_amounts!
              layers = SeeThrough.layers(@program)
              return if layers.empty?

              refuse_unmade!("more than one see-through layer") if layers.length > 1
              refuse_see_through_amount!(layers.first)
            end

            def refuse_see_through_amount!(layer)
              worked_out = [layer.shows, layer.behind].any? { |amount| amount.kind != :int }
              raise LoweringError, SEE_THROUGH_WORKED_OUT if worked_out
              return if SeeThrough.weights(layer, layer.shows.value, layer.behind.value) == HALF

              said = layer.split ? "`transparency: #{layer.behind.value}`" : "`shows: #{layer.shows.value}, shows_behind: #{layer.behind.value}`"
              raise LoweringError, "Layer :#{layer.name} is see-through by #{said}. A Super Nintendo can show a layer " \
                                   "half see-through only: `transparency:` from 50 to 56, or `shows: 50, shows_behind: " \
                                   "50`. To fix this, use one of those amounts for the Super Nintendo, for example " \
                                   "`transparency: console.name == :snes ? 50 : 40`."
            end

            SEE_THROUGH_WORKED_OUT = "This game works out how see-through a layer is as the game runs. A Super " \
                                     "Nintendo can show a layer half see-through only, so the amount must be a " \
                                     "number. To fix this, give the layer a number for the Super Nintendo, for " \
                                     "example `transparency: console.name == :snes ? 50 : 100 - mist`."

            def see_through_uncovered_message(layer)
              "Layer :#{layer.name} is see-through, and no background behind it covers the whole screen. Where " \
                "nothing is behind it, a Super Nintendo shows the layer whole, not half see-through. To fix this, " \
                "put a background behind layer :#{layer.name} that fills every cell of its map with tiles that " \
                "have no see-through pixels."
            end

            # Whether every map of +bg+ fills the console's whole grid of cells, each a tile with no
            # see-through pixel, so whatever its scroll it covers every pixel of the screen.
            def covers_screen?(bg)
              bg.every_map.all? do |map|
                columns, rows = TileMap.grid(map)
                map.length == rows && map.all? do |row|
                  Array(row).length == columns && Array(row).all? { |tile| solid_tile?(bg, tile) }
                end
              end
            end

            def solid_tile?(bg, tile)
              return false if tile.nil? || tile.negative?
              # A tile the game paints as it runs is never known solid.
              return false if @tile_runs.any? { |run| !run.picture && run.tiles.include?(bg.tiles.fetch(tile)) }

              image = Assets::Image.of(picture_named(bg.tiles.fetch(tile)))
              (0...64).none? { |at| image.tile_see_through_at?(at) }
            end

            # --- a background bent row by row ---

            # Reference#exec_scroll_rows: a standing declaration, gathered up front (#bends). Its rows
            # are worked out at every frame boundary (#emit_bends), not where it is written.
            def emit_scroll_rows(_node) = nil

            # The game's bends: the last each background is given, in the order the backgrounds were
            # first bent (Reference#collect_definitions).
            def bends
              @bends ||= @program.walk.select { |node| node.kind == :scroll_rows }.group_by(&:name).map { |_, said| said.last }
            end

            # Reference#work_out_bends, where the pass's wait ends: each row of the screen, its number
            # in the bend's variable, the bend's own steps, and how far along the row sits kept in the
            # layer's rows (Runtime::Picture.bend_offsets) for the frame after; the first row of each
            # bend, then the rest of each, leaving each variable at the screen's height.
            def emit_bends
              bends.each { |bend| emit_bend_rows(bend, 0...1) }
              bends.each { |bend| emit_bend_rows(bend, 1...Runtime::Picture::SCREEN_HEIGHT) }
            end

            # Rows +rows+ (a range short of its end) of +bend+.
            def emit_bend_rows(bend, rows)
              top = fresh("bend_row")
              done = fresh("bend_rows_done")
              statement(Build.set(bend.row, rows.begin))
              @asm.label(top)
              bend.children.each { |child| statement(child) }
              emit_bend_offset(bend)
              statement(Build.add(bend.row, 1))
              return if rows.size == 1

              jump_unless(Build.binop(:<, Build.var_ref(bend.row), Build.int(rows.end)), done)
              @asm.brl(top)
              @asm.label(done)
            end

            # The row in the bend's variable kept at its place in the layer's rows: the low 16 bits of
            # how far along, all the console's scroll register takes.
            def emit_bend_offset(bend)
              offsets = @memory[Runtime::Picture.bend_offsets(layer_of(background_declared_for(bend)))]
              value(bend.row)
              @asm.lda(@asm.direct(R0))
              @asm.asl
              @asm.pha
              value(bend.offset)
              @asm.plx
              @asm.lda(@asm.direct(R0))
              @asm.sta(@asm.long_x(offsets))
            end

            # The bends a layer's line table cannot show yet: one on a scene's own background (its
            # layer is another scene's in turn), on a status bar, or in a game that never waits for the
            # screen (whose rows the interpreter works out as it paints them).
            def refuse_unmade_bends!(always)
              return if bends.empty?

              refuse_unmade!("a background bent row by row in a game that never waits for the screen") unless
                @program.walk.any? { |node| node.kind == :wait_vblank }
              bends.each do |bend|
                bg = background_declared_for(bend)
                refuse_unmade!("a status bar bent row by row") if bg&.bar?
                refuse_unmade!("a background bent row by row that a scene puts up") unless always.any? { |up| up.equal?(bg) }
              end
            end

            # Reference#exec_show_map: a number naming no map leaves the cells alone; the view stays
            # where it was.
            def emit_show_map(node) = for_background(node) { |bg| emit_show_map_on(node, bg) }

            def emit_show_map_on(node, bg)
              which = keep_local(:map)
              value(node.which)
              store(which)
              done = fresh("map_shown")
              bg.every_map.each_index do |number|
                other = fresh("not_map")
                jump_unless(Build.binop(:==, Build.var_ref(which), Build.int(number)), other)
                runtime_call("rt_background_put_up", [Build.int(layer_of(bg)), Build.int(grid_of(bg, number).number), Build.int(0)])
                @asm.brl(done)
                @asm.label(other)
              end
              @asm.label(done)
            end

            # --- sprites ---

            # Reference#exec_present_objects: every sprite the frame draws, the back-most first, each
            # placed by the runtime from its table of pictures — or none at all on the pass after
            # `hide_sprites`.
            def emit_present_objects(node)
              hidden = sprites_hidden_flag
              placing = fresh("sprites_placed")
              done = fresh("sprites_done")
              call_routine("rt_sprites_begin")
              jump_unless(Build.var_ref(hidden), placing)
              store_number(place_of(hidden), 0)
              @asm.brl(done)
              @asm.label(placing)
              node.names.each do |name|
                obj = @objects.fetch(name) { raise LoweringError, "present of undeclared object #{name.inspect}" }
                skip = fresh("sprite_off")
                jump_unless(Build.binop(:==, obj.active, Build.int(1)), skip)
                behind = sprite_depths.empty? ? [] : [Build.int((3 - sprite_depths.fetch(name, 3)) << SPRITE_PRIORITY_SHIFT)]
                runtime_call("rt_sprite_place", [LongAddress.new(pose_table(obj)), obj.pose, obj.x, obj.y,
                                                 Build.int(@sprite_names.name_number(obj.declared)), *behind])
                @asm.label(skip)
              end
              @asm.label(done)
            end

            # The table of a sprite's pictures: how many, then each one's number.
            def pose_table(obj) = @pose_tables[obj] ||= "poses #{@pose_tables.length}"

            # Reference#exec_hide_sprites: the next placing of the sprites places none.
            def emit_hide_sprites(_node) = store_number(place_of(sprites_hidden_flag), 1)

            # --- fades and tints ---

            # Reference#exec_fade, as a fade that walks the colours (IR::Fading walks every fade on a
            # console that cannot blend, Runtime::Tint): toward black or white by the thirty-seconds
            # the amount comes to. A fade placed under a layer or held to part of the screen needs a
            # blend the build does not make.
            def emit_fade(node)
              refuse_unmade!("a fade held to part of the screen (`#{node.reaches}:`)") if node.reaches
              refuse_unmade!("a fade under a layer (`under:`)") if node.under
              toward = node.toward == :white ? Runtime::Tint::TOWARD_WHITE : Runtime::Tint::TOWARD_BLACK
              runtime_call("rt_tint", [Build.int(toward), Build.int(0), walk_steps(node)])
            end

            # Reference#exec_tint: toward the colour, in thirty-seconds.
            def emit_tint(node)
              runtime_call("rt_tint", [Build.int(Runtime::Tint::TOWARD_COLOR), Build.int(Graphics::Color.resolve(node.color)),
                                       walk_steps(node)])
            end

            # FadeSteps' steps for a fade that walks the colours, worked out as the game runs;
            # Runtime::Tint holds them to 0..32.
            def walk_steps(node) = FadeSteps.steps_value(node.amount, fraction_bits: node.fraction_bits, walked: true)

            def sprites_hidden_flag = @sprites_hidden ||= keep_local(:sprites_hidden)
          end
        end
      end
    end
  end
end
