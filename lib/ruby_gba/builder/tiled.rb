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
    # One `background` paints a single layer. Declare several and they stack — the
    # first is the backmost, each later one in front, composited by the tile hardware —
    # and each can be scrolled independently (scroll a near and a far layer at different
    # speeds for parallax). See {Background}.
    module Tiled
      # Define a tileset: a map from a character to the tile {#image} it stands for.
      # The images must already be defined and must all be the same size (they form
      # a uniform grid). The characters are the alphabet a `background` map is drawn
      # with.
      #
      #   tiles :dungeon, "#" => :brick, "." => :floor
      #
      # Or IMPORT the tiles from a tile sheet — one image file holding the tiles in a
      # grid — with `from:` (the file) and `tile:` (each tile's size in pixels). Then
      # each character points at a cell instead of a hand-drawn image: a cell number
      # (counting left-to-right, top-to-bottom) or `[column, row]`. The file is found
      # next to your script; `transparent: true` honors a cut-out background.
      #
      #   tiles :dungeon, from: "dungeon.png", tile: 8, "#" => 0, "." => 1
      #
      # Add `solid:` to mark which tiles are walls a sprite can't move through — a
      # list of the characters that block (`solid: ["#"]`, or one char `solid: "#"`).
      # A `background` built from this tileset then knows where its walls are, so a
      # sprite told to be `blocked_by` it stops at them (see {HardwareSprite#blocked_by}).
      #
      # @param name [Symbol] the tileset's name, referenced by `background(tiles:)`
      # @param char_map [Hash] one entry per tile: character => image name, or (with
      #   `from:`) character => cell. Options `from:`/`tile:`/`transparent:`/`solid:`.
      def tiles(name, char_map)
        char_map = char_map.dup
        solid = Array(char_map.delete(:solid)) # characters whose tiles block movement (walls)
        from = char_map.delete(:from)          # a tile sheet to import the tiles from, if any
        tile = char_map.delete(:tile)          # each tile's size in that sheet
        transparent = char_map.delete(:transparent) { false }
        raise ArgumentError, "tiles :#{name} needs at least one character => tile mapping" if char_map.empty?

        # With `from:`, each character named a cell; import those cells into images so
        # the rest of this method sees the same character => image-name map as inline.
        char_map = import_tile_cells(name, from, tile, transparent, char_map) if from

        unknown = solid.reject { |ch| char_map.key?(ch) }
        unless unknown.empty?
          raise ArgumentError,
                "tiles :#{name}: solid #{unknown.map(&:inspect).join(', ')} " \
                "#{unknown.one? ? 'is' : 'are'} not in the tileset (its tiles are #{char_map.keys.map(&:inspect).join(', ')})"
        end

        sizes = char_map.map do |ch, img|
          @images[img] || raise(ArgumentError,
                                 "tiles :#{name}: tile #{ch.inspect} => :#{img} isn't a defined image — " \
                                 "define it first with `image :#{img}, ...`")
        end
        unless sizes.uniq.size == 1
          raise ArgumentError,
                "tiles :#{name} tiles must all be the same size (they form a uniform grid), " \
                "got #{sizes.uniq.map { |w, h| "#{w}x#{h}" }.join(', ')}"
        end

        @tilesets[name] = { chars: char_map.dup, tile_w: sizes.first[0], tile_h: sizes.first[1], solid: solid }
      end

      # Paint a tiled background: a tileset plus a map of which tile goes in each
      # grid cell. The map is a block of characters — one character per cell, rows
      # separated by newlines (a heredoc reads most like the picture) — or an array
      # of row strings. Each character is stamped as its tile at that cell; a space
      # leaves the cell empty (the background shows through).
      #
      # Returns a {Background} handle you can scroll (`world.scroll_by dx, dy`).
      #
      # @param name [Symbol] the background's name
      # @param tiles [Symbol] a tileset defined with {#tiles}
      # @param map [String, Array<String>] the grid of tile characters
      # @return [Background] a handle: scroll_by / scroll_to
      def background(name, tiles:, map:)
        set = @tilesets[tiles] || raise(ArgumentError,
                                        "background :#{name}: no tileset named :#{tiles} — " \
                                        "define one first with `tiles :#{tiles}, ...`")
        rows = background_rows(name, map)
        chars = set[:chars]

        # Number the distinct tiles (in the order the tileset lists them), then turn
        # the character map into a grid of those numbers — nil where a cell is blank.
        # The grid, not a pile of draw calls, is what the background node carries, so
        # a backend is free to stamp it pixel by pixel or hand it to tile hardware.
        tile_names = chars.values.uniq
        index_of = tile_names.each_with_index.to_h
        grid = rows.map do |row|
          row.each_char.map do |ch|
            next nil if ch == " " # a blank cell — leave the background showing through

            img = chars[ch] || raise(ArgumentError,
                                     "background :#{name}: character #{ch.inspect} isn't in tileset " \
                                     ":#{tiles} (its tiles are #{chars.keys.map(&:inspect).join(', ')})")
            index_of[img]
          end
        end

        record(Build.background(name, tiles: tile_names, map: grid,
                                      tile_w: set[:tile_w], tile_h: set[:tile_h]))

        # The window's top-left, in pixels, tracked in two hidden variables (cleared at
        # boot since console RAM isn't zero at power-on). A background that never
        # scrolls simply leaves them at 0.
        scroll_x = :"__bg_#{name}_sx"
        scroll_y = :"__bg_#{name}_sy"
        [scroll_x, scroll_y].each { |var| at_boot(Build.set(var, Build.int(0))); ensure_var(var) }
        Background.new(self, name: name, scroll_x: scroll_x, scroll_y: scroll_y,
                             walls: wall_rects(rows, set))
      end

      private

      # Import a tileset from a sheet: slice the file into cells of the given size and
      # define the cell each character points at as an image, returning the character
      # => image-name map the tileset is built from. Each character's value is a cell
      # number or [column, row]. The internal image names are unique per tileset.
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

      # The wall rectangles for a background: the cells whose tile is `solid:` in the
      # tileset, merged into as few rectangles as possible and given in pixels. A sprite
      # `blocked_by` this background is stopped from entering any of them. Merging keeps
      # the count small — a bordered room is four rectangles, not one per wall tile — so
      # the per-frame overlap tests stay cheap.
      def wall_rects(rows, set)
        solid = set[:solid]
        return [] if solid.empty?

        grid = rows.map { |row| row.each_char.map { |ch| solid.include?(ch) } }
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
                "background :#{name} has ragged rows (#{widths.sort.join(', ')} characters wide) — " \
                "every row must be the same length, since a map is a rectangle"
        end
        rows
      end
    end
  end
end
