# frozen_string_literal: true

module Wolf3D
  # The secret walls: a cell built as wall, marked in the things plane, that slides two cells
  # away when you lean on it and opens a passage behind.
  #
  # THE MAP IS IN THE CARTRIDGE AND CANNOT BE WRITTEN TO, which is the whole problem here. A
  # door solves it by never moving — its panel slides within a cell it always occupies — but a
  # push wall leaves its cell entirely and ends up somewhere the map still calls floor.
  #
  # So the map marks every cell a push wall COULD ever reach, not the one it is in: its own,
  # and up to two along each of the four directions where the floor allows it. That is at most
  # nine cells out of four thousand. A ray or a foot that lands on one of them asks the wall
  # where it is now and gets a yes or a no, which is a handful of arithmetic on a cell almost
  # nothing ever touches. Every other cell in the level is untouched by any of this.
  class Pushwalls
    # How far one can go, and how many frames it takes over each cell.
    DISTANCE = 2
    FRAMES_PER_CELL = 45

    Wall = Data.define(:x, :y, :code, :reach)

    attr_reader :walls

    def initialize(level)
      @level = level
      @walls = level.each_cell.filter_map { |x, y| wall_at(x, y) }
    end

    def count = @walls.length

    def empty? = @walls.empty?

    # Which push wall could ever stand in this cell, counting from one, or nil. A cell reached
    # by two of them keeps the first; they are rare and rarely near each other.
    def number_at(x, y)
      @reachable ||= @walls.each_with_index.each_with_object({}) do |(wall, index), found|
        wall.reach.each { |cell| found[cell] ||= index + 1 }
      end
      @reachable[[x, y]]
    end

    # Where every push wall starts, as one number per wall — a flat cell number, which is what
    # the game works with.
    def homes = @walls.map { |wall| (wall.y * @level.width) + wall.x }

    def codes = @walls.map(&:code)

    private

    def wall_at(x, y)
      return nil unless @level.pushwall?(x, y) && @level.solid?(x, y)

      Wall.new(x: x, y: y, code: @level.wall_code(x, y), reach: reachable_from(x, y))
    end

    # Its own cell, and the cells it could slide into. It stops at the first thing in its way,
    # so a direction contributes cells only while the floor keeps going.
    def reachable_from(x, y)
      cells = [[x, y]]
      [[1, 0], [-1, 0], [0, 1], [0, -1]].each do |dx, dy|
        DISTANCE.times do |step|
          cell = [x + (dx * (step + 1)), y + (dy * (step + 1))]
          break if @level.solid?(*cell)

          cells << cell
        end
      end
      cells
    end
  end
end
