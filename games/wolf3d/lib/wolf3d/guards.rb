# frozen_string_literal: true

module Wolf3D
  # The guards standing on one floor: where each is, which way it faces, and whether it walks
  # a beat or waits where it was put.
  #
  # Plane 1 says all of it in one number per cell, and the number carries three things at once.
  # Four codes in a row are the four ways a guard can face; the next four are the same four
  # facings for one that patrols; and the whole block repeats twice more further up for the
  # guards that only turn up when the game is set harder. So a code is decoded by taking the
  # difficulty steps off it first, then asking which of the eight it landed on.
  #
  # The numbers are read out of the original rather than remembered.
  class Guards
    # Where the first block of spawn codes starts, and how far along the same block repeats
    # for a harder game. Everything a floor holds is at 108, plus 36 for the ones that appear
    # from the middle setting up, plus 36 again for the hardest.
    STANDING = 108
    PATROLLING = 112
    HARDER = 36
    BLOCK = 8 # the two sets of four facings, standing then patrolling

    # A guard that was already dead when the floor was built — scenery, not an enemy.
    DEAD = 124

    # WHICH WAY A CODE FACES, in the order the four codes run. Not the order the player's own
    # start codes run, which is north, east, south, west: the original stores the two in
    # different directions round the circle, and the only way to know that is to look.
    FACINGS = %i[east north west south].freeze

    # How many of the harder blocks a setting brings in. The game's own default is the second
    # of the four, which brings in none of them.
    STEPS = { baby: 0, easy: 0, medium: 1, hard: 2 }.freeze
    DEFAULT_DIFFICULTY = :easy

    # WHERE A GUARD'S PICTURES ARE in the numbering VSWAP's sprites use. That numbering is a
    # plain list in the original — a demo picture, a death-cam picture, forty-eight pieces of
    # scenery, and then the guard — which puts the first of its eight standing poses at 50.
    # Checked against a real VSWAP rather than counted off the source: 50 to 57 are eight
    # man-shaped pictures of about the same size, and 44 to 49 are visibly not.
    FIRST_STANDING_PICTURE = 50
    POSES = 8

    Guard = Data.define(:x, :y, :facing, :patrolling)

    attr_reader :guards

    def initialize(level, difficulty: DEFAULT_DIFFICULTY)
      unless STEPS.key?(difficulty)
        raise ArgumentError, "there is no difficulty #{difficulty.inspect}; the four are #{STEPS.keys.join(', ')}"
      end

      @level = level
      @steps = STEPS.fetch(difficulty)
      @guards = level.each_cell.filter_map { |x, y| guard_at(x, y) }
    end

    def count = @guards.length
    def empty? = @guards.empty?

    # The pictures a floor needs for its guards. All eight, whichever way they were put down:
    # which one shows depends on where the player is standing, so a guard facing east still
    # has its back to you from the other side of the room.
    def pictures = (0...POSES).map { |n| FIRST_STANDING_PICTURE + n }

    private

    def guard_at(x, y)
      code = spawn_code(x, y)
      return nil if code.nil?

      within = code - STANDING
      Guard.new(x: x, y: y,
                facing: FACINGS.fetch(within % FACINGS.length),
                patrolling: within >= (PATROLLING - STANDING))
    end

    # The code as the easiest setting would write it, or nil where this cell holds no guard
    # this game is playing. A harder game's codes come down to the same eight.
    def spawn_code(x, y)
      code = @level.thing_code(x, y)
      (0..@steps).each do |step|
        base = code - (step * HARDER)
        return base if base >= STANDING && base < STANDING + BLOCK
      end
      nil
    end
  end
end
