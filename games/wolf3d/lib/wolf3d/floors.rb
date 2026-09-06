# frozen_string_literal: true

module Wolf3D
  # EVERY FLOOR THE CARTRIDGE HOLDS, and the one idea that makes more than one of them possible.
  #
  # THE PROBLEM. Everything this renderer reads is a table in the cartridge, built while the ROM
  # is: the map, which cells stop a foot, where each door is and what it wears, where the walls
  # that move started, where every guard stands, what is lying on the floor. All of it was built
  # for one floor and read from nought.
  #
  # THE ANSWER IS NOT SIXTY COPIES OF THE CODE. It is one copy of the code and sixty of the DATA:
  # every table holds all the floors end to end, and reading one is the same read with a number
  # added. That number is set once when a floor starts and does not change while it is played, so
  # what it costs in the walk that reads the map thousands of times a frame is a single add.
  #
  # WHERE EACH FLOOR'S SLICE BEGINS is settled here, while building. The game does not look it up:
  # starting a floor runs one arm per floor that sets the handful of numbers for it, which is a
  # great deal of code that runs a few times a game and none at all while it is being played.
  #
  # WHAT IS NOT CONCATENATED is the state a floor is played with — how far each door has swung,
  # which guards are still up, what has been taken. Those are lists in the console's memory and
  # they are sized for the WORST floor rather than for all of them added together, because only
  # one floor is ever being played. That is also why a door in the map is numbered within its own
  # floor and not across the whole cartridge.
  class Floors
    # One floor, and everything read off it while building.
    Floor = Data.define(:index, :level, :doors, :pushwalls, :lifts, :guards, :scenery)

    include Enumerable

    attr_reader :floors

    # +maps+ is the whole GAMEMAPS; +which+ the floor numbers to ship, in the order the game
    # plays them. +vswap+ is wanted only because a door's picture comes out of it.
    def self.from(maps, vswap, which)
      new(which.map do |index|
        level = maps[index]
        Floor.new(index: index, level: level,
                  doors: Doors.new(level, vswap),
                  pushwalls: Pushwalls.new(level),
                  lifts: Elevator.new(level),
                  guards: Guards.new(level),
                  scenery: Scenery.new(level))
      end)
    end

    # ...and the one-floor case, which is what every test builds and what a cartridge with no
    # progression is. Given the pieces already made rather than making them again.
    #
    # NOTHING IS MADE UP HERE. A piece left out was left out on purpose — a floor built with no
    # scenery is a game that draws nothing standing in the rooms, which is what the tests of the
    # doors and their keys are — so a nil stays a nil rather than becoming an empty one.
    def self.of(level:, doors:, pushwalls:, lifts: nil, guards: nil, scenery: nil)
      new([Floor.new(index: 0, level: level, doors: doors, pushwalls: pushwalls,
                     lifts: lifts, guards: guards, scenery: scenery)])
    end

    def initialize(floors)
      raise ArgumentError, "a game needs at least one floor" if floors.empty?

      @floors = floors
      check_they_are_all_the_same_size!
    end

    def count = @floors.length
    def each(&) = @floors.each(&)
    def [](index) = @floors[index]
    def first_floor = @floors.first

    # Every floor is the same shape, which is what lets one number reach into the map table: the
    # slice of floor N starts at N times the cells in one. Wolfenstein's own levels are all 64 by
    # 64 and the reader would have to change for anything else, so this is checked rather than
    # assumed — a mixed set would read every map after the first from the wrong place.
    def width = first_floor.level.width
    def height = first_floor.level.height
    def cells = width * height

    # Where floor N's own cells begin in the map table.
    def map_base(n) = n * cells

    # WHERE EACH FLOOR'S SLICE OF A LIST BEGINS, by name. A floor's doors sit after every door of
    # every floor before it, and so on for each kind of thing a floor holds a list of.
    def first_of(kind, n) = @floors.take(n).sum { |floor| how_many(kind, floor) }
    def count_of(kind, n) = how_many(kind, @floors[n])

    # How many of a thing each floor holds, in order.
    def counts_of(kind) = @floors.map { |floor| how_many(kind, floor) }

    # ...and the most any one floor holds, which is what the lists played with are sized for.
    def most(kind) = counts_of(kind).max

    KINDS = %i[doors pushwalls lifts guards pieces].freeze

    private

    def how_many(kind, floor)
      case kind
      when :doors     then floor.doors.count
      when :pushwalls then floor.pushwalls.count
      when :lifts     then floor.lifts&.count || 0
      when :guards    then floor.guards&.count || 0
      when :pieces    then floor.scenery&.count || 0
      else raise ArgumentError, "no such thing on a floor: #{kind}"
      end
    end

    def check_they_are_all_the_same_size!
      odd = @floors.find { |floor| floor.level.width != width || floor.level.height != height }
      return unless odd

      raise ArgumentError,
            "floor #{odd.index} is #{odd.level.width}x#{odd.level.height} and floor " \
            "#{first_floor.index} is #{width}x#{height}. Every floor in one cartridge must be " \
            "the same size, because the map table holds them end to end."
    end
  end
end
