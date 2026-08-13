# frozen_string_literal: true

module Wolf3D
  # The game's 256 colours as a grid, so the palette pulled out of the program can be looked at
  # rather than taken on trust.
  class PaletteView
    ACROSS = 16
    CELL = 3
    ORIGIN_X = 4
    ORIGIN_Y = 56

    def initialize(build, palette)
      @build = build
      @palette = palette
    end

    def declare
      @build.image :palette, width: side, height: side, data: pixels
      self
    end

    def draw = @build.blit(:palette, ORIGIN_X, ORIGIN_Y)

    def side = ACROSS * CELL

    def pixels
      rows = @palette.colours.each_slice(ACROSS).flat_map do |row|
        stretched = row.flat_map { |colour| [colour] * CELL }
        [stretched] * CELL
      end
      rows.flatten
    end
  end
end
