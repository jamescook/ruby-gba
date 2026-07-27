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
    # (This paints a *static* background by stamping each tile once. Scrolling a map
    # bigger than the screen, and stacking layers, build on this same surface.)
    module Tiled
      # Define a tileset: a map from a character to the tile {#image} it stands for.
      # The images must already be defined and must all be the same size (they form
      # a uniform grid). The characters are the alphabet a `background` map is drawn
      # with.
      #
      # @param name [Symbol] the tileset's name, referenced by `background(tiles:)`
      # @param char_map [Hash{String=>Symbol}] one entry per tile: character => image name
      def tiles(name, char_map)
        raise ArgumentError, "tiles :#{name} needs at least one character => tile mapping" if char_map.empty?

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

        @tilesets[name] = { chars: char_map.dup, tile_w: sizes.first[0], tile_h: sizes.first[1] }
      end

      # Paint a tiled background: a tileset plus a map of which tile goes in each
      # grid cell. The map is a block of characters — one character per cell, rows
      # separated by newlines (a heredoc reads most like the picture) — or an array
      # of row strings. Each character is stamped as its tile at that cell; a space
      # leaves the cell empty (the background shows through).
      #
      # @param name [Symbol] the background's name
      # @param tiles [Symbol] a tileset defined with {#tiles}
      # @param map [String, Array<String>] the grid of tile characters
      def background(name, tiles:, map:)
        set = @tilesets[tiles] || raise(ArgumentError,
                                        "background :#{name}: no tileset named :#{tiles} — " \
                                        "define one first with `tiles :#{tiles}, ...`")
        rows = background_rows(name, map)
        chars = set[:chars]
        tile_w = set[:tile_w]
        tile_h = set[:tile_h]

        rows.each_with_index do |row, r|
          row.each_char.with_index do |ch, c|
            next if ch == " " # a blank cell — leave the background showing through

            img = chars[ch] || raise(ArgumentError,
                                     "background :#{name}: character #{ch.inspect} isn't in tileset " \
                                     ":#{tiles} (its tiles are #{chars.keys.map(&:inspect).join(', ')})")
            blit(img, c * tile_w, r * tile_h)
          end
        end
      end

      private

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
