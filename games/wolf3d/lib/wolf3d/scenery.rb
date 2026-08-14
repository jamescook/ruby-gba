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

    # WHAT WALKING ONTO A PIECE GIVES YOU, and about a third of the list gives something. The
    # numbers are the original's own (wl_agent.cpp, GetBonus) rather than remembered.
    #
    # Each is a KIND and an AMOUNT, which is what lets one piece of machinery serve all of them:
    # every one is "add this much of that, unless you are already full of it". The kinds differ
    # only in what being full means — a hundred of health, ninety-nine rounds, or nothing at all
    # for treasure, which you can never have too much of.
    #
    # THE TWO WEAPONS GIVE ONLY THEIR ROUNDS for now, which is not a stand-in: the original's
    # GiveWeapon hands you six rounds first and then the weapon, so the rounds are half of what a
    # machine gun really is. The other half waits on there being weapons to hold.
    BONUSES = {
      6 => [:health, 4],        # bad food — worth having, and not much
      20 => [:key, :gold],
      21 => [:key, :silver],
      24 => [:health, 10],      # good food
      25 => [:health, 25],      # a first aid box
      26 => [:ammunition, 8],   # a clip
      27 => [:ammunition, 6],   # a machine gun...
      28 => [:ammunition, 6],   # ...and a gatling gun
      29 => [:treasure, 100],   # a cross
      30 => [:treasure, 500],   # a chalice
      31 => [:treasure, 1000],  # a bible
      32 => [:treasure, 5000],  # a crown
      33 => [:extra_life, 0],   # the one-up: full health and another go
      # WHAT IS LEFT OF SOMEBODY, which heals one and which you can only bring yourself to take
      # when you are nearly dead. That last part is a rule of its own, so it is a kind of its own.
      34 => [:scraps, 1],
      38 => [:scraps, 1]
    }.freeze

    # THE CEILING LIGHT, named because its SHAPE matters and not only its rules. It is the lamp
    # high in its square and the light it throws low in it, with see-through nothing between —
    # so whatever stands further away and lands in that gap is looked at through the middle of
    # it. Every awkward question about drawing one thing behind another is asked by this piece.
    CEILING_LIGHT = FIRST_CODE + 14

    # Which picture a code wears, in the numbering VSWAP's sprites use.
    def self.picture_of(code) = FIRST_PICTURE + PICTURES.fetch(code - FIRST_CODE)

    # Which picture the clip a dead guard leaves behind wears. It is the same clip that lies on
    # the floor of a level, so a floor that ships none of its own still needs this one.
    CLIP = 26

    def self.clip_picture = picture_of(FIRST_CODE + CLIP)

    # +bonus+ is what walking onto it gives you, as a [kind, amount] pair, or nil for a piece
    # that is only something to look at.
    Piece = Data.define(:x, :y, :picture, :blocks, :bonus)

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

      Piece.new(x: x, y: y, picture: self.class.picture_of(code),
                blocks: BLOCKING.include?(code - FIRST_CODE),
                bonus: BONUSES[code - FIRST_CODE])
    end
  end
end
