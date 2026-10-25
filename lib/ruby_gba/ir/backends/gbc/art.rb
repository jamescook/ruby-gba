# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        # A GAME'S PICTURES, MADE INTO WHAT A GAME BOY COLOR DRAWS FROM, while the program is built.
        #
        # The Color draws everything from TILES: 8×8 pictures of two bits a pixel, so each pixel is
        # one of four places in a list of colours (a PALETTE). The background is a grid of tiles,
        # each cell naming a tile and one of eight palettes; a sprite is one or more tiles placed
        # anywhere, each drawn from one of eight palettes of its own, whose place 0 is see-through.
        #
        # So a picture the game declared is cut into 8×8 pieces, each piece's pixels written as
        # places in a list of four, and the lists the game's pictures need gathered into palettes.
        # What cannot fit — a picture with more colours than a list holds, more lists than the
        # Color has — is refused here with the picture's name.
        #
        # A background's place 0 is the BACKDROP, the colour shown where nothing is drawn, which on
        # the Color as in the interpreter is black: a tile's see-through pixels show it. So a
        # background tile has three colours of its own, and a sprite's picture three and
        # see-through.
        #
        # Everything is kept in the cartridge (#sections) under the labels the runtime reads it by
        # (Runtime::Picture): the tiles, copied into the console's memory at power-on; the
        # palettes; for every sprite picture its pieces and the mask of its drawn pixels, which is
        # what two sprites are tested against each other with; and every grid a background shows.
        class Art
          # The places a list holds, and how many are the picture's own: one is see-through.
          PLACES = 4
          OWN_COLORS = PLACES - 1

          # How many palettes of each kind there are.
          PALETTES = 8

          # The backdrop: black, as the interpreter's empty screen is.
          BACKDROP = 0

          # How many tiles of each kind there is room for in the console's picture memory: sprites
          # 128 to a bank, backgrounds 256 to a bank, two banks.
          MOST_SPRITE_TILES = 256
          MOST_BACKGROUND_TILES = 512

          # The grid a background is drawn on: 32 cells each way, wrapping round.
          GRID_CELLS = 32

          # The widest and tallest picture a sprite can show: the mask a collision reads is kept a
          # byte for every eight pixels of a row, and the runtime walks it in byte-sized steps.
          LARGEST_SPRITE = 64

          # A pixel of a picture that is not drawn, beside the colours of the ones that are.
          NOT_DRAWN = -1

          # One 8×8 piece of a sprite's picture: where it sits in the picture, its tile, and
          # whether that tile is drawn mirrored to make it.
          Piece = Data.define(:dx, :dy, :tile, :flips)

          # A sprite's picture, cut into pieces, with the place each pixel is drawn from (0 for one
          # not drawn) and the mask of the pixels it draws.
          SpritePicture = Data.define(:name, :number, :width, :height, :pieces, :places, :mask)

          # A game with a painted screen gives it the background's last palettes, as many as its
          # squares need (GBC::SquareColors), the last first, and the tiles past the first 128
          # (Runtime::Paint), so its tiled screens have the rest.
          PAINTING_BACKGROUND_TILES = 128

          # MORE SPRITE LISTS THAN THE COLOR HOLDS. A game whose sprites between them wear more
          # than eight lists of colours still fits when no more than eight are on the screen at
          # once: each list then BORROWS one of the eight as a sprite wearing it is placed, and
          # its colours are copied in (Runtime::Picture#emit_lend_colors). A game is first built
          # with a list of its own for each, which costs nothing as it runs; this is raised when
          # that runs out, and the build is made again lending them (GBC#build).
          class TooManySpriteLists < LoweringError; end

          # The most lists a game that lends them can have: the runtime keeps which one each of
          # the eight holds in a byte, one up so that nought is none.
          MOST_LENT = 254

          attr_reader :sprite_tiles, :sprite_palettes, :background_tiles, :background_palettes, :grids

          # A tile of a picture grouped by room: the +index+th of the picture's own, whose number is
          # known once every picture is (#group_rooms).
          GroupedTile = Data.define(:picture, :index)

          # A set of picture groups' room in sprite memory: its first tile, where each of its
          # pictures goes in it (IR::PictureGroupPlaces), and the pictures, in the order their tiles
          # are kept in the cartridge.
          GroupRoom = Data.define(:set, :number, :first_tile, :places, :pictures)

          # +square_colors+ are the colour lists of a painted screen's squares (GBC::SquareColors), nil for
          # a game that paints no screen. +lends+ says the sprites' lists borrow the console's eight
          # as the game runs (TooManySpriteLists). +grouped+ is the set of picture groups each grouped
          # picture is copied in by, by the picture's name (Lowering::Picture#grouped_pictures).
          def initialize(square_colors: nil, lends: false, grouped: {})
            @square_colors = square_colors
            @lends = lends
            @grouped = grouped
            @grouped_tiles = {} # a grouped picture's name -> its own tiles, 16 bytes each
            @sprite_tiles = []        # 16 bytes each
            @sprite_tile_numbers = {} # bytes -> [number, flips]
            @sprite_pictures = {}     # picture name -> SpritePicture
            @sprite_palettes = []     # lists of four colours
            @background_tiles = []
            @background_tile_numbers = {}
            @background_palettes = []
            @background_tile_of = {} # picture name -> [tile number, palette number]
            @run_tile_of = {} # a painted tile's name -> [tile number, palette number]
            @grids = []               # 2048 bytes each: the cells' tiles, then their attributes
            @big_maps = []            # [bytes, columns, rows] of each map bigger than the grid
            background_tile_number(Array.new(16, 0)) # tile 0: nothing but the backdrop, for an empty cell
            grid(Array.new(GRID_CELLS) { Array.new(GRID_CELLS) }) # grid 0: nothing up
          end

          def painting? = !@square_colors.nil?

          # The painted screen's palettes, four colours each, and the console's numbers for them, the
          # last of the eight first. None for a game that paints no screen.
          def paint_palettes = painting? ? @square_colors.palettes : []
          def painted_palettes = (0...paint_palettes.length).map { |i| PALETTES - 1 - i }

          # The maps of the painted screen (GBC::SquareColors#maps): for each, the console's number of
          # the palette each of its 360 squares names. None for a game that paints no screen.
          def square_maps = painting? ? @square_colors.maps.map { |map| map.map { |i| PALETTES - 1 - i } } : []

          # The map scene +name+ shows, by its number among #square_maps (nil for outside every scene).
          def square_map_of(name) = @square_colors.map_of(name)

          # Do the sprites' lists borrow the console's eight as the game runs? Then a sprite
          # palette's number counts into every list the game has (art_lent_palettes), not the eight.
          def lends? = @lends

          # Has the game pictures grouped by room, copied in as a room comes up (Runtime::PictureGroups)?
          def groups? = !@grouped.empty?

          # EVERY SET OF PICTURE GROUPS' ROOM IN SPRITE MEMORY, one after another past the tiles every
          # screen keeps, once every picture is known. A set's grouped pictures share its room as
          # their groups allow (IR::PictureGroupPlaces), counted in tiles; each set has a room of its
          # own, so a scene given the screen back finds its groups' pictures where it left them.
          def group_rooms
            @group_rooms ||= begin
              first = @sprite_tiles.length
              @grouped.values.uniq(&:name).each_with_index.map do |set, number|
                pictures = @grouped_tiles.keys.select { |name| @grouped[name].name == set.name }
                placed = pictures.map do |name|
                  IR::PictureGroupPlaces::Picture.new(key: name, units: @grouped_tiles[name].length, even_start: false,
                                                      groups: set.groups_holding(name))
                end
                room = GroupRoom.new(set: set, number: number, first_tile: first, pictures: pictures,
                                     places: IR::PictureGroupPlaces.new(placed, together: set.together))
                first += room.places.units
                room
              end
            end
          end

          # The number of a sprite's tile in sprite memory, a grouped picture's in its set's room.
          def tile_number(tile)
            return tile unless tile.is_a?(GroupedTile)

            room = group_rooms.find { |each| each.set.name == @grouped.fetch(tile.picture).name }
            room.first_tile + room.places.offset(tile.picture) + tile.index
          end

          # The palettes the game can show, by the console's numbers: the backgrounds' from 0 — the
          # first always, since its first colour is the backdrop — the painted screen's, and the
          # sprites' from 8, all eight of those when they are lent.
          def palettes_in_use
            backgrounds = (0...[@background_palettes.length, 1].max).to_a
            backgrounds.concat(painted_palettes)
            sprites =(0...(lends? ? PALETTES : @sprite_palettes.length)).map { |n| PALETTES + n }
            (backgrounds + sprites).uniq
          end

          # The place a painted colour is kept at in every one of the painted screen's palettes.
          def paint_place(color) = @square_colors.place(color)

          # --- sprites ---

          # The picture +name+ (an Assets::Image) as a sprite shows it: cut into pieces whose tiles
          # are kept once each. +colors+ is the picture's own list by place, see-through first.
          def sprite_picture(name, image)
            @sprite_pictures[name] ||= begin
              pieces = ((image.width + 7) / 8) * ((image.height + 7) / 8)
              too_big = image.width > LARGEST_SPRITE || image.height > LARGEST_SPRITE
              if too_big && pieces > Console::GBCHardware::SPRITES
                raise LoweringError, "the sprite picture #{name.inspect} is #{image.width}×#{image.height}, which is " \
                                     "#{pieces} pieces of 8×8, and a Game Boy Color shows #{Console::GBCHardware::SPRITES} " \
                                     "at once. To fix this, make the picture smaller."
              end
              if too_big
                raise LoweringError, "the sprite picture #{name.inspect} is #{image.width}×#{image.height}, and a " \
                                     "Game Boy Color sprite is at most #{LARGEST_SPRITE}×#{LARGEST_SPRITE}."
              end

              places = sprite_places(name, image)
              pieces = []
              (0...image.height).step(8).each do |y0|
                (0...image.width).step(8).each do |x0|
                  piece = Array.new(64) do |i|
                    x = x0 + (i % 8)
                    y = y0 + (i / 8)
                    x >= image.width || y >= image.height ? 0 : places[(y * image.width) + x]
                  end
                  next if piece.all?(&:zero?) # a piece with nothing in it is not drawn at all

                  tile, flips = @grouped.key?(name) ? grouped_tile(name, piece) : sprite_tile(piece)
                  pieces << Piece.new(dx: x0, dy: y0, tile: tile, flips: flips)
                end
              end
              mask = Array.new(image.width * image.height) { |i| image.drawn_at?(i) }
              SpritePicture.new(name: name, number: @sprite_pictures.size, width: image.width, height: image.height,
                                pieces: pieces, places: places, mask: mask)
            end
          end

          # A SPRITE'S PICTURE THE GAME PAINTS from a list (Nodes::TileRun with a picture): every 8×8
          # piece of it, in the order the list keeps them — left to right, then top to bottom — a tile
          # of its own, empty until the game's first copy. Its outline is not known while the game is
          # built, so it collides with nothing.
          def painted_sprite_picture(name, width, height)
            @sprite_pictures[name] ||= begin
              pieces = (0...height).step(8).flat_map do |y0|
                (0...width).step(8).map do |x0|
                  Piece.new(dx: x0, dy: y0, tile: (@sprite_tiles << Array.new(16, 0)).length - 1, flips: 0)
                end
              end
              SpritePicture.new(name: name, number: @sprite_pictures.size, width: width, height: height, pieces: pieces,
                                places: Array.new(width * height, 0), mask: Array.new(width * height, false))
            end
          end

          # The palette a painted picture is drawn in from +colors+, a list by place, see-through first.
          def painted_sprite_palette(name, colors)
            if colors.length > PLACES
              raise LoweringError, "the sprite picture #{name.inspect} is painted from a list with #{colors.length} " \
                                   "colours, and a Game Boy Color sprite holds #{OWN_COLORS} and see-through. To fix " \
                                   "this, give `colors:` #{PLACES} colours or fewer."
            end

            palette_number(@sprite_palettes, padded([BACKDROP, *colors.drop(1).map { |color| color & 0x7FFF }]), "sprites")
          end

          # The palette a sprite picture drawn as +drawn+ shows is given: +drawn+ is each pixel's
          # colour, or NOT_DRAWN, as the interpreter draws the picture (in its own colours or in
          # another list's). The same list asked twice is the same palette.
          def sprite_palette(name, image, drawn)
            picture = sprite_picture(name, image)
            colors = Array.new(PLACES, BACKDROP)
            picture.places.each_with_index do |place, i|
              next if place.zero? || drawn[i] == NOT_DRAWN

              colors[place] = drawn[i] & 0x7FFF
            end
            palette_number(@sprite_palettes, colors, "sprites")
          end

          # --- backgrounds ---

          # The tile number and palette number a background's tile picture +name+ is drawn with.
          def background_tile(name, image)
            @background_tile_of[name] ||= begin
              unless image.width == 8 && image.height == 8
                raise LoweringError, "the tile #{name.inspect} is #{image.width}×#{image.height}; the Game Boy Color " \
                                     "build makes 8×8 tiles only so far."
              end

              drawn = tile_colors(image)
              if drawn.size > OWN_COLORS
                raise LoweringError, "the tile #{name.inspect} has #{drawn.size} colours, and a Game Boy Color tile holds " \
                                     "#{OWN_COLORS} and the backdrop. To fix this, draw it in #{OWN_COLORS} colours."
              end

              colors = [BACKDROP, *drawn]
              places = Array.new(64) { |i| image.tile_see_through_at?(i) ? 0 : drawn.index(image.color_at(i) & 0x7FFF) + 1 }
              [background_tile_number(encode(places)), palette_number(@background_palettes, padded(colors), "backgrounds")]
            end
          end

          # The colours a background tile draws, in the order its palette holds them after the
          # backdrop: the order it first draws each.
          def tile_colors(image)
            (0...64).reject { |i| image.tile_see_through_at?(i) }.map { |i| image.color_at(i) & 0x7FFF }.uniq
          end

          # A TILE THE GAME PAINTS from a list (Nodes::TileRun): a tile number of its own, never
          # shared with another tile however alike the two start, since the game writes it as it
          # runs; empty until the game's first copy, as the interpreter's is. +colors+ is the run's
          # list, see-through first, and gives its palette: the backdrop where it is see-through.
          def run_tile(name, colors)
            @run_tile_of[name] ||= begin
              if colors.length > PLACES
                raise LoweringError, "the tiles painted from a list with #{colors.length} colours (#{name.inspect}) " \
                                     "are more than a Game Boy Color tile holds: #{OWN_COLORS} and the backdrop. " \
                                     "To fix this, give `colors:` #{PLACES} colours or fewer, the first meaning " \
                                     "see-through."
              end

              own = colors.drop(1).map { |color| color & 0x7FFF }
              [(@background_tiles << Array.new(16, 0)).length - 1,
               palette_number(@background_palettes, padded([BACKDROP, *own]), "backgrounds")]
            end
          end

          # The number of a grid of 32×32 cells, each [tile number, palette number] or nil for a
          # cell with nothing in it, which shows the backdrop.
          def grid(cells)
            tiles = cells.flatten(1).map { |cell| cell ? cell.first : 0 }
            attributes = cells.flatten(1).map do |cell|
              next 0 unless cell

              tile, palette = cell
              palette | (tile >= 256 ? Console::GBCHardware::ATTR_TILE_BANK : 0)
            end
            bytes = tiles.map { |tile| tile & 0xFF } + attributes
            @grids.index(bytes) || (@grids << bytes).length - 1
          end

          # The number of a map bigger than the grid (Runtime::BigMaps), kept whole: +cells+ is its
          # rows, each cell [tile number, palette number] or nil for one with nothing in it, and every
          # cell is two bytes, its tile and its colours, a row after another.
          def big_map(cells)
            cols = cells.map(&:length).max.to_i
            if cols > 255 || cells.length > 255
              raise LoweringError, "a map of #{cols}×#{cells.length} cells is bigger than a Game Boy Color build " \
                                   "keeps, which is 255 each way."
            end

            bytes = cells.flat_map do |row|
              Array.new(cols) do |col|
                tile, palette = row[col]
                next [0, 0] unless tile

                [tile & 0xFF, palette | (tile >= 256 ? Console::GBCHardware::ATTR_TILE_BANK : 0)]
              end.flatten
            end
            entry = [bytes, cols, cells.length]
            @big_maps.index(entry) || (@big_maps << entry).length - 1
          end

          # The number of a big map of +cols+ × +rows+ kept in work memory at +address+ (one the game
          # changes, Runtime::BigMaps's rt_big_copy_in): its table of rows says where each row is there.
          def big_map_in_memory(cols, rows, address)
            entry = [nil, cols, rows, address]
            @big_maps.index(entry) || (@big_maps << entry).length - 1
          end

          # --- the cartridge's copy ---

          # What each of the art's sections is to the author, for a cartridge too full for them (see
          # Linker::TooBig). The tables hold every list of colours, and for each sprite picture the
          # pieces it is cut into and the outline it collides by, so sprite pictures are what grow it.
          SPRITE_PICTURES = SM83::Holding.new(what: "the game's sprite pictures", fix: "use fewer or smaller sprite pictures")
          PICTURE_TABLES = SM83::Holding.new(what: "the colours and outlines of the game's pictures",
                                             fix: "use fewer or smaller sprite pictures")
          BACKGROUND_TILES = SM83::Holding.new(what: "the game's background tiles",
                                               fix: "use fewer different tiles in its backgrounds")
          BACKGROUND_MAPS = SM83::Holding.new(what: "the game's background maps",
                                              fix: "make its background maps smaller, or use fewer of them")

          # The sections the art is kept in: the tiles and the grids in banks of their own (each a
          # copy the runtime puts the bank in view for), and everything read as the game runs —
          # the palettes, the pieces, the masks, where each grid is — in the part always in view.
          def sections
            refuse_too_many_tiles!
            [tables_section,
             data_section("art sprite tiles", "art_sprite_tiles", @sprite_tiles.flatten, holds: SPRITE_PICTURES),
             *group_rooms.map { |room| group_tiles_section(room) },
             data_section("art background tiles", "art_background_tiles", @background_tiles.flatten,
                          holds: BACKGROUND_TILES),
             *@grids.each_with_index.map do |bytes, i|
               data_section("art grid #{i}", "art_grid_#{i}", bytes, holds: BACKGROUND_MAPS)
             end,
             *@big_maps.each_with_index.flat_map do |(bytes, cols, _), i|
               next [] unless bytes # kept in work memory

               # A row to a section, since a whole map can be more than a bank holds.
               bytes.each_slice(cols * 2).each_with_index.map do |row, r|
                 data_section("art big map #{i} row #{r}", "art_big_map_#{i}_#{r}", row, holds: BACKGROUND_MAPS)
               end
             end]
          end

          private

          def tables_section
            asm = SM83.new("art tables", home: :fixed, holds: PICTURE_TABLES)
            asm.label("art_palettes")
            backgrounds = @background_palettes.dup
            painted_palettes.zip(paint_palettes).each { |number, colors| backgrounds[number] = colors }
            # A game that lends its sprites' lists starts with nothing in the eight.
            [backgrounds, lends? ? [] : @sprite_palettes].each do |palettes|
              PALETTES.times do |i|
                colors = palettes[i] || Array.new(PLACES, BACKDROP)
                asm.data_words(colors)
              end
            end
            if lends?
              asm.label("art_lent_palettes")
              @sprite_palettes.each { |colors| asm.data_words(colors) }
            end
            pictures = @sprite_pictures.values
            asm.label("art_pictures")
            pictures.each { |picture| asm.data_words("art_pieces_#{picture.number}") }
            asm.label("art_masks")
            pictures.each { |picture| asm.data_words("art_mask_#{picture.number}") }
            asm.label("art_grids")
            @grids.each_index do |i|
              asm.data_words("art_grid_#{i}")
              asm.data_bank_of("art_grid_#{i}")
            end
            # Each map bigger than the grid as Runtime::BigMaps reads it: where its table of rows is
            # (each row's place and bank), a byte unused, and its size.
            asm.label("art_big_maps")
            @big_maps.each_index do |i|
              asm.data_words("art_big_rows_#{i}")
              asm.data_bytes(0, @big_maps[i][1], @big_maps[i][2])
            end
            @big_maps.each_with_index do |(bytes, cols, rows, address), i|
              asm.label("art_big_rows_#{i}")
              rows.times do |r|
                if bytes
                  asm.data_words("art_big_map_#{i}_#{r}")
                  asm.data_bank_of("art_big_map_#{i}_#{r}")
                else
                  asm.data_words(address + (r * cols * 2))
                  asm.data_bytes(1) # work memory reads the same whichever bank is in view
                end
              end
            end
            group_rooms.each { |room| emit_group_tables(asm, room) }
            pictures.each do |picture|
              asm.label("art_pieces_#{picture.number}")
              asm.data_bytes(picture.pieces.length)
              picture.pieces.each do |piece|
                tile = tile_number(piece.tile)
                bank = tile / 128
                asm.data_bytes(piece.dx, piece.dy, tile % 128,
                               piece.flips | (bank.zero? ? 0 : Console::GBCHardware::OBJ_TILE_BANK))
              end
              asm.label("art_mask_#{picture.number}")
              stride = (picture.width + 7) / 8
              asm.data_bytes(picture.width, picture.height, stride)
              picture.height.times do |y|
                stride.times do |byte|
                  bits = (0...8).sum do |bit|
                    x = (byte * 8) + bit
                    x < picture.width && picture.mask[(y * picture.width) + x] ? 0x80 >> bit : 0
                  end
                  asm.data_bytes(bits)
                end
              end
            end
            asm.section
          end

          # A run of a grouped picture's tiles as the copy into sprite memory takes it
          # (Runtime::PictureGroups): its label in its set's copy of the tiles, the tiles, and the
          # bank of picture memory and the place they go. At most CHUNK_TILES, and never across
          # from one bank of picture memory to the other.
          GroupChunk = Data.define(:label, :tiles, :bank, :to)

          # Each picture of +room+ in its chunks, by the picture's name.
          def group_chunks(room)
            @group_chunks ||= {}
            @group_chunks[room.number] ||= room.pictures.each_with_index.to_h do |name, p|
              tiles = @grouped_tiles.fetch(name)
              first = room.first_tile + room.places.offset(name)
              chunks = []
              at = 0
              while at < tiles.length
                tile = first + at
                count = [Runtime::PictureGroups::CHUNK_TILES, tiles.length - at, 128 - (tile % 128)].min
                chunks << GroupChunk.new(label: "art_group_#{room.number}_#{p}_#{chunks.length}", tiles: tiles[at, count],
                                         bank: tile / 128, to: Console::GBCHardware::VRAM + ((tile % 128) * 16))
                at += count
              end
              [name, chunks]
            end
          end

          # A set's grouped pictures' tiles, picture after picture, a label at each chunk, where the
          # console's own copy reads them from.
          def group_tiles_section(room)
            asm = SM83.new("art group tiles #{room.set.name}", home: :aligned16, holds: SPRITE_PICTURES)
            asm.label("art_group_#{room.number}_tiles")
            group_chunks(room).each_value do |chunks|
              chunks.each do |chunk|
                asm.label(chunk.label)
                asm.data_bytes(chunk.tiles.flatten)
              end
            end
            asm.data_bytes(0) if room.pictures.empty? # a label has to be somewhere
            asm.section
          end

          # A set's table of groups (Runtime::PictureGroups): for each group, how many chunks it
          # copies and where their list is; then each list, a chunk to an entry.
          def emit_group_tables(asm, room)
            lists = room.set.groups.each_index.map do |number|
              room.pictures.select { |name| room.set.groups_holding(name).include?(number) }
                  .flat_map { |name| group_chunks(room).fetch(name) }
            end
            asm.label("art_group_#{room.number}_groups")
            lists.each_with_index do |chunks, number|
              asm.data_bytes(chunks.length)
              asm.data_words("art_group_#{room.number}_list_#{number}")
            end
            lists.each_with_index do |chunks, number|
              asm.label("art_group_#{room.number}_list_#{number}")
              chunks.each do |chunk|
                asm.data_words(chunk.label)
                asm.data_bytes(chunk.bank)
                asm.data_words(chunk.to)
                asm.data_bytes(chunk.tiles.length - 1)
              end
            end
          end

          # A copy the console's own copying (Runtime::Picture) reads 16 bytes at a time, from an
          # address that is a multiple of 16 — which a bank's first byte is.
          def data_section(name, label, bytes, holds:)
            asm = SM83.new(name, home: :aligned16, holds: holds)
            asm.label(label)
            asm.data_bytes(bytes)
            asm.data_bytes(0) if bytes.empty? # a label has to be somewhere
            asm.section
          end

          def refuse_too_many_tiles!
            rooms = group_rooms.sum { |room| room.places.units }
            if @sprite_tiles.length + rooms > MOST_SPRITE_TILES
              grouped = if rooms.zero? then ""
                        else
                          " (#{@sprite_tiles.length} for the pictures in no group, and #{rooms} for the groups " \
                            "that can be up together)"
                        end
              raise LoweringError, "this game's sprites need #{@sprite_tiles.length + rooms} tiles of 8×8#{grouped}, " \
                                   "and a Game Boy Color has room for #{MOST_SPRITE_TILES}. To fix this, give it fewer " \
                                   "or smaller pictures."
            end
            most = painting? ? PAINTING_BACKGROUND_TILES : MOST_BACKGROUND_TILES
            return unless @background_tiles.length > most

            raise LoweringError, "this game's backgrounds need #{@background_tiles.length} different tiles, and a Game " \
                                 "Boy Color has room for #{most}#{painting? ? ' beside a painted screen' : ''}."
          end

          # The place each pixel of a sprite's picture is drawn from: its own list's, where it came
          # with one, or see-through and then every colour it draws in the order it draws them.
          def sprite_places(name, image)
            if image.places
              places = Array.new(image.width * image.height) { |i| image.drawn_at?(i) ? image.place_at(i) : 0 }
              refuse_sprite_colors!(name, places.max.to_i)
              return places
            end

            colors = [nil]
            Array.new(image.width * image.height) do |i|
              next 0 unless image.drawn_at?(i)

              color = image.color_at(i) & 0x7FFF
              colors << color unless colors.include?(color)
              colors.index(color)
            end.tap { refuse_sprite_colors!(name, colors.length - 1) }
          end

          def refuse_sprite_colors!(name, colors)
            return if colors <= OWN_COLORS

            raise LoweringError, "the sprite picture #{name.inspect} has #{colors} colours, and a Game Boy Color " \
                                 "sprite holds #{OWN_COLORS} and see-through. To fix this, draw it in " \
                                 "#{OWN_COLORS} colours."
          end

          # Sixty-four places as the Color keeps a tile: two bytes a row, the low bit of each
          # place in the first and the high bit in the second, the leftmost pixel in bit 7.
          def encode(places)
            (0...8).flat_map do |row|
              line = places[row * 8, 8]
              low = line.each_with_index.sum { |place, x| (place & 1) << (7 - x) }
              high = line.each_with_index.sum { |place, x| ((place >> 1) & 1) << (7 - x) }
              [low, high]
            end
          end

          # A sprite tile: one already kept, drawn as it is or mirrored, or a new one. The Color
          # mirrors a sprite's tile as it draws it, so a picture and its mirror image share tiles.
          def sprite_tile(places)
            turnings(places).each do |flips, version|
              number = @sprite_tile_numbers[encode(version)]
              return [number, flips] if number
            end
            bytes = encode(places)
            @sprite_tile_numbers[bytes] = (@sprite_tiles << bytes).length - 1
            [@sprite_tile_numbers[bytes], 0]
          end

          # A tile of the grouped picture +name+: one of the picture's own already kept, drawn as it
          # is or turned, or a new one. It shares no tile with another picture, since the two need
          # not be up at the same time.
          def grouped_tile(name, places)
            own = (@grouped_tiles[name] ||= [])
            turnings(places).each do |flips, version|
              index = own.index(encode(version))
              return [GroupedTile.new(picture: name, index: index), flips] if index
            end
            [GroupedTile.new(picture: name, index: (own << encode(places)).length - 1), 0]
          end

          # The tile's places drawn as they are, mirrored, upside down and both, by the flips that
          # draw the tile that way.
          def turnings(places)
            h = Console::GBCHardware
            { 0 => places, h::OBJ_X_FLIP => mirrored(places), h::OBJ_Y_FLIP => upside_down(places),
              h::OBJ_X_FLIP | h::OBJ_Y_FLIP => upside_down(mirrored(places)) }
          end

          def mirrored(places) = places.each_slice(8).flat_map(&:reverse)
          def upside_down(places) = places.each_slice(8).to_a.reverse.flatten

          def background_tile_number(bytes)
            @background_tile_numbers[bytes] ||= (@background_tiles << bytes).length - 1
          end

          def padded(colors) = colors + ([BACKDROP] * (PLACES - colors.length))

          def palette_number(palettes, colors, kind)
            found = palettes.index(colors)
            return found if found

            sprites = palettes.equal?(@sprite_palettes)
            most = if sprites then lends? ? MOST_LENT : PALETTES
                   elsif painting? then PALETTES - painted_palettes.length
                   else PALETTES
                   end
            if palettes.length == most
              raise TooManySpriteLists, "more lists" if sprites && !lends?

              raise LoweringError, "this game's #{kind} need more than the #{most} lists of colours a Game Boy Color " \
                                   "#{sprites ? 'build keeps' : 'holds'} for them. To fix this, draw more of them " \
                                   "from the same colours."
            end

            (palettes << colors).length - 1
          end
        end
      end
    end
  end
end
