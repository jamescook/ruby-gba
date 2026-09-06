# frozen_string_literal: true

module Wolf3D
  # WHICH ROOMS OF THIS FLOOR ARE OPEN TO THE ONE THE PLAYER IS STANDING IN.
  #
  # A LEVEL IS DIVIDED INTO ROOMS and the division is already in the map: a floor cell's code is
  # 107 plus the room it belongs to. Rooms are joined only by DOORS, so which of them are open to
  # the player is a matter of which doors are open — and that answer is the same for everything on
  # the floor, so it is worked out once a frame here rather than per guard, per shot, per lamp.
  #
  # This is NOT about guards, though guards are the first thing to ask it. It is a fact about the
  # level, and the original uses the same fact to decide which rooms hear a gunshot.
  #
  # WHY IT EXISTS AT ALL. A guard's think is nearly all line of sight — a walk from him to you
  # asking what is between — and it was walked whether he stood in the next room or on the far
  # side of the floor. The first floor of the first episode has ten guards and the second has
  # twenty-nine, and that alone was thirty frames a second falling to twenty. The original refuses
  # to think for a guard whose room is shut off (wl_play.cpp, DoActor):
  #
  #     if (!ob->active && !areabyplayer[ob->areanumber])
  #         return;
  #
  # A guard who has been SEEN is awake and thinks wherever he is, for ever after — otherwise one
  # visible across a courtyard you cannot walk into would stand frozen while you watched him. That
  # half is kept beside the drawing, which is the only thing that knows he was on the screen.
  #
  # WHAT IT COSTS is one walk over the doors, once a frame, and it is not conditional on anything:
  # a door either is or is not open, and asking all of them is cheaper than working out whether
  # anything changed since last time. Measured over every place a player can stand on the second
  # floor, the room you are in holds 1.5 guards of the 29 — so this is not a small saving, it is
  # most of the thinking on every floor after the first.
  class Rooms
    # 0 IS NOT A ROOM. A wall belongs to none, and neither does a doorway or one of the ambush
    # cells the game marks with a code of its own — so every room is stored one higher and nought
    # is left to mean "nowhere in particular". Nought is always open, so anything standing on such
    # a cell thinks: a guard in a doorway is by definition at the join between two rooms, and the
    # original, which stores the raw number, reads off the end of its own array there.
    NOWHERE = 0

    # A door is joined while it is off the shut post at all, which is what the original does — it
    # counts the join the moment the door STARTS opening rather than when it finishes.
    AJAR = 0.0

    # Does this cartridge need any of it? A floor that is all one room has nothing to shut off,
    # and a cartridge with no doors on any floor can never join two rooms anyway — either way
    # every room is always reached and none of this is emitted. The sibling of Billboards.needed?.
    def self.needed?(floors)
      floors.any? { |floor| rooms_in(floor.level).length > 1 } &&
        floors.any? { |floor| floor.doors.count.positive? }
    end

    def self.rooms_in(level)
      level.each_cell.filter_map { |x, y| level.area(x, y) }.uniq
    end

    def initialize(build:, floors:, map_base:, door_first:, door_count:, door_open:, player:)
      @b = build
      @floors = floors
      @map_base = map_base
      @door_first = door_first
      @door_count = door_count
      @open = door_open
      @player = player
      @width = floors.width
      declare
    end

    # Bring it up to date: run once a frame, before anything asks.
    def refresh = @b.call(:which_rooms_are_open)

    # Is the room at this cell open to the player's? +x+ and +y+ are where something stands, as
    # the game keeps them.
    def open_to_the_player?(x, y)
      @room.set(@room_of[@map_base + (y.to_i * @width) + x.to_i])
      @open_room[@room] == 1
    end

    private

    def declare
      b = @b

      # THE ROOM EACH CELL BELONGS TO, every floor end to end like the map itself and reached the
      # same way. One byte a cell: the game has 37 rooms at the most and this leaves room for 255.
      @room_of = b.table :room_of, @floors.flat_map { |floor|
        floor.level.each_cell.map { |x, y| (floor.level.area(x, y)&.+(1)) || NOWHERE }
      }, width: :byte

      # WHICH TWO ROOMS EACH DOOR JOINS, worked out while building because a door never moves.
      # A door that does not have a room on both sides joins nothing and is simply never followed.
      sides = @floors.flat_map { |floor| floor.doors.doors.map { |door| joins(floor.level, door) } }
      sides = [[NOWHERE, NOWHERE]] if sides.empty?
      @side_a = b.table :door_side_a, sides.map(&:first), width: :byte
      @side_b = b.table :door_side_b, sides.map(&:last), width: :byte

      # WHICH ROOMS ARE OPEN RIGHT NOW, one entry a room. Written every frame, so it is a list
      # rather than a table.
      @count = most_rooms + 1
      @open_room = b.list :room_open, capacity: @count
      @count.times { @open_room << 0 }

      @room, @here, @spread, @near, @far = whole(:room, :here, :spread, :near, :far)
      declare_the_fill
    end

    def whole(*names) = names.map { |name| @b.var(:"_#{name}", 0) }

    # The rooms either side of a door. A panel running one way has its neighbours the other way.
    def joins(level, door)
      pair = door.across == Doors::ACROSS_X ? [[-1, 0], [1, 0]] : [[0, -1], [0, 1]]
      pair.map do |dx, dy|
        x = door.x + dx
        y = door.y + dy
        (level.inside?(x, y) && level.area(x, y)&.+(1)) || NOWHERE
      end
    end

    # The most rooms any one floor has, which is what the list is sized for — only one floor is
    # ever being played. Numbered from one, so the count is the highest number.
    def most_rooms = @floors.map { |floor| self.class.rooms_in(floor.level).max.to_i + 1 }.max

    # A ROUTINE, and told to stay OUT of the quick memory, which is the same instruction
    # :guard_thinking carries and for the same reason — with one extra twist worth writing down.
    #
    # This runs ONCE a frame. What it displaced when it was allowed in was
    # :remember_a_standing_thing, which runs once for every guard and every piece of scenery in
    # front of the eye — hundreds of times a frame. The swap cost more than everything this
    # saves, and floor two went from twenty frames a second to fifteen: the change was measured
    # as a LOSS until this line was added.
    #
    # WHY THE FRAMEWORK CHOSE WRONG is not the framework being wrong. It ranks routines by what a
    # frame costs, and the walk below is bounded by a floor's whole count of rooms — a ceiling it
    # reaches only if every door on the floor stands open in one chain. That worst case is real,
    # it is what an honest estimate has to report, and it is nothing like what a frame really
    # pays. A ceiling far above the usual case is exactly when to say so by hand.
    def declare_the_fill
      @b.func(:which_rooms_are_open, fast: false) { fill }
    end

    def fill
      b = @b
      b.repeat(@count) { |room| @open_room[room] = 0 }
      # Nowhere in particular is always open — see NOWHERE.
      @open_room[NOWHERE] = 1
      @here.set(@room_of[@map_base + (@player[:y].to_i * @width) + @player[:x].to_i])
      @open_room[@here] = 1

      # SPREAD THROUGH THE OPEN DOORS UNTIL NOTHING MORE OPENS. Two rooms joined by an open door
      # are one room as far as this is concerned, and a run of open doors joins the lot — so a
      # single walk over the doors is not enough, and it is walked again until a walk changes
      # nothing.
      #
      # A ROOM CANNOT BE OPENED TWICE, so a floor's own count of rooms is a ceiling no run of
      # doors can beat and the answer is exact rather than near enough. What it usually takes is
      # ONE walk: almost every door in this game is shut almost all the time, so the first walk
      # finds nothing to spread and the second never happens.
      #
      # SET BEFORE THE LOOP because a loop that stops early is asked whether to stop BEFORE its
      # first pass as well as after it. Left at what the last frame finished on — nought, always,
      # since that is what ends it — the walk would never run at all.
      @spread.set 1
      b.repeat(@count, stop_when: @spread == 0, estimate: { usually: 1 }) do
        @spread.set 0
        b.repeat(@door_count, estimate: how_many_doors) do |door|
          (@open[door] > AJAR).then do
            @near.set(@side_a[@door_first + door])
            @far.set(@side_b[@door_first + door])
            ((@open_room[@near] == 1) & (@open_room[@far] == 0))
              .then { @open_room[@far] = 1; @spread.set 1 }
            ((@open_room[@far] == 1) & (@open_room[@near] == 0))
              .then { @open_room[@near] = 1; @spread.set 1 }
          end
        end
      end
    end

    # For the estimate only — the walk is over however many doors THIS floor has, which is a
    # number the game works out, so the report is told what a floor usually holds.
    def how_many_doors
      counts = @floors.counts_of(:doors)
      { usually: [(counts.sum.to_f / counts.length).ceil, 1].max, most: [counts.max, 1].max }
    end
  end
end
