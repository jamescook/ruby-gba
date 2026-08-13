# frozen_string_literal: true

module Wolf3D
  # The wall pictures a level uses, laid side by side in one picture.
  #
  # A stretched column takes the column NUMBER as something the game works out, so a hundred
  # wall pictures in one picture need no runtime choosing: the column is
  # `which_wall * 64 + which_column`. That is why this exists rather than one picture per wall.
  #
  # Wolfenstein numbers its walls from one and keeps TWO pictures for each — a lit one for the
  # faces you meet going one way and a darker one for the other. That pair is where the whole
  # game gets its sense of light, for nothing.
  class WallAtlas
    SIDE = Vswap::Texture::SIDE
    LIT = 0
    DARK = 1

    attr_reader :codes

    def initialize(vswap, palette, level)
      @vswap = vswap
      @palette = palette
      @codes = wall_codes(level)
    end

    # Where a wall code's pictures start in the row of them. Two per code, lit then dark.
    def slice_for(code, face)
      (@codes.index(code) * 2 * SIDE) + (face * SIDE)
    end

    def width = @codes.length * 2 * SIDE
    def height = SIDE

    # Column-major in the file, and a picture here is row-major, so this is the one place the
    # two orders meet.
    def pixels
      rows = Array.new(SIDE) { [] }
      @codes.each do |code|
        [LIT, DARK].each do |face|
          texture = @vswap.wall(texture_index(code, face))
          SIDE.times { |y| SIDE.times { |x| rows[y] << @palette[texture[x, y]] } }
        end
      end
      rows.flatten
    end

    # A code's two pictures sit next to each other in the file, lit first.
    def texture_index(code, face) = ((code - 1) * 2) + face

    private

    # Only the walls this level actually builds with. A whole set is a hundred pictures and a
    # floor uses a dozen.
    def wall_codes(level)
      seen = []
      level.each_cell do |x, y|
        code = level.wall_code(x, y)
        next unless level.solid?(x, y) && code.between?(1, 63)

        seen << code unless seen.include?(code)
      end
      seen.sort
    end
  end
end
