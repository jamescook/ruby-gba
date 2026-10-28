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
                                                 hide_sprites: :emit_hide_sprites
                                               })

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
            end

            # Each piece of the picture this lowering does not make yet, refused by name: the
            # build makes a tiled screen of 8×8 tiles, at most two backgrounds, and plain sprites.
            def refuse_unmade_picture!
              screens = @program.walk.select { |node| node.kind == :screen }.map(&:mode).uniq
              refuse_unmade!("a painted (bitmap) screen") unless (screens - [:tiled]).empty?
              names = @backgrounds.keys
              refuse_unmade!("more than two backgrounds in one game") if names.length > BACKGROUND_LAYERS
              @backgrounds.each_value do |bg|
                refuse_unmade!("background tiles of #{bg.tile_w}×#{bg.tile_h}") unless bg.tile_w == 8 && bg.tile_h == 8
                refuse_unmade!("a background in a scene of its own") if bg.scene
                refuse_unmade!("a status bar") if bg.bar?
                refuse_unmade!("a background in a layer") if bg.layer
                refuse_unmade!("a background drawn with other colours") unless Array(bg.recolors).empty? && Array(bg.palettes).empty?
                refuse_unmade!("a background drawn from several sets of tiles") if bg.several_sets?
                refuse_unmade!("a background whose maps are of different sizes or too big to hold") if bg.streams?
              end
              @objects.each_value do |obj|
                refuse_unmade!("a sprite in a layer") if obj.layer || obj.layers
                refuse_unmade!("a sprite drawn with other colours") unless obj.recolors.empty?
              end
              ordered = @reachable.any? { |node| node.kind == :present_objects && !Array(node.orders).empty? }
              refuse_unmade!("sprites drawn in an order the game works out (`draw_in_order`)") if ordered
            end

            # Every picture a sprite can show, made into sprite pieces, in the order the pose tables
            # number them.
            def make_sprite_art
              @sprite_pictures = @objects.values.flat_map(&:poses).uniq
              @sprite_pictures.each { |name| @art.sprite_picture(name, Assets::Image.of(picture_named(name))) }
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
              data.label("art colors")
              data.data_bytes(@art.cgram.bytes)
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
              @pose_tables.each do |obj, label|
                data.label(label)
                data.data_words(obj.poses.length, *obj.poses.map { |pose| @sprite_pictures.index(pose) })
              end
              [data.section, *bytes_section("art background tiles", @art.background_tile_data),
               *bytes_section("art sprite tiles", @art.sprite_tile_data),
               *@art.grids.map { |grid| bytes_section(grid_label(grid.number), grid.bytes) }]
            end

            ART = W65816::Holding.new(what: "the game's pictures", fix: "use fewer different pictures and maps")

            # A sprite row's attributes, the high byte of its tile word: in front of every background
            # (priority 3).
            SPRITE_IN_FRONT = 0x3000

            def pieces_label(number) = "art pieces #{number}"
            def grid_label(number) = "art grid #{number}"

            def bytes_section(label, bytes)
              asm = W65816.new(label, holds: ART)
              asm.label(label)
              asm.data_bytes(bytes.bytes)
              asm.section
            end

            private

            def by_kind(kind) = @program.walk.select { |node| node.kind == kind }.to_h { |node| [node.name, node] }

            def picture_named(name)
              @pictures.fetch(name) { raise LoweringError, "the picture #{name.inspect} is drawn and never declared" }
            end

            # --- the screen and the backgrounds ---

            # A tiled screen is the one the console is set up for at power-on.
            def emit_screen(_node) = nil

            # Reference#exec_background: put up, showing from its corner (Reference#put_up_background).
            def emit_background(node)
              return if @handover.on_arrival?(node)

              runtime_call("rt_background_put_up", [Build.int(layer_of(node)), Build.int(grid_of(node, 0).number), Build.int(1)])
            end

            # The layer a background is on: the one declared last on BG1 (0), in front.
            def layer_of(bg) = @backgrounds.length - 1 - @backgrounds.keys.index(bg.name)

            # The declared background a scroll, a changed cell or a map handed over names.
            def background_declared_for(node)
              @backgrounds.fetch(node.name) { raise LoweringError, "#{node.kind} of undeclared background #{node.name.inspect}" }
            end

            # The background's map number +which+ as a grid of cells (SNES::Art#grid).
            def grid_of(bg, which)
              @grids[[bg.name, which]] ||= begin
                map = bg.every_map.fetch(which)
                columns, rows = TileMap.grid(map)
                cells = map.map { |row| Array(row).map { |tile| cell_of(bg, tile) } }
                @art.grid(cells, columns, rows)
              end
            end

            # A cell showing tile +tile+ of +bg+'s, as [tile number, palette], or nil for none.
            def cell_of(bg, tile)
              return nil if tile.nil? || tile.negative?

              @art.background_cell(Assets::Image.of(picture_named(bg.tiles.fetch(tile))))
            end

            # Reference#exec_scroll_background.
            def emit_scroll_background(node)
              bg = background_declared_for(node)
              runtime_call("rt_background_scroll", [Build.int(layer_of(bg)), node.x, node.y])
            end

            # Reference#exec_set_tile: a tile the background does not have changes nothing, and nor
            # does a place outside its map.
            def emit_set_tile(node)
              bg = background_declared_for(node)
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
              word = tile ? tile | (palette << Art::PALETTE_SHIFT) : 0
              runtime_call("rt_set_cell", [Build.int(layer_of(bg)), Build.var_ref(column), Build.var_ref(row), Build.int(word)])
              @asm.label(outside)
            end

            # Reference#exec_show_map: a number naming no map leaves the cells alone; the view stays
            # where it was.
            def emit_show_map(node)
              bg = background_declared_for(node)
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
                runtime_call("rt_sprite_place", [LongAddress.new(pose_table(obj)), obj.pose, obj.x, obj.y,
                                                 Build.int(@sprite_names.name_number(obj.declared))])
                @asm.label(skip)
              end
              @asm.label(done)
            end

            # The table of a sprite's pictures: how many, then each one's number.
            def pose_table(obj) = @pose_tables[obj] ||= "poses #{@pose_tables.length}"

            # Reference#exec_hide_sprites: the next placing of the sprites places none.
            def emit_hide_sprites(_node) = store_number(place_of(sprites_hidden_flag), 1)

            def sprites_hidden_flag = @sprites_hidden ||= keep_local(:sprites_hidden)
          end
        end
      end
    end
  end
end
