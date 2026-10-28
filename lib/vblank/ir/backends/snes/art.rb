# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # A GAME'S PICTURES, MADE INTO WHAT A SUPER NINTENDO DRAWS FROM, while the program is built.
        #
        # The Super Nintendo draws everything from TILES: 8×8 pictures in which each pixel is a
        # number, here four bits — one of sixteen places in a list of colours (a PALETTE). A tile
        # is kept as four BITPLANES: for each row, a byte holding bit 0 of each of its eight
        # pixels, then a byte holding bit 1, and after all eight rows the same again for bits 2 and
        # 3 — 32 bytes a tile. A background is a grid of cells (a MAP), each naming a tile and one of
        # eight palettes for it; a sprite is a tile placed anywhere, drawn from one of eight palettes
        # of its own. Place 0 of every palette is see-through, and where nothing is drawn the screen
        # shows colour 0 of the first palette, the BACKDROP, black as the interpreter's empty
        # screen is.
        #
        # So a picture the game declared is cut into 8×8 pieces, each piece's pixels written as
        # places in a palette of fifteen colours, and the palettes the game's pictures need gathered
        # into the console's colour memory (CGRAM): 128 colours for the backgrounds, then 128 for
        # the sprites. What cannot fit — more colours than the palettes hold, more tiles than video
        # memory has room for — is refused here with plain words.
        class Art
          # A palette's places, and how many hold a colour of the picture's own: place 0 is
          # see-through.
          PLACES = 16
          OWN_COLORS = PLACES - 1
          PALETTES = 8

          # How many tiles there is room for in video memory (see Runtime::Picture for the layout):
          # 1024 for the backgrounds and 512 for the sprites.
          MOST_BACKGROUND_TILES = 1024
          MOST_SPRITE_TILES = 512

          TILE_BYTES = 32

          # A tile number and attributes as a cell of a map holds them: the tile in the low ten
          # bits, the palette in the next three.
          PALETTE_SHIFT = 10

          # A sprite's picture, cut into 8×8 pieces: each piece where it sits in the picture, its
          # tile and its palette. +number+ is what the runtime knows it by.
          Piece = Data.define(:dx, :dy, :tile, :palette)
          SpritePicture = Data.define(:name, :number, :width, :height, :pieces)

          # A grid of map cells, as the console's video memory holds it: +columns+ and +rows+ of
          # 32 or 64, and the bytes, two a cell, laid out in screens of 32×32 cells — the left top
          # screen, then the right one, then the two below — as the console reads a map wider or
          # taller than one screen.
          Grid = Data.define(:number, :columns, :rows, :bytes) do
            # The size bits of a background's map register (BGnSC): one screen, two across, two
            # down or four.
            def size_bits = (columns == 64 ? 1 : 0) | (rows == 64 ? 2 : 0)
          end

          # Raised for art the console cannot hold.
          class TooMuch < LoweringError; end

          attr_reader :background_tiles, :sprite_tiles, :grids, :sprite_pictures

          def initialize
            @background_tiles = [blank_tile] # tile 0: nothing drawn, for an empty cell
            @background_tile_numbers = { blank_tile => 0 }
            @background_palettes = [[]] # each a list of up to fifteen colours
            @sprite_tiles = []
            @sprite_tile_numbers = {}
            @sprite_palettes = []
            @sprite_pictures = {}
            @grids = []
          end

          # --- backgrounds ---

          # The cell +image+ (an Assets::Image of 8×8) makes in a map: its tile number and its
          # palette, as two numbers.
          def background_cell(image)
            drawn = (0...64).reject { |at| image.tile_see_through_at?(at) }
            palette = palette_for(@background_palettes, drawn.map { |at| image.color_at(at) }.uniq, "backgrounds")
            places = Array.new(64) do |at|
              image.tile_see_through_at?(at) ? 0 : @background_palettes[palette].index(image.color_at(at)) + 1
            end
            bytes = tile_bytes(places)
            number = @background_tile_numbers[bytes] ||= begin
              refuse_too_many!(@background_tiles.length, MOST_BACKGROUND_TILES, "backgrounds")
              @background_tiles << bytes
              @background_tiles.length - 1
            end
            [number, palette]
          end

          # The map +cells+ ([tile, palette] or nil, by row and column) made into the console's grid
          # of +columns+ × +rows+ cells, and its number.
          def grid(cells, columns, rows)
            bytes = +"".b
            (rows / 32).times do |screen_row|
              (columns / 32).times do |screen_column|
                32.times do |row|
                  32.times do |column|
                    cell = cells.dig((screen_row * 32) + row, (screen_column * 32) + column)
                    word = cell ? cell[0] | (cell[1] << PALETTE_SHIFT) : 0
                    bytes << [word].pack("v")
                  end
                end
              end
            end
            @grids << Grid.new(number: @grids.length, columns: columns, rows: rows, bytes: bytes)
            @grids.last
          end

          # --- sprites ---

          # The sprite picture +name+ (an Assets::Image), cut into pieces. A picture whose width or
          # height is not a multiple of 8 has its last pieces' extra pixels left undrawn.
          def sprite_picture(name, image)
            @sprite_pictures[name] ||= begin
              drawn = (0...(image.width * image.height)).select { |at| image.drawn_at?(at) }
              palette = palette_for(@sprite_palettes, drawn.map { |at| image.color_at(at) }.uniq, "sprites")
              pieces = (0...((image.height + 7) / 8)).flat_map do |down|
                (0...((image.width + 7) / 8)).filter_map do |across|
                  places = Array.new(64) do |at|
                    x = (across * 8) + (at % 8)
                    y = (down * 8) + (at / 8)
                    i = (y * image.width) + x
                    next 0 if x >= image.width || y >= image.height || !image.drawn_at?(i)

                    @sprite_palettes[palette].index(image.color_at(i)) + 1
                  end
                  next if places.all?(&:zero?) # a piece with nothing drawn is not placed at all

                  Piece.new(dx: across * 8, dy: down * 8, tile: sprite_tile_number(tile_bytes(places)), palette: palette)
                end
              end
              SpritePicture.new(name: name, number: @sprite_pictures.length, width: image.width, height: image.height,
                                pieces: pieces)
            end
          end

          # --- the colour memory ---

          # All 256 colours, as the console's colour memory holds them: two bytes each, the
          # backgrounds' eight palettes and then the sprites'.
          def cgram
            colors = Array.new(256, 0)
            @background_palettes.each_with_index { |list, p| list.each_with_index { |c, i| colors[(p * PLACES) + i + 1] = c } }
            @sprite_palettes.each_with_index { |list, p| list.each_with_index { |c, i| colors[128 + (p * PLACES) + i + 1] = c } }
            colors.pack("v*")
          end

          def sprite_tile_data = @sprite_tiles.join
          def background_tile_data = @background_tiles.join

          private

          def blank_tile = ("\0".b * TILE_BYTES)

          def sprite_tile_number(bytes)
            @sprite_tile_numbers[bytes] ||= begin
              refuse_too_many!(@sprite_tiles.length, MOST_SPRITE_TILES, "sprites")
              @sprite_tiles << bytes
              @sprite_tiles.length - 1
            end
          end

          # The palette of +palettes+ that holds every one of +colors+, adding them to one with
          # room where none does, or starting another. +what+ names whose palettes they are.
          def palette_for(palettes, colors, what)
            if colors.length > OWN_COLORS
              raise TooMuch, "A picture of the #{what} uses #{colors.length} colours, and a Super Nintendo tile shows " \
                             "#{OWN_COLORS} and see-through. To fix this, draw it in #{OWN_COLORS} colours or fewer."
            end

            found = palettes.index { |list| (colors - list).empty? }
            return found if found

            roomy = palettes.each_index.select { |p| (palettes[p] | colors).length <= OWN_COLORS }
                            .max_by { |p| (palettes[p] & colors).length }
            if roomy
              palettes[roomy] |= colors
              return roomy
            end
            if palettes.length >= PALETTES
              raise TooMuch, "The pictures of the #{what} use more colours than a Super Nintendo can show for them. " \
                             "It holds #{PALETTES} sets of #{OWN_COLORS} colours. To fix this, use fewer colours in " \
                             "the #{what}' pictures."
            end

            palettes << colors.dup
            palettes.length - 1
          end

          def refuse_too_many!(count, most, what)
            return if count < most

            raise TooMuch, "The #{what} use more different 8×8 squares of picture than a Super Nintendo has room " \
                           "for (#{most}). To fix this, use fewer different pictures."
          end

          # The 32 bytes of a tile whose 64 pixels are +places+ (0 to 15), row by row: each row's
          # bits 0 and 1 as two bytes, all eight rows, then bits 2 and 3 the same way. The leftmost
          # pixel is the top bit of each byte.
          def tile_bytes(places)
            low = +"".b
            high = +"".b
            8.times do |row|
              planes = Array.new(4) do |plane|
                (0...8).sum { |column| ((places[(row * 8) + column] >> plane) & 1) << (7 - column) }
              end
              low << planes[0].chr << planes[1].chr
              high << planes[2].chr << planes[3].chr
            end
            low + high
          end
        end
      end
    end
  end
end
