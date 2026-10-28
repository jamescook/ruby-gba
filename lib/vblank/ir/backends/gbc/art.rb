# frozen_string_literal: true

module VBlank
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

          # MORE BACKGROUND TILES THAN THE COLOR HOLDS AT ONCE. A game whose backgrounds between
          # them need more tiles than its picture memory holds still fits when no one screen needs
          # more: each screen then BRINGS ITS OWN TILES IN as it comes up (a Room, and
          # Runtime::Picture#emit_rooms). A game is first built with every tile in memory from
          # power-on, which costs nothing as it runs; this is raised when that runs out, and the
          # build is made again with rooms (GBC#build).
          class TooManyBackgroundTiles < LoweringError; end

          # MORE BACKGROUND LISTS OF COLOURS THAN THE COLOR HOLDS AT ONCE. A game whose backgrounds
          # between them draw from more than eight lists still fits when no one screen draws from
          # more: each screen then brings its own palettes in with its tiles (a Room's +palettes+). A
          # game is first built with every palette in the console from power-on; this is raised when
          # that runs out, and the build is made again with rooms that carry colours (GBC#build).
          class TooManyBackgroundLists < LoweringError; end

          # THE TILES ONE SCREEN BRINGS IN, past the ones every screen keeps from power-on: a scene's
          # own backgrounds' tiles, or one area's of a background that walks between areas. +number+
          # is the one the runtime brings it in by (one up, so that nought is none), or nil for a
          # scene's tiles that only its areas' rooms bring in (+parent+ of each of those). +base+ is
          # its first tile's number, +tiles+ its own tiles (16 bytes each) and +numbers+ which number
          # each is by its bytes. +what+ says whose it is, for a message, and +id+ which it is among
          # every room the game has, which labels its tiles in the cartridge.
          #
          # In a game whose screens bring their colours in too (Art#room_colors?), +palettes+ are the
          # room's own (Art::BackgroundPalette each), numbered from +palette_base+, past every screen's and its
          # parent's; and +first_palette+ is the one it puts first, where an empty cell is drawn
          # from, when no palette every screen keeps is there (#room_palette_number).
          Room = Struct.new(:id, :number, :base, :parent, :tiles, :numbers, :what, :palette_base, :palettes,
                            :first_palette) do
            # The number its tiles take up to, past every room it carries.
            def reach = base + tiles.length

            # The number its palettes take up to, past every room it carries.
            def palette_reach = palette_base + palettes.length

            # The rooms whose tiles it brings in, its parent's first.
            def chain = parent ? [*parent.chain, self] : [self]

            # The palette it or a room it carries puts first, nil for none yet.
            def first_palette_in_chain = first_palette || parent&.first_palette_in_chain

            # Every palette of its own and of the rooms it carries, [number, Art::BackgroundPalette]
            # each, its parent's first.
            def chain_palettes
              chain.flat_map { |link| link.palettes.each_with_index.map { |palette, i| [link.palette_base + i, palette] } }
            end

            # Whether it brings anything in: tiles, or colours.
            def brings_in? = chain.any? { |link| link.tiles.any? || link.palettes.any? || link.first_palette }
          end

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
          # +room_colors+ says each screen brings its own palettes in with its tiles
          # (TooManyBackgroundLists).
          def initialize(square_colors: nil, lends: false, grouped: {}, room_colors: false)
            @square_colors = square_colors
            @lends = lends
            @grouped = grouped
            @room_colors = room_colors
            @lent_family = nil # a lent list's number -> its family's, once every sprite is known (#lent_family)
            @shared_palettes = nil # how many palettes every screen keeps, once rooms are planned
            @first_free = false # ...and whether the first of them is black alone, a room's to take
            @rooms = [] # the Rooms the runtime brings in, by their number less one
            @all_rooms = [] # ...and every Room, the ones only carried by another too
            @shared_tiles = nil # how many tiles every screen keeps, once rooms are planned
            @grouped_tiles = {} # a grouped picture's name -> its own tiles, 16 bytes each
            @sprite_tiles = []        # 16 bytes each
            @sprite_tile_numbers = {} # bytes -> [number, flips]
            @sprite_pictures = {}     # picture name -> SpritePicture
            @sprite_palettes = []     # lists of four colours
            @background_tiles = []
            @background_tile_numbers = {}
            @background_palettes = []
            @black_held = false # the first palette is black alone, until one that can be first comes
            @background_tile_of = {} # [room, picture name, its recolour steps] -> [tile number, palette number]
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

          # The lists sprite +wearer+ (the object's name) can wear, by their numbers, for #lent_family.
          def note_lists_worn(wearer, palettes)
            @lists_worn ||= Hash.new { |all, name| all[name] = [] }
            @lists_worn[wearer] |= palettes
          end

          # LISTS ONE SPRITE WEARS BY TURNS, AND NO OTHER SPRITE EVER DOES — the lists of its
          # `draw_with`, in each of its poses — are a FAMILY, numbered from 1. A sprite stepping
          # through them a frame at a time (a fade done with lists) takes the one of the eight its
          # family held the frame before, rather than waiting for a list nothing wore for a whole
          # frame (Runtime::Picture#emit_lend_colors). Since no other sprite wears the family's lists,
          # the one it takes was its own, and no sprite placed later in the pass loses its colours.
          # A list two sprites can wear — a pool's things, two sprites of one picture — is in no
          # family. Each sprite is a family, so there are never more than MOST_LENT, a byte's worth
          # with nought left for none. A lent list's number -> its family's.
          def lent_family
            @lent_family ||= begin
              wearers = Hash.new(0)
              (@lists_worn || {}).each_value { |lists| lists.each { |number| wearers[number] += 1 } }
              own = (@lists_worn || {}).values.map { |lists| lists.select { |number| wearers[number] == 1 } }
              own.select { |lists| lists.length > 1 }.each_with_index.each_with_object({}) do |(lists, i), family|
                lists.each { |number| family[number] = i + 1 }
              end
            end
          end

          # Has any sprite lists of its own to step through (#lent_family)?
          def lent_families? = lends? && lent_family.any?

          # Do the screens bring their own background palettes in with their tiles?
          def room_colors? = @room_colors

          # Does each room put its own palette first, every screen's first being black alone
          # (#keep_art_asked_so_far)? Then every room, one of nothing included, puts it in as it
          # comes up (Lowering::Picture#plan_rooms_for_bare_scenes).
          def first_palette_per_room? = room_colors? && @first_free

          # Has the game pictures grouped by room, copied in as a room comes up (Runtime::PictureGroups)?
          def groups? = !@grouped.empty?

          # EVERY SET OF PICTURE GROUPS' ROOM IN SPRITE MEMORY, one after another past the tiles every
          # screen keeps, once every picture is known. A set's grouped pictures share its room as
          # their groups allow (IR::PictureGroupPlaces), counted in tiles; each set has a room of its
          # own, so a scene given the screen back finds its groups' pictures where it left them.
          # They are kept by the name of their set.
          def group_rooms
            @group_rooms ||= begin
              first = @sprite_tiles.length
              by_set = @grouped_tiles.keys.group_by { |name| @grouped.fetch(name).name }
              @grouped.values.uniq(&:name).each_with_index.to_h do |set, number|
                pictures = by_set.fetch(set.name, [])
                placed = pictures.map do |name|
                  IR::PictureGroupPlaces::Picture.new(key: name, units: @grouped_tiles[name].length, even_start: false,
                                                      groups: set.groups_holding(name))
                end
                room = GroupRoom.new(set: set, number: number, first_tile: first, pictures: pictures,
                                     places: IR::PictureGroupPlaces.new(placed, together: set.together))
                first += room.places.units
                [set.name, room]
              end
            end
          end

          # The number of a sprite's tile in sprite memory, a grouped picture's in its set's room.
          def tile_number(tile)
            return tile unless tile.is_a?(GroupedTile)

            room = group_rooms.fetch(@grouped.fetch(tile.picture).name)
            room.first_tile + room.places.offset(tile.picture) + tile.index
          end

          # The palettes the game can show, by the console's numbers: the backgrounds' from 0 — the
          # first always, since its first colour is the backdrop — the painted screen's, and the
          # sprites' from 8, all eight of those when they are lent. A screen's own palettes count up to
          # the most any screen reaches.
          def palettes_in_use
            reach = [@background_palettes.length, 1, *@all_rooms.map(&:palette_reach)].max
            backgrounds = (0...reach).to_a
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

          # --- rooms: the tiles a screen brings in (TooManyBackgroundTiles) ---

          # The Rooms the runtime brings in, in the order of their numbers.
          attr_reader :rooms

          # Whether the tiles every screen keeps are settled, so the rest go in rooms.
          def shared_tiles_settled? = !@shared_tiles.nil?

          # Keep the tiles every screen keeps: those asked for so far. Every tile asked for after
          # this is asked for in a room. In a game whose screens bring their colours in, the palettes
          # every screen keeps are settled too; where none of them can be first, the first is black
          # alone, and each room puts a palette of its own there (#room_palette_number).
          def keep_art_asked_so_far
            @shared_tiles = @background_tiles.length
            return unless room_colors?

            @first_free = @black_held || @background_palettes.empty?
            @background_palettes << black_alone if @background_palettes.empty?
            @shared_palettes = @background_palettes.length
          end

          # A room for the tiles +what+ brings in (see Room), numbered from +base+: from its parent's
          # last, or past the tiles every screen keeps. +brought_in+ says the runtime brings it in by
          # a number of its own; a scene's tiles carried by its areas' rooms are not. Its palettes are
          # numbered the same way.
          def add_room(what, parent: nil, base: nil, brought_in: true)
            base ||= parent ? parent.reach : @shared_tiles
            refuse_too_many_rooms! if brought_in
            made = Room.new(id: @all_rooms.length, number: brought_in ? @rooms.length + 1 : nil, base: base,
                            parent: parent, tiles: [], numbers: {}, what: what, palettes: [],
                            palette_base: parent ? parent.palette_reach : @background_palettes.length)
            @rooms << made if brought_in
            @all_rooms << made
            made
          end

          # The most rooms the runtime brings in by number: it finds a room's list by a word a room,
          # its number doubled in a byte (Runtime::Picture#emit_rooms).
          MOST_ROOMS = 127

          def refuse_too_many_rooms!
            return if @rooms.length < MOST_ROOMS

            raise LoweringError, "this game has more than #{MOST_ROOMS} scenes and areas that bring their own tiles in, " \
                                 "and a Game Boy Color build brings in #{MOST_ROOMS}. To fix this, use fewer scenes " \
                                 "or areas with tiles of their own."
          end

          # The tile number and palette number a background's tile picture +name+ is drawn with, as
          # +room+ numbers it: one every screen keeps where there is one the same, or else the room's
          # own. Without a room, in the tiles every screen keeps. +recolor_steps+ is nil where the
          # background showing it is never drawn with other lists of colours; for one that is, the
          # colours its palette shows with each of that background's lists
          # (Lowering::Picture#recolor_steps_of), which write into its palette. So two tiles that
          # show the same colours but change differently have palettes of their own, and so does one
          # tile shown by two backgrounds that change it differently: its picture is kept once, and
          # each background's cells name their own palette. +empty_cells_shown+ says an empty cell can
          # show while its palette is in (Lowering::Picture#empty_cells_shown_with?); where none can,
          # the palette of a tile drawn with other lists can be the first, whatever its first colour
          # (#background_palette_number). Others keep to black first, as they always have.
          def background_tile(name, image, room: nil, recolor_steps: nil, empty_cells_shown: true)
            @background_tile_of[[room&.id, name, recolor_steps]] ||= begin
              unless image.width == 8 && image.height == 8
                raise LoweringError, "the tile #{name.inspect} is #{image.width}×#{image.height}; the Game Boy Color " \
                                     "build makes 8×8 tiles only so far."
              end

              drawing = TileDrawing.new(room: room, recolor_steps: recolor_steps, any_first: !empty_cells_shown && !recolor_steps.nil?)
              order = list_order(image)
              placed = recolor_steps && !order && drawn_places(image)
              if order then listed_tile(image, order, drawing)
              elsif placed then placed_tile(image, placed, drawing)
              else drawn_tile(name, image, drawing)
              end
            end
          end

          # How a background tile is drawn, past its picture: the Room it is numbered in (nil for the
          # tiles every screen keeps), the colours it shows with each list it is drawn with (nil for
          # none), and whether its palette can be the first whatever its first colour, on screens
          # where no empty cell shows (#background_tile).
          TileDrawing = Data.define(:room, :recolor_steps, :any_first)

          # A BACKGROUND PALETTE: its four colours, and for one a background draws with other lists,
          # the four it shows with each of them (see #background_tile). Two palettes are the same
          # only when both are.
          BackgroundPalette = Data.define(:colors, :swaps)

          # A TILE DRAWN BY PLACE that #list_order does not take — one with see-through pixels, or
          # from a list of more than four colours — for one a background draws with other lists.
          # Another list drawn over it swaps it place for place, so a list holding one colour at two
          # of its places shows two colours then; drawn by its colours, the two would be one colour of
          # its palette. So each place it draws is a colour of its palette of its own: after the
          # backdrop, where it has see-through pixels, or all four of them where it has none. The
          # places it draws, in the order its palette holds them; nil for a tile that is not given by
          # places, or that draws more places than its palette holds.
          def drawn_places(image)
            return nil unless image.places && image.colors

            drawn = (0...64).reject { |i| image.tile_see_through_at?(i) }.map { |i| image.place_at(i) }.uniq.sort
            drawn if drawn.length <= (see_through_tile?(image) ? OWN_COLORS : PLACES)
          end

          # The four colours a tile drawn by its places +placed+ (#drawn_places) shows when each
          # place shows the colour the block gives it: the backdrop first where the tile has
          # see-through pixels, which show it.
          def placed_colors(image, placed)
            shown = placed.map { |place| yield(place) & 0x7FFF }
            padded(see_through_tile?(image) ? [BACKDROP, *shown] : shown)
          end

          def see_through_tile?(image) = (0...64).any? { |i| image.tile_see_through_at?(i) }

          # The tile number and palette number of a tile drawn by the places it draws (#drawn_places):
          # each pixel is its place's position in the palette (#placed_colors). Another list drawn
          # over one without see-through pixels writes its first colour too, so it cannot keep black
          # first.
          def placed_tile(image, placed, drawing)
            see_through = see_through_tile?(image)
            colors = placed_colors(image, placed) { |place| image.colors[place] }
            places = Array.new(64) do |i|
              next 0 if image.tile_see_through_at?(i)

              placed.index(image.place_at(i)) + (see_through ? 1 : 0)
            end
            [tile_number_in(drawing.room, encode(places)), drawn_palette_number(colors, drawing, keeps_black: see_through)]
          end

          # A TILE DRAWN BY PLACE FROM A LIST OF FOUR, with no see-through pixel, the way a cartridge
          # made for the Color draws its screens: the list is its palette, all four colours of it,
          # and every tile from the same list shares that palette — so eight lists are the Color's
          # eight palettes. The backdrop has no place in it, since nothing of the tile shows
          # through. Its places, in the order the palette holds them; nil for a tile that is not
          # one (#drawn_tile).
          #
          # Black goes first when the list has it. An empty cell is written with the first palette,
          # here and in the game's code, and shows that palette's first colour — so a list that
          # starts with black can be the first palette (#background_palette_number).
          def list_order(image)
            list = image.colors
            return nil unless image.places && list && list.length.between?(2, PLACES + 1)
            return nil if (0...64).any? { |i| image.tile_see_through_at?(i) }

            places = (1...list.length).to_a
            black = places.find { |place| (list[place] & 0x7FFF) == BACKDROP }
            black ? [black, *(places - [black])] : places
          end

          # The tile number and palette number of a tile drawn from its list (#list_order): each
          # pixel is its place's position in +order+, and the palette is the list's colours in it.
          # Another list drawn over it writes its first colour too, so one drawn with other lists
          # cannot keep black first.
          def listed_tile(image, order, drawing)
            colors = padded(order.map { |place| image.colors[place] & 0x7FFF })
            [tile_number_in(drawing.room, encode(Array.new(64) { |i| order.index(image.place_at(i)) })),
             drawn_palette_number(colors, drawing, keeps_black: !drawing.recolor_steps)]
          end

          # The number of the palette of +colors+ a tile drawn as +drawing+ says is drawn from.
          def drawn_palette_number(colors, drawing, keeps_black: true)
            background_palette_number(colors, keeps_black: keeps_black, room: drawing.room, swaps: drawing.recolor_steps,
                                              any_first: drawing.any_first)
          end

          # A background palette's number. The first of them has to start with black, the colour an
          # empty cell shows (#list_order), and keep it while the game runs. A palette that cannot be
          # the first, made while there is none, is put after a palette of black alone, held for
          # the first palette after it that can: that one takes its place rather than a ninth.
          # +room+ is the one whose tiles it draws, in a game whose screens bring their colours in.
          # +swaps+ is what the palette shows with each list a background draws it with, nil for none.
          # +any_first+ says no empty cell shows while it is in, so whatever its first colour, it can
          # be the first.
          def background_palette_number(colors, keeps_black: true, room: nil, swaps: nil, any_first: false)
            can_be_first = any_first || (keeps_black && colors.first == BACKDROP)
            palette = BackgroundPalette.new(colors: colors, swaps: swaps)
            return room_palette_number(room, palette, can_be_first) if room && room_colors?
            return settled_palette_number(palette, can_be_first) if @shared_palettes

            found = kept_palette_number(palette, can_be_first)
            if found
              @black_held = false if found.zero?
              return found
            end
            if @black_held && can_be_first
              @black_held = false
              @background_palettes[0] = palette
              return 0
            end
            if @background_palettes.empty? && !can_be_first
              @background_palettes << black_alone
              @black_held = true
            end
            added_palette_number(@background_palettes, palette, "backgrounds")
          end

          # The number of a palette made already that every screen keeps, nil for none. The first
          # is the answer only for colours that can be first, and only while it is not black alone
          # held for a room's own (#keep_art_asked_so_far).
          def kept_palette_number(palette, can_be_first)
            found = @background_palettes.index(palette)
            found if found && (found.positive? || (can_be_first && !@first_free))
          end

          # A palette's number among those +room+ shows: one every screen keeps, one of its own or
          # a room's it carries, or a new one of its own after those. The first palette is its own
          # to put there where every screen's first is black alone (#keep_art_asked_so_far): the
          # first that can be first takes it, as the first palette of a game does.
          def room_palette_number(room, palette, can_be_first)
            first = room.first_palette_in_chain
            return 0 if first == palette && can_be_first

            kept = kept_palette_number(palette, can_be_first)
            return kept if kept

            own = room.chain_palettes.find { |_, listed| listed == palette }
            return own.first if own
            if @first_free && first.nil? && can_be_first
              room.first_palette = palette
              return 0
            end
            refuse_too_many_room_palettes!(room)
            room.palettes << palette
            room.palette_reach - 1
          end

          def refuse_too_many_room_palettes!(room)
            most = most_background_palettes
            return if room.palette_reach < most

            beside = painting? ? " beside a painted screen" : ""
            raise LoweringError, "the backgrounds of #{room.what} need more than #{most} lists of colours, with the " \
                                 "lists that every scene shares. A Game Boy Color holds #{most}#{beside} at one " \
                                 "time. To fix this, draw more of them from the same colours."
          end

          # A palette every screen keeps, asked for once the rooms are planned. Every one is made
          # before the rooms are, since a room's are numbered past them.
          def settled_palette_number(palette, can_be_first)
            kept_palette_number(palette, can_be_first) ||
              raise(LoweringError, "the Game Boy Color build asked for a new list of colours for every screen after " \
                                   "it numbered each screen's own. This is a fault in the build, not in the game.")
          end

          # How many palettes the backgrounds have: the eight, less the painted screen's.
          def most_background_palettes = painting? ? PALETTES - painted_palettes.length : PALETTES

          # The palette of black alone, where an empty cell is drawn from while nothing else is first.
          def black_alone = BackgroundPalette.new(colors: padded([BACKDROP]), swaps: nil)

          # A tile drawn any other way — from colours, or from a list with a see-through place or
          # more than four colours: three colours of its own after the backdrop, in the order it
          # first draws them, which its see-through pixels show.
          def drawn_tile(name, image, drawing)
            drawn = tile_colors(image)
            if drawn.size > OWN_COLORS
              raise LoweringError, "the tile #{name.inspect} has #{drawn.size} colours, and a Game Boy Color tile holds " \
                                   "#{OWN_COLORS} and the backdrop. To fix this, draw it in #{OWN_COLORS} colours."
            end

            colors = [BACKDROP, *drawn]
            places = Array.new(64) { |i| image.tile_see_through_at?(i) ? 0 : drawn.index(image.color_at(i) & 0x7FFF) + 1 }
            [tile_number_in(drawing.room, encode(places)), drawn_palette_number(padded(colors), drawing)]
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
               background_palette_number(padded([BACKDROP, *own]))]
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
          # Linker::TooBig). The tables in the part always in view hold every list of colours and where
          # each sprite picture's pieces and outline are; those are kept in the banks, a section a
          # picture, under the same name. Sprite pictures are what grow both.
          SPRITE_PICTURES = SM83::Holding.new(what: "the game's sprite pictures", fix: "use fewer or smaller sprite pictures")
          PICTURE_TABLES = SM83::Holding.new(what: "the colours and outlines of the game's pictures",
                                             fix: "use fewer or smaller sprite pictures")
          BACKGROUND_TILES = SM83::Holding.new(what: "the game's background tiles",
                                               fix: "use fewer different tiles in its backgrounds")
          BACKGROUND_MAPS = SM83::Holding.new(what: "the game's background maps",
                                              fix: "make its background maps smaller, or use fewer of them")

          # The sections the art is kept in: the tiles, the grids and each sprite picture's pieces
          # and mask in banks (each read with its bank put in view), and the palettes and where
          # each of the others is in the part always in view.
          def sections
            refuse_too_many_tiles!
            [tables_section,
             *@sprite_pictures.each_value.map { |picture| picture_section(picture) },
             data_section("art sprite tiles", "art_sprite_tiles", @sprite_tiles.flatten, holds: SPRITE_PICTURES),
             *group_rooms.each_value.map { |room| group_tiles_section(room) },
             data_section("art background tiles", "art_background_tiles", @background_tiles.flatten,
                          holds: BACKGROUND_TILES),
             *@all_rooms.flat_map do |room|
               room_chunks(room).map { |chunk| data_section(chunk.label, chunk.label, chunk.tiles.flatten, holds: BACKGROUND_TILES) }
             end,
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
            backgrounds = @background_palettes.map(&:colors)
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
              if lent_families?
                asm.label("art_lent_families")
                asm.data_bytes(@sprite_palettes.each_index.map { |number| lent_family.fetch(number, 0) })
              end
            end
            # Where each sprite picture's pieces and mask are, and the bank each is in (#picture_section).
            pictures = @sprite_pictures.values
            asm.label("art_pictures")
            pictures.each do |picture|
              asm.data_words("art_pieces_#{picture.number}")
              asm.data_bank_of("art_pieces_#{picture.number}")
            end
            asm.label("art_masks")
            pictures.each do |picture|
              asm.data_words("art_mask_#{picture.number}")
              asm.data_bank_of("art_mask_#{picture.number}")
            end
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
            group_rooms.each_value { |room| emit_group_tables(asm, room) }
            emit_room_tables(asm) unless @rooms.empty?
            asm.section
          end

          # Where each Room's tiles are, as Runtime::Picture#emit_rooms reads them: a word for each
          # room, by its number, saying where its list is; then each list, a chunk to an entry —
          # how many tiles, where they are in the cartridge and in which bank, which bank of picture
          # memory they go to and where — its parents' chunks first, and nought after the last.
          def emit_room_tables(asm)
            asm.label("art_rooms")
            @rooms.each { |room| asm.data_words("art_room_list_#{room.number}") }
            @rooms.each do |room|
              asm.label("art_room_list_#{room.number}")
              room.chain.each do |link|
                room_chunks(link).each do |chunk|
                  asm.data_bytes(chunk.tiles.length)
                  asm.data_words(chunk.label)
                  asm.data_bank_of(chunk.label)
                  asm.data_bytes(chunk.bank)
                  asm.data_words(chunk.to)
                end
              end
              asm.data_bytes(0)
            end
            emit_room_colors(asm) if room_colors?
          end

          # The palettes each Room brings in, as rt_background_colors reads a list of them: a word
          # for each room, by its number, saying where its list is; then each list — how many
          # palettes, then each one's number and its four colours — its parents' first. Where every
          # screen's first palette is black alone, each list puts its own first, or black alone again
          # over the one another room put there.
          def emit_room_colors(asm)
            asm.label("art_room_colors")
            @rooms.each { |room| asm.data_words("art_room_colors_#{room.number}") }
            @rooms.each do |room|
              asm.label("art_room_colors_#{room.number}")
              listed = room.chain_palettes
              listed.unshift([0, room.first_palette_in_chain || black_alone]) if @first_free
              asm.data_bytes(listed.length)
              listed.each do |number, palette|
                asm.data_bytes(number)
                asm.data_words(palette.colors)
              end
            end
          end

          # A SPRITE PICTURE'S PIECES AND MASK, in a bank of the cartridge rather than the part always
          # in view: four bytes a piece and a bit a pixel come to more than its tiles' own share of
          # that part for a big picture, so a game of many rooms would fill it long before the
          # pictures' tiles fill their banks. The runtime
          # puts the bank in view while it reads them (rt_sprite, rt_pixels_overlap).
          def picture_section(picture)
            asm = SM83.new("art picture #{picture.number}", home: :banked, holds: PICTURE_TABLES)
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
              Runtime::PictureGroups.emit_group(asm, chunks: chunks.length, list: "art_group_#{room.number}_list_#{number}")
            end
            lists.each_with_index do |chunks, number|
              asm.label("art_group_#{room.number}_list_#{number}")
              chunks.each do |chunk|
                Runtime::PictureGroups.emit_chunk(asm, tiles: chunk.label, bank: chunk.bank, to: chunk.to,
                                                       count: chunk.tiles.length)
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
            rooms = group_rooms.each_value.sum { |room| room.places.units }
            if @sprite_tiles.length + rooms > MOST_SPRITE_TILES
              grouped = if rooms.zero? then ""
                        else
                          " The pictures in no group need #{@sprite_tiles.length} of them. The groups that can be " \
                            "up together need #{rooms}."
                        end
              raise LoweringError, "this game's sprites need #{@sprite_tiles.length + rooms} tiles of 8×8, and a Game " \
                                   "Boy Color has room for #{MOST_SPRITE_TILES}.#{grouped} To fix this, give it fewer " \
                                   "or smaller pictures."
            end
            most = painting? ? PAINTING_BACKGROUND_TILES : MOST_BACKGROUND_TILES
            beside = painting? ? " beside a painted screen" : ""
            full = @rooms.find { |room| room.reach > most }
            if full
              raise LoweringError, "the backgrounds of #{full.what} need #{full.reach} different tiles, with the tiles " \
                                   "that every scene shows. A Game Boy Color has room for #{most}#{beside} at one " \
                                   "time. To fix this, use fewer different tiles there."
            end
            return unless @background_tiles.length > most

            # Every tile in memory at once does not fit; tiles a screen brings in as it comes up may.
            error = shared_tiles_settled? ? LoweringError : TooManyBackgroundTiles
            raise error, "this game's backgrounds need #{@background_tiles.length} different tiles, and a Game " \
                         "Boy Color has room for #{most}#{beside} at one time. To fix this, use fewer different tiles. " \
                         "Or declare each background in the scene that shows it. Then each scene brings its own tiles in."
          end

          # A run of a room's tiles as the runtime copies it in (Runtime::Picture#emit_rooms): its label
          # in the cartridge, its tiles, and the bank of picture memory and the place they go. At most
          # 128 tiles, never across from one half of picture memory to the next.
          RoomChunk = Data.define(:label, :tiles, :bank, :to)

          # Each of +room+'s own tiles in chunks: a tile numbered +n+ is in bank n / 256 of picture
          # memory, the first 128 of a bank from 0x9000 and the rest from 0x8800, as the background's
          # cells count them (Runtime::Picture#emit_start).
          def room_chunks(room)
            @room_chunks ||= {}
            @room_chunks[room.id] ||= begin
              chunks = []
              at = 0
              while at < room.tiles.length
                tile = room.base + at
                count = [room.tiles.length - at, 128 - (tile % 128)].min
                half = tile / 128
                chunks << RoomChunk.new(label: "art_room_#{room.id}_#{chunks.length}", tiles: room.tiles[at, count],
                                        bank: half / 2, to: (half.even? ? 0x9000 : 0x8800) + ((tile % 128) * 16))
                at += count
              end
              chunks
            end
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

          # A tile's number in +room+ (see #background_tile).
          def tile_number_in(room, bytes)
            return background_tile_number(bytes) unless room

            kept = @background_tile_numbers[bytes]
            return kept if kept

            room.chain.each do |link|
              number = link.numbers[bytes]
              return number if number
            end
            room.numbers[bytes] = room.base + (room.tiles << bytes).length - 1
          end

          def padded(colors) = colors + ([BACKDROP] * (PLACES - colors.length))

          def palette_number(palettes, colors, kind) = palettes.index(colors) || added_palette_number(palettes, colors, kind)

          def added_palette_number(palettes, colors, kind)
            sprites = palettes.equal?(@sprite_palettes)
            most = if sprites then lends? ? MOST_LENT : PALETTES
                   else most_background_palettes
                   end
            if palettes.length == most
              raise TooManySpriteLists, "more lists" if sprites && !lends?
              raise TooManyBackgroundLists, "more lists" unless sprites || room_colors?

              scenes = if sprites then ""
                       else
                         " A tile that a background draws with other lists of colours needs a list of its own for " \
                           "each way it changes. Or declare each background in the scene that shows it. Then each " \
                           "scene brings its own colours in."
                       end
              raise LoweringError, "this game's #{kind} need more than the #{most} lists of colours a Game Boy Color " \
                                   "#{sprites ? 'build keeps' : 'holds'} for them. To fix this, draw more of them " \
                                   "from the same colours.#{scenes}"
            end

            (palettes << colors).length - 1
          end
        end
      end
    end
  end
end
