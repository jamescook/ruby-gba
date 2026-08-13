# frozen_string_literal: true

module Wolf3D
  # One floor of the game: a 64x64 grid of what is built, and a second of what stands in it.
  #
  # The numbers below were read off all sixty levels of a real GAMEMAPS rather than remembered.
  class Level
    # Plane 0. Everything below this is something you cannot walk through; this and above is
    # floor, and how far above says which area of the level it belongs to.
    FLOOR = 107
    # Walkable, but a guard standing on one does not notice you until you shoot.
    AMBUSH = 106
    # The only codes that turn up between the walls and the floor.
    DOORS = [90, 91, 92, 93, 94, 95, 100, 101].freeze
    LOCKED_DOORS = [92, 93, 94, 95].freeze
    ELEVATOR_DOORS = [100, 101].freeze

    # Plane 1. Exactly one of these per level, and which one says which way you face.
    FACINGS = { 19 => :north, 20 => :east, 21 => :south, 22 => :west }.freeze
    PUSHWALL = 98

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
