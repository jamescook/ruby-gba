# frozen_string_literal: true

module Wolf3D
  # One floor of the game: a 64x64 grid of what is built, and a second of what stands in it.
  #
  # The numbers below were read off all sixty levels of a real GAMEMAPS rather than remembered.
  class Level
    # Plane 0. Everything below this is something you cannot walk through; this and above is
    # floor, and how far above says which area of the level it belongs to.
    FLOOR = 107
    # Walkable, and a guard standing on one is lying in wait: he is the one guard a gunshot does
    # NOT bring, because he has to SEE you before he moves. That is what the tile is for — the
    # men behind doors and in alcoves who are meant to catch you walking past.
    AMBUSH = 106
    # The only codes that turn up between the walls and the floor.
    DOORS = [90, 91, 92, 93, 94, 95, 100, 101].freeze
    LOCKED_DOORS = [92, 93, 94, 95].freeze
    ELEVATOR_DOORS = [100, 101].freeze

    # Plane 1. Exactly one of these per level, and which one says which way you face.
    FACINGS = { 19 => :north, 20 => :east, 21 => :south, 22 => :west }.freeze
    PUSHWALL = 98

    # THE TILE THAT ENDS AN EPISODE, and it is worth knowing that killing the boss is NOT what
    # does it. Walking onto one of these is, which is the original's own rule (wl_agent.cpp,
    # EXITTILE): the boss stands between you and a gold-locked door, and behind that door is the
    # corridor this tile lies in. So the key he leaves is the whole of what killing him buys.
    #
    # Only two floors of the game have one — the ends of the first and fifth episodes, which are
    # exactly the two floors Hans and Gretel stand on. The other bosses end their floors another
    # way, which this cartridge does not build yet.
    EXIT = 99

    # The keys lying on the floor, and which lock each one answers. Checked against the game:
    # every floor of the first episode that has a gold-locked door also has exactly one gold
    # key on it, which it must, or the floor could not be finished.
    KEYS = { 43 => :gold, 44 => :silver }.freeze

    Start = Data.define(:x, :y, :facing)
    Thing = Data.define(:x, :y, :code)

    attr_reader :name, :width, :height

    def initialize(name:, width:, height:, walls:, things:)
      @name = name
      @width = width
      @height = height
      @walls = walls
      @things = things
    end

    def wall_code(x, y) = @walls[(y * @width) + x]
    def thing_code(x, y) = @things[(y * @width) + x]

    def solid?(x, y) = !inside?(x, y) || (wall_code(x, y) < FLOOR && !door?(x, y) && !ambush?(x, y))
    def door?(x, y) = DOORS.include?(wall_code(x, y))
    def locked_door?(x, y) = LOCKED_DOORS.include?(wall_code(x, y))
    def elevator?(x, y) = ELEVATOR_DOORS.include?(wall_code(x, y))
    def ambush?(x, y) = wall_code(x, y) == AMBUSH

    # Is this the tile that ends the episode? See EXIT.
    def exit?(x, y) = thing_code(x, y) == EXIT

    # Every cell of this floor that ends the episode, which is a short run of them side by side
    # or none at all.
    def exits = @exits ||= each_cell.select { |x, y| exit?(x, y) }
    def floor?(x, y) = wall_code(x, y) >= FLOOR || ambush?(x, y)
    def pushwall?(x, y) = thing_code(x, y) == PUSHWALL

    # Which lock a key on this cell answers, or nil if there is no key here.
    def key_at(x, y) = KEYS[thing_code(x, y)]

    # Which key a locked door wants. The codes run in pairs — the two ways a panel can face —
    # so the pair a code sits in is the lock it has.
    def lock_at(x, y)
      code = wall_code(x, y)
      return nil unless LOCKED_DOORS.include?(code)

      (code - LOCKED_DOORS.first) / 2 == 0 ? :gold : :silver
    end

    # Which area of the level a floor cell belongs to. Areas are how the original decides which
    # rooms hear a gunshot.
    def area(x, y)
      code = wall_code(x, y)
      code >= FLOOR ? code - FLOOR : nil
    end

    def inside?(x, y) = x >= 0 && y >= 0 && x < @width && y < @height

    def start
      @start ||= each_cell.filter_map { |x, y| FACINGS[thing_code(x, y)]&.then { |f| Start.new(x: x, y: y, facing: f) } }
                          .first
    end

    # THE SAME FLOOR WITH THE PLAYER PUT DOWN SOMEWHERE ELSE, which is a measuring and demoing
    # tool rather than a way to play — the same kind of dial as which floors to ship.
    #
    # The interesting moments of a game are the far ones: the boss, the floor with sixty guards
    # on it, the room where a dozen things go off at once. Every one of them is a long walk from
    # where the map puts you, and there is no way to look at one without making that walk. This
    # moves the start, which is one cell of plane 1 — so what comes out is an ordinary floor and
    # everything downstream of it reads it the way it reads any other.
    # THE CELL HAS TO BE EMPTY FLOOR, and both halves of that are refused rather than allowed to
    # be nearly right. A wall would leave you inside it. And a cell with something standing on it
    # already — a guard, a clip, the chain gun you were trying to start next to — would have that
    # thing REPLACED by you, silently, which is a demoralising way to find out that the gun you
    # meant to pick up is the one you overwrote.
    def starting_at(x, y, facing: start&.facing || :north)
      raise ArgumentError, "there is no cell #{x},#{y} on #{@name} — it is #{@width}x#{@height}" unless
        inside?(x, y)
      raise ArgumentError, "#{x},#{y} on #{@name} is a wall, so you cannot start there" if solid?(x, y)

      standing = thing_code(x, y)
      unless standing.zero? || FACINGS.key?(standing)
        raise ArgumentError,
              "#{x},#{y} on #{@name} already holds something (code #{standing}). Starting there " \
              "would replace it. Pick an empty cell beside it."
      end

      moved = @things.dup
      moved[(start.y * @width) + start.x] = 0 if start
      moved[(y * @width) + x] = FACINGS.key(facing)
      self.class.new(name: @name, width: @width, height: @height, walls: @walls, things: moved)
    end

    def things
      @things_list ||= each_cell.filter_map do |x, y|
        code = thing_code(x, y)
        Thing.new(x: x, y: y, code: code) if code.positive? && !FACINGS.key?(code)
      end
    end

    def each_cell
      return enum_for(:each_cell) unless block_given?

      @height.times { |y| @width.times { |x| yield x, y } }
    end
  end
end
