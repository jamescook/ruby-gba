# frozen_string_literal: true

module Wolf3D
  # The doors of one floor: where they are, which way their panels run, what opens them, and
  # which picture each one wears.
  #
  # A DOOR IS NOT A WALL IN ITS CELL. It is a panel standing across the MIDDLE of the cell, so
  # the half cell either side of it is open space you walk into before the door stops you. That
  # is why a doorway has visible depth in this game, and it is the whole reason the ray has to
  # do something special here rather than stopping at the cell's edge like everything else.
  #
  # A panel runs one way or the other, and the level says which by the parity of the code —
  # read off the first ten floors of a real GAMEMAPS, where 323 doors agreed with no exceptions:
  # an even code has walls to its north and south, so it sits in a corridor running east-west
  # and its panel runs north-south.
  class Doors
    # Which way a panel runs, named by the grid lines it is parallel to. A panel running
    # north-south is met by a ray crossing in x, which is the side the walk already calls 0.
    ACROSS_X = 0
    ACROSS_Y = 1

    # The last eight wall pictures, just before the sprites start, are the doors. Four light
    # and dark pairs, in the order the original uses them.
    DOOR_PICTURES = 8
    FACE = 0     # a plain door
    JAMB = 2     # the wall beside a doorway, which has a metal edge
    ELEVATOR = 4 # the one that ends the floor
    LOCKED = 6   # the one that wants a key

    Door = Data.define(:x, :y, :across, :picture, :lock)

    attr_reader :doors

    def initialize(level, vswap)
      @level = level
      @first_door_picture = vswap.wall_count - DOOR_PICTURES
      @doors = level.each_cell.filter_map { |x, y| door_at(x, y) }
    end

    def count = @doors.length

    def empty? = @doors.empty?

    # Which door stands in a cell, counting from one, or nil. The ray walk and the player's
    # feet both ask this, so it is one table rather than a search.
    def number_at(x, y)
      @number ||= @doors.each_with_index.to_h { |door, i| [[door.x, door.y], i + 1] }
      @number[[x, y]]
    end

    # The VSWAP picture a door wears. A panel running north-south wears the lit one and a panel
    # running east-west the darker one, which is the same trick every wall in the game uses to
    # tell you which way a face is turned.
    def picture_for(door) = @first_door_picture + door.picture + door.across

    # The pictures a level needs on top of its walls: every door's own, and the jamb.
    def pictures
      wanted = @doors.map { |door| picture_for(door) }
      wanted += [@first_door_picture + JAMB, @first_door_picture + JAMB + 1]
      wanted.uniq.sort
    end

    private

    def door_at(x, y)
      return nil unless @level.door?(x, y)

      code = @level.wall_code(x, y)
      Door.new(x: x, y: y,
               across: code.even? ? ACROSS_X : ACROSS_Y,
               picture: picture_kind(x, y),
               lock: @level.lock_at(x, y))
    end

    def picture_kind(x, y)
      return ELEVATOR if @level.elevator?(x, y)
      return LOCKED if @level.locked_door?(x, y)

      FACE
    end
  end
end
