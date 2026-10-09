# frozen_string_literal: true

module RubyGBA
  module IR
    # HOW BIG THE GRID A BACKGROUND SCROLLS OVER IS, which is not the same as how many
    # rows the author wrote.
    #
    # A tiled background scrolls over a grid that comes in fixed sizes, and the picture
    # comes round again at that grid's edge rather than at the edge of the cells anybody
    # filled in. So a map of twelve rows scrolls over a grid of thirty-two: past the
    # twelfth row you see empty cells, and the picture repeats after thirty-two. Wrapping
    # at the author's own size instead would tile a small map across the screen forever,
    # which is not what a background does.
    #
    # This is here rather than in a backend because every backend has to agree about it
    # exactly — one draws the picture, another moves scroll registers, and a disagreement
    # shows up as a background that comes round in a different place on the console than
    # in the oracle. It is derived from the authored map and nothing else, so both get the
    # same answer without being told.
    module TileMap
      # The grid sizes a background can have, per axis. Both come from the console and
      # neither is written anywhere in a program: the framework picks the smallest that
      # holds what the author drew.
      SIZES = [32, 64].freeze

      module_function

      # The grid this background scrolls over, as [columns, rows].
      def grid(map)
        [grid_size_for(map.map { |row| row.length }.max || 0), grid_size_for(map.length)]
      end

      # The smallest grid size that holds this many cells, or nil for a map too big for
      # any of them.
      def grid_size_for(count) = SIZES.find { |size| count <= size }

      # Whether a map fits a grid at all — the one thing a caller has to check before
      # trusting #grid.
      def fits?(map)
        cols, rows = [map.map { |row| row.length }.max || 0, map.length]
        !grid_size_for(cols).nil? && !grid_size_for(rows).nil?
      end

      # The biggest map there is, for a message.
      def max_grid_size = SIZES.last

      # WHETHER A BACKGROUND'S MAPS ARE BROUGHT INTO VIEW A STRIP AT A TIME, rather than
      # held whole in the grid. That is so for a background with a map too big for any
      # grid, and for one whose maps are of different sizes, since they cannot all fill
      # one grid. Such a background keeps every map whole in the cartridge and the grid
      # holds only the cells around the view.
      #
      # IT DOES NOT COME ROUND AGAIN. Past the edge of such a map there are no cells, so
      # the view shows nothing there — the backdrop, or the layers behind. A room has
      # edges; coming round to the far side of it is what a small repeating backdrop
      # wants, and that one is held whole and still does.
      def streams?(maps)
        maps.any? { |map| !fits?(map) } || maps.map { |map| size_of(map) }.uniq.size > 1
      end

      # A map's own size, as [columns, rows].
      def size_of(map) = [map.map { |row| row.length }.max || 0, map.length]
    end
  end
end
