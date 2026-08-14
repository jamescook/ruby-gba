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

    # WHERE EACH OF A GUARD'S PICTURES SITS in his own run of them, counting from the first.
    # Eight of him standing still, then four sets of eight walking, then the ones that do not
    # turn: hurt, dying, dead, and firing.
    STILL_PICTURE = 0
    WALK_PICTURES = [8, 16, 24, 32].freeze
    # The two he flinches with sit either side of the three he falls over in, which is the
    # order they are in the file rather than an order anyone would choose.
    HURT_PICTURES = [40, 44].freeze
    FALL_PICTURES = [41, 42, 43].freeze
    DEAD_PICTURE = 45
    FIRE_PICTURES = [46, 47, 48].freeze

    # How much killing a guard takes. The easiest two settings agree on it.
    HIT_POINTS = 25

    # HOW LONG A STATE LASTS is counted in the original's own units — seventieths of a second —
    # and the numbers below are its numbers, unchanged. This is how many of them a pass of this
    # game is worth. It is deliberately a whole number: the shortest state in the table is three
    # units long, so a pass can never step over a whole state, and the machine never needs to
    # advance twice in one pass.
    TICKS_PER_PASS = 2

    # THE STATE TABLE, and it is the behaviour rather than a description of it. Each row is a
    # picture, how long to stand in it, what to think about while there, and which row comes
    # next. Read out of the original: guessing these gives something that merely resembles
    # Wolfenstein.
    #
    # Standing lasts forever (a length of nought never runs down) and only looks. The patrol is
    # four walking pictures at twenty and fifteen with a five-unit step between the pairs; the
    # chase is the same four at ten and eight with three-unit steps, which is why a guard who
    # has seen you visibly hurries. Firing is three pictures at twenty each.
    # +fires+ marks the one state whose END is a shot: the original hangs its actions on
    # leaving a state rather than on being in one, so a guard aims, fires, and lowers his arm
    # across three pictures and the bullet leaves on the middle one.
    State = Data.define(:name, :picture, :turns, :ticks, :think, :becomes, :fires)

    def self.state(name, picture, ticks, think, becomes, turns: true, fires: false)
      State.new(name: name, picture: picture, ticks: ticks, think: think, becomes: becomes,
                turns: turns, fires: fires)
    end

    STATES = [
      state(:stand,   STILL_PICTURE,    0,  :look,   :stand),

      state(:path1,   WALK_PICTURES[0], 20, :patrol, :path1s),
      state(:path1s,  WALK_PICTURES[0], 5,  nil,     :path2),
      state(:path2,   WALK_PICTURES[1], 15, :patrol, :path3),
      state(:path3,   WALK_PICTURES[2], 20, :patrol, :path3s),
      state(:path3s,  WALK_PICTURES[2], 5,  nil,     :path4),
      state(:path4,   WALK_PICTURES[3], 15, :patrol, :path1),

      state(:chase1,  WALK_PICTURES[0], 10, :chase,  :chase1s),
      state(:chase1s, WALK_PICTURES[0], 3,  nil,     :chase2),
      state(:chase2,  WALK_PICTURES[1], 8,  :chase,  :chase3),
      state(:chase3,  WALK_PICTURES[2], 10, :chase,  :chase3s),
      state(:chase3s, WALK_PICTURES[2], 3,  nil,     :chase4),
      state(:chase4,  WALK_PICTURES[3], 8,  :chase,  :chase1),

      state(:shoot1,  FIRE_PICTURES[0], 20, nil,     :shoot2, turns: false),
      state(:shoot2,  FIRE_PICTURES[1], 20, nil,     :shoot3, turns: false, fires: true),
      state(:shoot3,  FIRE_PICTURES[2], 20, nil,     :chase1, turns: false),

      # Hurt but not finished: he flinches and comes straight back at you. Which of the two
      # pictures he wears is whether the hits he has left are an odd number, which is the
      # original's way of making the same wound look different twice running.
      state(:hurt1,   HURT_PICTURES[0], 10, nil,     :chase1, turns: false),
      state(:hurt2,   HURT_PICTURES[1], 10, nil,     :chase1, turns: false),

      # ...and finished: three pictures of falling and then a body on the floor, which lasts
      # for good because its length is nought.
      state(:fall1,   FALL_PICTURES[0], 15, nil,     :fall2, turns: false),
      state(:fall2,   FALL_PICTURES[1], 15, nil,     :fall3, turns: false),
      state(:fall3,   FALL_PICTURES[2], 15, nil,     :dead,  turns: false),
      state(:dead,    DEAD_PICTURE,     0,  nil,     :dead,  turns: false)
    ].freeze

    THINKING = { nil => 0, look: 1, patrol: 2, chase: 3 }.freeze

    # A guard who has noticed you keeps knowing it, through being hurt and into falling over.
    # The one thing it changes: a guard who has NOT noticed you takes double from a shot, which
    # is the original quietly rewarding you for getting the first one in.
    def self.roused?(state) = !%i[stand path1 path1s path2 path3 path3s path4].include?(state.name)

    def self.dead?(state) = state.name == :dead

    def self.state_number(name) = STATES.index { |s| s.name == name } ||
                                  raise(ArgumentError, "there is no guard state #{name.inspect}")

    # HOW FAST A GUARD WALKS, in the original's units: so many 65536ths of a cell per unit of
    # time. A guard who has seen you moves at three times his patrolling speed.
    PATROL_SPEED = 512
    CHASE_TIMES = 3
    CELL = 1 << 16

    # ...and the same as this game counts it: cells per pass.
    def self.speed(chasing: false)
      PATROL_SPEED * (chasing ? CHASE_TIMES : 1) * TICKS_PER_PASS / CELL.to_f
    end

    # HOW NEAR IS NEAR ENOUGH TO BE SEEN WITHOUT LOOKING: a guard notices anyone this close
    # whichever way he is facing. One and a half cells, in the original's units.
    AUTOMATIC_SIGHT = 0x18000 / CELL.to_f

    # HOW LONG A GUARD TAKES TO REACT once he has seen you, in the original's time units — one
    # plus a quarter of a random byte, so up to about a second. This delay is why the game feels
    # fair: you get a moment between being seen and being shot at.
    REACTION = 64

    # WHICH WAY EACH DIRECTION GOES, in the order the original numbers them: counter-clockwise
    # from east, with the diagonals between. Eight is "nowhere", which is what a guard who
    # cannot move in any direction is left with.
    WAYS = [[1, 0], [1, -1], [0, -1], [-1, -1], [-1, 0], [-1, 1], [0, 1], [1, 1]].freeze
    NOWHERE = WAYS.length

    # A cell of plane 1 holding one of these is a TURNING POINT: a patrolling guard who reaches
    # it turns to the direction it names and carries on.
    FIRST_ARROW = 90

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

    # The pictures a floor needs for its guards: every one any state can wear. A state that
    # turns needs all eight of its own, because which one shows depends on where the player is
    # standing — a guard facing east still has his back to you from the other side of the room.
    # A state that does not turn needs the one.
    def self.pictures
      @pictures ||= STATES.flat_map { |s| s.turns ? (0...POSES).map { |n| s.picture + n } : [s.picture] }
                          .uniq.sort.map { |offset| FIRST_STANDING_PICTURE + offset }
    end

    # Where a state's first picture sits in that row.
    def self.picture_position(state) = pictures.index(FIRST_STANDING_PICTURE + state.picture)

    # Which way a guard put down facing +facing+ is pointing, as the original numbers
    # directions: counter-clockwise from east, so the four square ones are every other number.
    def self.direction_of(facing) = FACINGS.index(facing) * 2

    def self.starting_state(guard) = state_number(guard.patrolling ? :path1 : :stand)

    def pictures = self.class.pictures

    # Which way a turning point sends a patrolling guard who reaches it, or nil where the cell
    # holds no turning point.
    def arrow_at(x, y)
      code = @level.thing_code(x, y)
      return nil unless code.between?(FIRST_ARROW, FIRST_ARROW + WAYS.length - 1)

      code - FIRST_ARROW
    end

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
