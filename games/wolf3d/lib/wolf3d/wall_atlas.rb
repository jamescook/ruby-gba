# frozen_string_literal: true

module Wolf3D
  # The pictures a level needs, laid side by side in one picture.
  #
  # A stretched column takes the column NUMBER as something the game works out, so a hundred
  # wall pictures in one picture need no runtime choosing: the column is
  # `which_picture * 64 + which_column`. That is why this exists rather than one picture per wall.
  #
  # Wolfenstein numbers its walls from one and keeps TWO pictures for each — a lit one for the
  # faces you meet going one way and a darker one for the other. That pair is where the whole
  # game gets its sense of light, for nothing, and the two are kept side by side here so that
  # picking between them is an add rather than a lookup.
  #
  # Doors are pictures too, and they live in the same row for the same reason.
  class WallAtlas
    SIDE = Vswap::Texture::SIDE
    LIT = 0
    DARK = 1

    attr_reader :codes, :textures

    def initialize(vswap, palette, level, doors: nil, lifts: nil)
      @vswap = vswap
      @palette = palette
      @codes = wall_codes(level)
      @textures = @codes.flat_map { |code| [texture_index(code, LIT), texture_index(code, DARK)] }
      # A door's panel, and the lever of a lift pulled down. Neither is a wall the map builds
      # with, so neither turns up in the codes above — a pulled lever appears in no map at all,
      # because it is only ever written by the game. Both are appended in pairs, lit then dark,
      # so the walk can still pick a face by adding one.
      @textures += ((doors&.pictures || []) + (lifts&.pictures || [])).reject { |t| @textures.include?(t) }
    end

    # Where a picture sits in the row, counting pictures. This is what the map table holds, so
    # that the two pictures of a wall are one apart and the walk adds the face to pick.
    def position_of(texture) = @textures.index(texture)

    # ...and the same as a COLUMN number, which is what a stretched column is asked for.
    def slice_of(texture) = position_of(texture) * SIDE

    # Where a wall code's pictures start in the row of them. Two per code, lit then dark.
    def slice_for(code, face) = slice_of(texture_index(code, face))

    def width = @textures.length * SIDE
    def height = SIDE

    # Column-major in the file, and a picture here is row-major, so this is the one place the
    # two orders meet.
    def pixels
      rows = Array.new(SIDE) { [] }
      @textures.each do |index|
        texture = @vswap.wall(index)
        SIDE.times { |y| SIDE.times { |x| rows[y] << @palette[texture[x, y]] } }
      end
      rows.flatten
    end

    # A code's two pictures sit next to each other in the file, lit first. Also asked at build
    # time by things that know a wall code but have no atlas yet — the lift, whose pulled lever
    # is a picture no map ever mentions — so the sum lives on the class and the instance defers
    # to it rather than the two drifting apart.
    def self.texture_index(code, face) = ((code - 1) * 2) + face

    def texture_index(code, face) = self.class.texture_index(code, face)

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
