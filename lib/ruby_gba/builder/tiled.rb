# frozen_string_literal: true

module RubyGBA
  class Builder
    # Tiled backgrounds — the way most console games draw a level: not pixel by
    # pixel, but out of a small set of reusable little pictures ("tiles") stamped
    # onto a grid by a map. You define a tileset (which character means which tile
    # image) and a background (a map of those characters), and the framework paints
    # the grid for you.
    #
    #   image :brick, "#" => :gray  do <<~ART … ART end   # each tile is an image
    #   image :floor, "." => :black do <<~ART … ART end
    #   tiles :dungeon, "#" => :brick, "." => :floor       # the character -> tile map
    #   background :level, tiles: :dungeon, map: <<~MAP     # where each tile goes
    #     ##########
    #     #........#
    #     ##########
    #   MAP
    #
    # A tile is just an {#image}, so tiles are authored exactly like any other art
    # (ASCII, an array, or an imported picture) and the tileset only says which
    # character stands for which. All the console's tile machinery — where the tile
    # pictures live in video memory, the map layout, the background-control
    # registers — is managed for you and never appears here.
    #
    # For a level drawn in a map editor (like Tiled) and exported, you skip the
    # characters entirely: import the whole tile sheet as numbered tiles and hand the
    # background the editor's CSV export — a grid of those numbers — with `from:`.
    # See {#tiles} and {#background}.
    #
    # One `background` paints a single layer. Declare several and they stack — the
    # first is the backmost, each later one in front, composited by the tile hardware —
    # and each can be scrolled independently (scroll a near and a far layer at different
    # speeds for parallax). See {Background}.
    module Tiled
      # Define a tileset. Two ways to author it:
      #
      # 1. BY CHARACTER — a map from a character to the tile {#image} it stands for.
      #    The images must already be defined and must all be the same size (they form
      #    a uniform grid). The characters are the alphabet a `background` map is drawn
      #    with.
      #
      #      tiles :dungeon, "#" => :brick, "." => :floor
      #
      #    You can still import those tiles from a tile sheet — one image file holding
      #    the tiles in a grid — with `from:` (the file) and `tile:` (each tile's size
      #    in pixels); then each character points at a cell instead of a hand-drawn
      #    image: a cell number (counting left-to-right, top-to-bottom) or `[column,
      #    row]`.
      #
      #      tiles :dungeon, from: "dungeon.png", tile: 8, "#" => 0, "." => 1
      #
      # 2. BY NUMBER — import the WHOLE tile sheet with `from:` and `tile:` and NO
      #    characters. Every cell becomes a numbered tile: 1, 2, 3… left-to-right then
      #    top-to-bottom — the exact numbering a map editor like Tiled writes into a
      #    CSV export. A background over this tileset is authored as that CSV of
      #    numbers (see `background from:`), so there are no characters to name.
      #
      #      tiles :world, from: "world.png", tile: 8
      #
      # The file is found next to your script; `transparent: true` honors a cut-out
      # background.
      #
      # Add `solid:` to mark which tiles are walls a sprite can't move through — the
      # characters that block (`solid: ["#"]`, or one char `solid: "#"`), or, for a
      # numbered sheet, the tile numbers (`solid: [1, 2]`). A `background` built from
      # this tileset then knows where its walls are, so a sprite told to be
      # `blocked_by` it stops at them (see {HardwareSprite#blocked_by}).
      #
      # @param name [Symbol] the tileset's name, referenced by `background(tiles:)`
      # @param char_map [Hash] one entry per tile: character => image name, or (with
      #   `from:`) character => cell — or empty with `from:` to import the whole sheet
      #   as numbered tiles. Options `from:`/`tile:`/`transparent:`/`solid:`.
      def tiles(name, char_map)
        char_map = char_map.dup
        solid = Array(char_map.delete(:solid)) # tiles that block movement: characters, or sheet tile numbers
        from = char_map.delete(:from)          # a tile sheet to import the tiles from, if any
        tile = char_map.delete(:tile)          # each tile's size in that sheet
        transparent = char_map.delete(:transparent) { false }

        # A sheet with no character map: import EVERY cell as a numbered tile, ready
        # for a CSV map that picks tiles by number.
        return define_sheet_tileset(name, from, tile, transparent, solid) if from && char_map.empty?

        raise ArgumentError, "tiles :#{name} needs at least one character => tile mapping" if char_map.empty?

        # With `from:`, each character named a cell; import those cells into images so
        # the rest of this method sees the same character => image-name map as inline.
        char_map = import_tile_cells(name, from, tile, transparent, char_map) if from

        unknown = solid.reject { |ch| char_map.key?(ch) }
        unless unknown.empty?
          raise ArgumentError,
                "tiles :#{name}: solid #{unknown.map(&:inspect).join(', ')} " \
                "#{unknown.one? ? 'is' : 'are'} not in the tileset. Mark as solid only its tiles: " \
                "#{char_map.keys.map(&:inspect).join(', ')}."
        end

        sizes = char_map.map do |ch, img|
          @images[img] || raise(ArgumentError,
                                 "tiles :#{name}: tile #{ch.inspect} => :#{img} is not a defined image. " \
                                 "Define it first with `image :#{img}, ...`.")
        end
        unless sizes.uniq.size == 1
          raise ArgumentError,
                "tiles :#{name}: all tiles must be the same size. They form a uniform grid. " \
                "These sizes are different: #{sizes.uniq.map { |w, h| "#{w}x#{h}" }.join(', ')}."
        end

        # Number the tiles 1, 2, 3… in the order they're listed, so this same tileset
        # can also be drawn from a CSV map of numbers (not only from characters).
        by_number = char_map.values.each_with_index.to_h { |img, i| [i + 1, img] }
        @tilesets[name] = { chars: char_map.dup, by_number: by_number,
                            tile_w: sizes.first[0], tile_h: sizes.first[1],
                            solid_images: solid.map { |ch| char_map[ch] }.uniq }
      end

      # Paint a tiled background: a tileset plus a map of which tile goes in each grid
      # cell. Author the map two ways:
      #
      # - `map:` — a block of tileset characters, one character per cell, rows
      #   separated by newlines (a heredoc reads most like the picture), or an array
      #   of row strings. Each character is stamped as its tile; a space leaves the
      #   cell empty (the background shows through).
      #
      #     background :level, tiles: :dungeon, map: <<~MAP
      #       ##########
      #       #........#
      #       ##########
      #     MAP
      #
      # - `from:` — a CSV tilemap exported from a map editor like Tiled: a grid of
      #   tile numbers (the numbering `tiles from:` gives an imported sheet), one row
      #   per line. A `0` leaves the cell empty. The file is found next to your script.
      #
      #     background :level, tiles: :world, from: "level.csv"
      #
      # Returns a {Background} handle you can scroll (`world.scroll_by dx, dy`).
      #
      # @param name [Symbol] the background's name
      # @param tiles [Symbol] a tileset defined with {#tiles}
      # @param map [String, Array<String>, nil] the grid of tile characters
      # @param from [String, nil] path to a CSV tilemap (a grid of tile numbers)
      # @return [Background] a handle: scroll_by / scroll_to
      def background(name, tiles:, map: nil, from: nil)
        set = @tilesets[tiles] || raise(ArgumentError,
                                        "background :#{name}: there is no tileset named :#{tiles}. " \
                                        "Define one first with `tiles :#{tiles}, ...`.")

        img_rows, tile_names = background_image_grid(name, tiles, set, map: map, from: from)

        # Number the distinct tiles, then turn the grid of tile images into a grid of
        # those numbers — nil where a cell is blank. The grid, not a pile of draw calls,
        # is what the background node carries, so a backend is free to stamp it pixel by
        # pixel or hand it to tile hardware.
        index_of = tile_names.each_with_index.to_h
        grid = img_rows.map { |row| row.map { |img| img && index_of[img] } }

        record(Build.background(name, tiles: tile_names, map: grid,
                                      tile_w: set[:tile_w], tile_h: set[:tile_h]))

        # The window's top-left, in pixels, tracked in two hidden variables (cleared at
        # boot since console RAM isn't zero at power-on). A background that never
        # scrolls simply leaves them at 0.
        scroll_x = :"__bg_#{name}_sx"
        scroll_y = :"__bg_#{name}_sy"
        [scroll_x, scroll_y].each { |var| at_boot(Build.set(var, Build.int(0))); ensure_var(var) }
        Background.new(self, name: name, scroll_x: scroll_x, scroll_y: scroll_y,
                             walls: wall_rects(img_rows, set))
      end

      private

      # Import a tileset from a sheet by CHARACTER: slice the file into cells of the
      # given size and define the cell each character points at as an image, returning
      # the character => image-name map the tileset is built from. Each character's
      # value is a cell number or [column, row]. The internal image names are unique
      # per tileset.
      def import_tile_cells(name, path, tile, transparent, cells)
        tile_w, tile_h = sheet_tile_size("tiles :#{name}", tile)
        sheet = Image.slice(resolve_asset_path(path), tile_w: tile_w, tile_h: tile_h, transparent: transparent)
        cells.each_with_index.each_with_object({}) do |((char, where), idx), out|
          col, row = sheet_cell_at("tiles :#{name} tile #{char.inspect}", where, sheet.cols)
          bmp = sheet.cell(col, row)
          img = :"__tile_#{name}_#{idx}"
          define_pixel_image(img, width: bmp.width, height: bmp.height, data: bmp.data,
                                  transparent: bmp.transparent)
          out[char] = img
        end
      end

      # Import a whole tile sheet as numbered tiles: slice the file into cells and make
      # cell (col, row) tile number `row*cols + col + 1` — 1-based, left-to-right then
      # top-to-bottom, the exact order a map editor like Tiled numbers a sheet (so its
      # CSV export lines up). `solid:` here is a list of those tile numbers. There are
      # no characters — a background over this tileset is authored as a CSV of numbers.
      def define_sheet_tileset(name, path, tile, transparent, solid_numbers)
        tile_w, tile_h = sheet_tile_size("tiles :#{name}", tile)
        sheet = Image.slice(resolve_asset_path(path), tile_w: tile_w, tile_h: tile_h, transparent: transparent)

        by_number = {}
        sheet.rows.times do |row|
          sheet.cols.times do |col|
            number = (row * sheet.cols) + col + 1
            bmp = sheet.cell(col, row)
            img = :"__tile_#{name}_#{number}"
            define_pixel_image(img, width: bmp.width, height: bmp.height, data: bmp.data,
                                    transparent: bmp.transparent)
            by_number[number] = img
          end
        end

        unknown = solid_numbers.reject { |n| by_number.key?(n) }
        unless unknown.empty?
          raise ArgumentError,
                "tiles :#{name}: solid #{unknown.map(&:inspect).join(', ')} " \
                "#{unknown.one? ? 'is' : 'are'} not a tile number in the sheet. " \
                "The sheet holds tiles #{by_number.keys.min}..#{by_number.keys.max}."
        end

        @tilesets[name] = { chars: {}, by_number: by_number, tile_w: tile_w, tile_h: tile_h,
                            solid_images: solid_numbers.map { |n| by_number[n] }.uniq }
      end

      # The background's cells as a grid of tile-image names (nil = blank), plus the
      # list of distinct tile images in a stable order. Author the grid with `map:` (a
      # block of tileset characters) or `from:` (a CSV tilemap of tile numbers) — one
      # or the other, never both.
      def background_image_grid(name, tiles, set, map:, from:)
        if from
          raise ArgumentError, "background :#{name}: give it a map: or a from:, not both" if map

          csv_image_grid(name, tiles, set, from)
        elsif map
          char_image_grid(name, tiles, set, map)
        else
          raise ArgumentError,
                "background :#{name} needs a map: (a grid of tile characters) or a from: (a CSV tilemap file)"
        end
      end

      # Turn a character map into a grid of tile-image names. A space (or a character
      # not in the tileset — a friendly error) is the only surprise here.
      def char_image_grid(name, tiles, set, map)
        chars = set[:chars]
        if chars.empty?
          raise ArgumentError,
                "background :#{name}: tileset :#{tiles} was imported as numbered tiles, so it has no characters. " \
                "A character map: cannot select its tiles. " \
                "Write the map as a CSV of tile numbers and pass it with from: instead."
        end

        img_rows = background_rows(name, map).map do |row|
          row.each_char.map do |ch|
            next nil if ch == " " # a blank cell — leave the background showing through

            chars[ch] || raise(ArgumentError,
                               "background :#{name}: character #{ch.inspect} is not in tileset " \
                               ":#{tiles}. Its tiles are #{chars.keys.map(&:inspect).join(', ')}.")
          end
        end
        [img_rows, chars.values.uniq]
      end

      # Turn a CSV tilemap (a grid of tile numbers) into a grid of tile-image names. A
      # `0` is a blank cell; any other number picks a tile by the tileset's numbering.
      def csv_image_grid(name, tiles, set, path)
        by_number = set[:by_number]
        numbers = parse_csv_tilemap(name, File.read(resolve_asset_path(path)))

        img_rows = numbers.map do |row|
          row.map do |n|
            next nil if n.zero? # 0 = an empty cell (a map editor's convention) — background shows through

            by_number[n] || raise(ArgumentError,
                                  "background :#{name}: the map uses tile number #{n}, but tileset :#{tiles} " \
                                  "has only tiles #{by_number.keys.min}..#{by_number.keys.max}. " \
                                  "Make sure this CSV is from the same tile sheet.")
          end
        end
        [img_rows, by_number.keys.sort.map { |k| by_number[k] }.uniq]
      end

      # Parse a CSV tilemap, as a map editor like Tiled exports a layer: rows of
      # comma-separated whole numbers, one row per line. Blank lines and a trailing
      # comma on a row are tolerated. Every row must be the same width (a map is a
      # rectangle) and every cell a number (0 = empty). The high bits a map editor sets
      # on a flipped/rotated tile are stripped, so such a tile still draws (unflipped)
      # rather than erroring.
      def parse_csv_tilemap(name, text)
        rows = text.each_line.map(&:strip).reject(&:empty?).each_with_index.map do |line, r|
          line.split(",").map(&:strip).reject(&:empty?).map do |field|
            unless field.match?(/\A\d+\z/)
              raise ArgumentError,
                    "background :#{name}: the tilemap must be a grid of numbers (a CSV export), " \
                    "but line #{r + 1} has #{field.inspect}."
            end
            field.to_i & 0x1FFFFFFF # drop a map editor's tile-flip flags (the top 3 bits of the number)
          end
        end
        raise ArgumentError, "background :#{name}: the tilemap file is empty" if rows.empty?

        widths = rows.map(&:length).uniq
        unless widths.size == 1
          raise ArgumentError,
                "background :#{name}: the tilemap has rows of different widths (#{widths.sort.join(', ')} cells). " \
                "Every row must be the same length, because a map is a rectangle."
        end
        rows
      end

      # The wall rectangles for a background: the cells whose tile is marked `solid:` in
      # the tileset, merged into as few rectangles as possible and given in pixels. A
      # sprite `blocked_by` this background is stopped from entering any of them. Merging
      # keeps the count small — a bordered room is four rectangles, not one per wall tile
      # — so the per-frame overlap tests stay cheap. +img_rows+ is the grid of tile-image
      # names (nil = blank cell) the background was built from.
      def wall_rects(img_rows, set)
        solid = set[:solid_images]
        return [] if solid.empty?

        grid = img_rows.map { |row| row.map { |img| !img.nil? && solid.include?(img) } }
        merge_solid_cells(grid).map do |col, row, w, h|
          [col * set[:tile_w], row * set[:tile_h], w * set[:tile_w], h * set[:tile_h]]
        end
      end

      # Greedily cover the solid cells with rectangles: from each unclaimed solid cell,
      # grow right as far as the run goes, then down as far as that whole width stays
      # solid, claim the block, and move on. Maze-shaped walls collapse to a handful of
      # rectangles this way. Returns [col, row, width, height] in tile units.
      def merge_solid_cells(grid)
        rows = grid.length
        cols = grid.map(&:length).max || 0
        claimed = Array.new(rows) { Array.new(cols, false) }
        rects = []
        rows.times do |r|
          cols.times do |c|
            next unless grid[r][c] && !claimed[r][c]

            w = 1
            w += 1 while c + w < cols && grid[r][c + w] && !claimed[r][c + w]
            h = 1
            h += 1 while r + h < rows && (c...c + w).all? { |cc| grid[r + h][cc] && !claimed[r + h][cc] }
            (r...r + h).each { |rr| (c...c + w).each { |cc| claimed[rr][cc] = true } }
            rects << [c, r, w, h]
          end
        end
        rects
      end

      # Normalize a background map into an array of row strings. A string is split on
      # newlines (blank lines dropped); an array is taken as its rows already. A map
      # is a rectangle, so every row must be the same width — a ragged one is almost
      # always a typo (a stray or missing character), and left alone it would push
      # part of the level out of line, so we catch it with a plain-language error.
      def background_rows(name, map)
        rows = case map
               when String then map.each_line.map(&:chomp).reject(&:empty?)
               when Array then map.map(&:to_s)
               else raise ArgumentError, "background :#{name} map must be a String or an Array of row strings"
               end
        raise ArgumentError, "background :#{name} has an empty map" if rows.empty?

        widths = rows.map(&:length).uniq
        unless widths.size == 1
          raise ArgumentError,
                "background :#{name} has rows of different widths (#{widths.sort.join(', ')} characters). " \
                "Every row must be the same length, because a map is a rectangle."
        end
        rows
      end
    end
  end
end
