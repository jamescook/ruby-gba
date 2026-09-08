# frozen_string_literal: true

module Wolf3D
  # EVERYTHING STANDING ON ONE FLOOR THAT WILL TRY TO KILL YOU: where each is, which way it
  # faces, whether it walks a beat or waits where it was put, and which of the five kinds it is.
  #
  # "Guard" is the collective, because the brown guard is the one every floor has and the one
  # every other kind is a variation on. What each kind IS lives in Enemy; this reads a floor.
  #
  # Plane 1 says all of it in one number per cell, and the number carries three things at once.
  # Four codes in a row are the four ways a thing can face; the next four are the same four
  # facings for one that patrols; and each kind's whole block repeats twice more further up for
  # the ones that only turn up when the game is set harder. So a code is decoded by asking which
  # kind's block it fell in, taking the harder steps off it, and asking which of the eight is
  # left.
  #
  # HOW HARD THE GAME IS SET IS NOT KNOWN HERE, because it is picked on a screen long after the
  # cartridge was built. So every block is read and each one carries the easiest setting it
  # turns up on; a floor stands up the ones its own setting names when it starts.
  #
  # WHAT THAT COSTS, and the two halves of it are worth keeping apart.
  #
  # CARRYING them all costs a frame NOTHING. One its setting leaves out is never spawned, so it
  # takes no slot, is never drawn and never thinks. It costs the cartridge its row in the tables
  # and the floor's start one comparison. Over the first episode that is about two and a half
  # times as many rows as the easiest setting alone would have shipped, in a cartridge with room
  # to spare.
  #
  # STANDING them up costs plenty, and that is the game rather than this reader: the hardest
  # setting really does put twice the men on a busy floor that the easiest does, and a floor is
  # slower for it. Which is what picking "I am Death incarnate!" is FOR.
  #
  # The numbers are read out of the original rather than remembered.
  class Guards
    # A guard that was already dead when the floor was built — scenery, not an enemy. It sits in
    # the gap the codes leave between the officer's block and the SS's.
    DEAD = 124

    # WHICH WAY A CODE FACES, in the order the four codes run. Not the order the player's own
    # start codes run, which is north, east, south, west: the original stores the two in
    # different directions round the circle, and the only way to know that is to look.
    FACINGS = %i[east north west south].freeze
    FACES = FACINGS.length
    BLOCK = FACES * 2 # the two sets of four, standing then patrolling

    # THE FOUR SETTINGS, in the order the original numbers them — which is also the order the
    # screen asks them in, so the row you pick IS the number. Everything that compares one
    # setting against another compares these numbers, at run time.
    SETTINGS = %i[baby easy medium hard].freeze

    # THE EASIEST SETTING EACH BLOCK TURNS UP ON. A code in the first block is on every game, one
    # in the second from the middle setting up, one in the third only on the hardest — so this
    # runs in block order and says which setting each one waits for. That is what one carries
    # into the cartridge, and a floor stands up everyone whose number is at or below the one you
    # picked. The two easiest settings share the first entry, which is the whole of why "Can I
    # play, Daddy?" and "Don't hurt me." meet exactly the same men.
    FROM = [SETTINGS.index(:baby), SETTINGS.index(:medium), SETTINGS.index(:hard)].freeze

    # What a game plays at until somebody picks, which is where the original's own menu opens.
    DEFAULT_DIFFICULTY = :medium

    # THE ONE SETTING THAT CHANGES WHAT A SHOT DOES TO YOU: it takes a quarter of what it would
    # otherwise. The original spends it where the health is taken rather than where the shot is
    # worked out, so every wound goes through it. It is the easiest setting ALONE — the second
    # one hurts you as much as the hardest does, which is easy to get wrong, because the two
    # easiest agree about every other thing on this page.
    GENTLE = SETTINGS.index(:baby)
    GENTLE_PART = 4 # one part in four of what the shot would otherwise have taken

    # HOW NEAR IS NEAR ENOUGH TO BE SEEN WITHOUT LOOKING: one notices anyone this close whichever
    # way it is facing. One and a half cells, in the original's units.
    AUTOMATIC_SIGHT = 0x18000 / Enemy::CELL.to_f

    # HOW NEAR A DOG HAS TO BE TO JUMP, and how near for the jump to land. The original measures
    # both on each axis on its own rather than as a distance: it jumps from about a cell away,
    # and its teeth reach two.
    JUMP_FROM = 1.0
    BITE_REACH = 2.0

    # ...and how often a jump that reaches you actually bites, out of 256 — with a byte of
    # randomness shifted down four deciding what it takes off you, whatever the distance. Which
    # is why a dog at your feet is worse than a guard across the room.
    BITE_CHANCE = 180
    BITE_SHIFT = 16

    # HOW LONG ONE TAKES TO REACT once it has seen you — one plus a quarter of a random byte of
    # the original's time units, so up to about a second. This delay is why the game feels fair:
    # you get a moment between being seen and being shot at. Kept in the same thirds everything
    # else that counts down is kept in.
    REACTION = 64 * Enemy::SCALE

    # WHICH WAY EACH DIRECTION GOES, in the order the original numbers them: counter-clockwise
    # from east, with the diagonals between. Eight is "nowhere", which is what one hemmed in on
    # every side is left with.
    WAYS = [[1, 0], [1, -1], [0, -1], [-1, -1], [-1, 0], [-1, 1], [0, 1], [1, 1]].freeze
    NOWHERE = WAYS.length

    # A cell of plane 1 holding one of these is a TURNING POINT: a patrolling guard who reaches
    # it turns to the direction it names and carries on.
    FIRST_ARROW = 90

    # --- THE GUARD'S OWN NUMBERS ------------------------------------------------------------
    #
    # The rest of the game grew up around the brown guard and is written against him: he is the
    # kind on all but one floor, and the one every test builds. These are his, named here so that
    # nothing which only ever means a guard has to say so twice.

    STANDING = Enemy::GUARD.standing
    PATROLLING = Enemy::GUARD.patrolling
    STATES = Enemy::GUARD.states
    HIT_POINTS = Enemy::GUARD.hit_points.first
    POINTS = Enemy::GUARD.points

    def self.state_number(name) = Enemy::GUARD.state_number(name) ||
                                  raise(ArgumentError, "there is no guard state #{name.inspect}")

    def self.pictures = Enemy::GUARD.pictures
    def self.speed(chasing: false) = Enemy::GUARD.speed(chasing: chasing)

    # --- reading one floor ------------------------------------------------------------------

    # +ambush+ is one put down on an ambush tile: one lying in wait, which has to SEE you and is
    # the one a gunshot does not bring. See Level::AMBUSH and GuardMind#look.
    # +from+ is the easiest setting it turns up on — see FROM.
    Guard = Data.define(:x, :y, :kind, :facing, :patrolling, :ambush, :from)

    # EVERYONE THE FLOOR CAN HOLD, at any setting, because how hard the game is set is not known
    # while the cartridge is built. So all of them are read and each carries the setting it
    # needs; which of them stand up is settled when a floor starts.
    attr_reader :guards

    def initialize(level)
      @level = level
      @guards = level.each_cell.filter_map { |x, y| guard_at(x, y) }
    end

    # ...and the ones a game set THIS way really has.
    def at(difficulty)
      wanted = self.class.number_of(difficulty)
      @guards.select { |guard| guard.from <= wanted }
    end

    def self.number_of(difficulty)
      SETTINGS.index(difficulty) ||
        raise(ArgumentError,
              "there is no difficulty #{difficulty.inspect}; the four are #{SETTINGS.join(', ')}")
    end

    def count = @guards.length
    def empty? = @guards.empty?

    # WHICH KINDS THIS FLOOR HOLDS, in the order a state table lays them out. What reads it is
    # the cartridge, which ships the pictures and the behaviour of the kinds it can meet and
    # nothing else — a floor of nothing but mutants pays for no dogs.
    def kinds = Enemy::ALL.select { |kind| @guards.any? { |g| g.kind == kind.name } }.map(&:name)

    # The pictures this floor needs, which is every picture of every kind standing on it.
    def pictures = kinds.flat_map { |name| Enemy[name].pictures }.uniq.sort

    # Which way one put down facing +facing+ is pointing, as the original numbers directions:
    # counter-clockwise from east, so the four square ones are every other number.
    def self.direction_of(facing) = FACINGS.index(facing) * 2

    # Which way a turning point sends a patrolling guard who reaches it, or nil where the cell
    # holds no turning point.
    def arrow_at(x, y)
      code = @level.thing_code(x, y)
      return nil unless code.between?(FIRST_ARROW, FIRST_ARROW + WAYS.length - 1)

      code - FIRST_ARROW
    end

    private

    def guard_at(x, y)
      kind, within, step = spawn_code(x, y)
      return nil if kind.nil?

      patrolling = within >= FACES
      # A KIND THAT NEVER STANDS reads its standing block as nothing at all, which is the dog:
      # the original has no arm for a standing one, and no floor of the game puts one down.
      return nil if !patrolling && !kind.stands

      Guard.new(x: x, y: y, kind: kind.name,
                facing: FACINGS.fetch(within % FACES),
                patrolling: patrolling,
                ambush: @level.ambush?(x, y),
                from: FROM.fetch(step))
    end

    # Which kind stands here, which of its eight codes this is, and which block it came out of —
    # or nothing where this cell holds no enemy at all. A harder game's codes come down to the
    # same eight. The five kinds' fifteen blocks do not overlap, so the order they are tried in
    # cannot change the answer.
    def spawn_code(x, y)
      code = @level.thing_code(x, y)
      Enemy::ALL.each do |kind|
        FROM.each_index do |step|
          within = code - (step * kind.harder) - kind.standing
          return [kind, within, step] if within >= 0 && within < BLOCK
        end
      end
      nil
    end
  end
end
