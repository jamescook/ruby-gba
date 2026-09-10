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
        [cells(map.map { |row| row.length }.max || 0), cells(map.length)]
      end

      # The smallest grid size that holds this many cells, or nil for a map too big for
      # any of them.
      def cells(count) = SIZES.find { |size| count <= size }

      # Whether a map fits a grid at all — the one thing a caller has to check before
      # trusting #grid.
      def fits?(map)
        cols, rows = [map.map { |row| row.length }.max || 0, map.length]
        !cells(cols).nil? && !cells(rows).nil?
      end

      # The biggest map there is, for a message.
      def most = SIZES.last
    end
  end
end
