# frozen_string_literal: true

module Wolf3D
  # The things standing in the rooms: lamps and tables and bones and barrels, and which of them
  # you cannot walk through.
  #
  # Plane 1 says it the same way it says where the guards are — one number per cell — and the
  # numbers from 23 up name about fifty pieces in a fixed order. So a code is a piece by
  # subtraction, and everything else about it is looked up in the table below.
  #
  # A PIECE IS A BILLBOARD: one picture standing in the middle of a cell, drawn at the size its
  # distance earns and behind whatever walls are in front of it. It is exactly what a guard is
  # with the mind taken out, so nothing here draws — the view already knows how.
  class Scenery
    # Where the codes start, and how many of them there are. The last one is a second kind of
    # ammunition clip that shares the ordinary clip's picture, which is why the list of pictures
    # below is not simply nought to forty-seven.
    FIRST_CODE = 23

    # Where these pictures sit in the numbering VSWAP's sprites use. The file opens with a
    # picture for the demo and one for the death camera, and the scenery starts after them —
    # which is also what puts the first guard at 50, forty-eight pieces later.
    FIRST_PICTURE = 2

    # WHICH PICTURE EACH PIECE WEARS. All but the last wear their own, in order.
    PICTURES = ((0..47).to_a + [26]).freeze

    # WHICH OF THEM STOP YOU, read out of the original's own table rather than remembered.
    # Roughly half: a barrel, a table, a pillar, a tree, a sink, a plant, an urn, a suit of
    # armour, a hanging cage, a well, a flag, a stove, a rack of spears.
    #
    # The rest you walk through — a puddle, a skeleton lying flat, the kitchen things, and every
    # one of the things you can pick up. The two people always notice are the CHANDELIER and the
    # CEILING LIGHT, which hang: this game has no up or down, so a hanging lamp is a picture
    # whose art sits high in its square, and what reads as its shadow is the lower part of the
    # same picture. You walk under both.
    BLOCKING = [1, 2, 3, 5, 7, 8, 10, 11, 12, 13, 16, 17, 18, 22,
                35, 36, 37, 39, 40, 45, 46].freeze

    LAST_CODE = FIRST_CODE + PICTURES.length - 1

    Piece = Data.define(:x, :y, :picture, :blocks)

    attr_reader :pieces

    def initialize(level)
      @level = level
      @pieces = level.each_cell.filter_map { |x, y| piece_at(x, y) }
      @where = @pieces.each_with_index.to_h { |piece, at| [[piece.x, piece.y], at] }
    end

    def count = @pieces.length
    def empty? = @pieces.empty?

    # The pictures a floor needs for its scenery, each once.
    def pictures = @pieces.map(&:picture).uniq.sort

    # Where in the list the piece standing on this cell is, or nil for a cell with none. What
    # reads this is anything that has to make one piece disappear — a key, once you have it.
    def index_at(x, y) = @where[[x, y]]

    # Can a foot go here? Only the pieces that block say no, and a cell with nothing standing in
    # it never asks the question.
    def blocks?(x, y) = @where.key?([x, y]) && @pieces[@where[[x, y]]].blocks

    private

    def piece_at(x, y)
      code = @level.thing_code(x, y)
      return nil unless code.between?(FIRST_CODE, LAST_CODE)

      at = code - FIRST_CODE
      Piece.new(x: x, y: y, picture: FIRST_PICTURE + PICTURES.fetch(at), blocks: BLOCKING.include?(at))
    end
  end
end
