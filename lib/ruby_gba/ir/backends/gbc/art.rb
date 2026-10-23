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

          # A game with a painted screen gives it the background's last palette and the tiles past
          # the first 128 (Runtime::Paint), so its tiled screens have the rest.
          PAINTING_PALETTES = PALETTES - 1
          PAINTING_BACKGROUND_TILES = 128

          attr_reader :sprite_tiles, :sprite_palettes, :background_tiles, :background_palettes, :grids, :paint_colors

          # +paint_colors+ are the colours a game paints a screen in, black first (nil for a game
          # that paints no screen).
          def initialize(paint_colors: nil)
            @paint_colors = paint_colors
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

          def painting? = !@paint_colors.nil?

          # The place a painted colour is kept at in the painted screen's palette.
          def paint_place(color)
            @paint_colors.index(color & 0x7FFF) or raise LoweringError, "the colour #{color} is not among the painted ones"
          end

          # --- sprites ---

          # The picture +name+ (an Assets::Image) as a sprite shows it: cut into pieces whose tiles
          # are kept once each. +colors+ is the picture's own list by place, see-through first.
          def sprite_picture(name, image)
            @sprite_pictures[name] ||= begin
              if image.width > LARGEST_SPRITE || image.height > LARGEST_SPRITE
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

                  tile, flips = sprite_tile(piece)
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
             data_section("art background tiles", "art_background_tiles", @background_tiles.flatten,
                          holds: BACKGROUND_TILES),
             *@grids.each_with_index.map do |bytes, i|
               data_section("art grid #{i}", "art_grid_#{i}", bytes, holds: BACKGROUND_MAPS)
             end,
             *@big_maps.each_with_index.flat_map do |(bytes, cols, _), i|
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
            backgrounds[PAINTING_PALETTES] = padded(@paint_colors) if painting?
            [backgrounds, @sprite_palettes].each do |palettes|
              PALETTES.times do |i|
                colors = palettes[i] || Array.new(PLACES, BACKDROP)
                asm.data_words(colors)
              end
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
            @big_maps.each_with_index do |(_, _, rows), i|
              asm.label("art_big_rows_#{i}")
              rows.times do |r|
                asm.data_words("art_big_map_#{i}_#{r}")
                asm.data_bank_of("art_big_map_#{i}_#{r}")
              end
            end
            pictures.each do |picture|
              asm.label("art_pieces_#{picture.number}")
              asm.data_bytes(picture.pieces.length)
              picture.pieces.each do |piece|
                bank = piece.tile / 128
                asm.data_bytes(piece.dx, piece.dy, piece.tile % 128,
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
            if @sprite_tiles.length > MOST_SPRITE_TILES
              raise LoweringError, "this game's sprites need #{@sprite_tiles.length} tiles of 8×8, and a Game Boy " \
                                   "Color has room for #{MOST_SPRITE_TILES}. To fix this, give it fewer or smaller pictures."
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
            h = Console::GBCHardware
            turned = { 0 => places, h::OBJ_X_FLIP => mirrored(places), h::OBJ_Y_FLIP => upside_down(places),
                       h::OBJ_X_FLIP | h::OBJ_Y_FLIP => upside_down(mirrored(places)) }
            turned.each do |flips, version|
              number = @sprite_tile_numbers[encode(version)]
              return [number, flips] if number
            end
            bytes = encode(places)
            @sprite_tile_numbers[bytes] = (@sprite_tiles << bytes).length - 1
            [@sprite_tile_numbers[bytes], 0]
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

            most = painting? && palettes.equal?(@background_palettes) ? PAINTING_PALETTES : PALETTES
            if palettes.length == most
              raise LoweringError, "this game's #{kind} need more than the #{most} lists of colours a Game Boy Color " \
                                   "holds for them. To fix this, draw more of them from the same colours."
            end

            (palettes << colors).length - 1
          end
        end
      end
    end
  end
end
