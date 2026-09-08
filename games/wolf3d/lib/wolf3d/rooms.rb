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
  # WHAT IT BUYS: measured over every place a player can stand on the second floor, the room you
  # are in holds 1.5 guards of the 29 — so this is not a small saving, it is most of the thinking
  # on every floor after the first.
  #
  # WHAT IT COSTS is one walk over the doors — and NOT once a frame, which it used to be. The
  # answer depends on three things and nothing else: which room the player stands in, which doors
  # are open past AJAR, and which floor is being played. A player changes room a handful of times
  # a minute and a door crosses the post twice an opening, so on the ordinary frame the walk
  # would arrive at exactly last frame's answer. It runs when one of the three moved and not
  # otherwise (see #refresh), which measured 11.2 scanlines a pass off a frame of 372.9.
  #
  # It used to say here that asking all the doors was cheaper than working out whether anything
  # changed. That was worth believing until it was measured: noticing is one comparison inside a
  # walk the doors were doing anyway.
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

    # BRING IT UP TO DATE, WHICH NEARLY ALWAYS MEANS DOING NOTHING. Run once a frame, before
    # anything asks — but the walk itself only when the answer can have moved since the last one.
    #
    # THE ANSWER DEPENDS ON THREE THINGS AND NOTHING ELSE: which room the player is standing in,
    # which doors are open past AJAR, and which floor is being played. A player changes room a
    # handful of times a minute and a door crosses the post twice an opening, so on the ordinary
    # frame there is nothing to work out — and the walk was being done anyway, at a tenth of the
    # whole frame, to arrive at last frame's answer again.
    #
    # WHICH ROOM THE PLAYER IS IN IS READ HERE rather than inside the walk, because it is one
    # table read and it is half of the question being asked. The other half is a flag the doors
    # set when one of them moves (see #a_door_moved) and a floor start sets when it changes the
    # map underneath all of this.
    def refresh
      where_the_player_stands
      ((@here != @was_here) | (@changed == 1)).then do
        @was_here.set @here
        @changed.set 0
        @b.call(:which_rooms_are_open)
      end
    end

    # WHICH ROOM THE PLAYER IS IN, and it is REMEMBERED rather than read fresh, because there are
    # cells that are in no room and the player walks through them constantly: a doorway is one.
    # Read fresh, standing in a doorway would say "no room", and then no room at all would be
    # open and every lamp in the level would blink out for the two steps it takes to walk
    # through. The room they were last really in is the right answer there — a doorway they are
    # standing in is open by definition, so the room on the other side of it is open too.
    def where_the_player_stands
      @stood.set(@room_of[@map_base + (@player[:y].to_i * @width) + @player[:x].to_i])
      (@stood > NOWHERE).then { @here.set @stood }
    end

    # A DOOR MOVED, so the walk has to be done again. Said by the doors rather than worked out
    # here: they already walk every door every frame and already hold what each one was before
    # they moved it, so noticing is one comparison where asking again would be the walk itself.
    #
    # It says "moved at all" rather than "crossed the post". A door takes about twenty frames to
    # slide and this recomputes on each of them where two would do, which is twenty frames in a
    # doorway's lifetime against a test that would have to hold the old side of the post as well.
    # Being early is also the safe way to be wrong.
    def a_door_moved = @changed.set(1)

    # ...and so does starting a floor, which changes the map every part of this reads through.
    def floor_started = @changed.set(1)

    # Is the room at this cell open to the player's? +x+ and +y+ are where something stands, as
    # the game keeps them.
    def open_to_the_player?(x, y)
      @room.set(@room_of[@map_base + (y.to_i * @width) + x.to_i])
      open?(@room)
    end

    # ...and the same question asked of a room NUMBER, for anything that was told its room while
    # the cartridge was built and does not have to work it out again. A piece of scenery never
    # moves, so this is what it asks.
    def open?(room) = @open_room[room] == 1

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

      @always = always_joined
      @room, @here, @stood, @spread, @near, @far =
        whole(:room, :here, :stood, :spread, :near, :far)
      # WHAT THE LAST WALK WAS ABOUT, so this one can tell whether it would say anything new.
      # The room starts at one nothing can be in and the flag starts set, so the first frame of
      # the game does the walk however it starts. Declared with those values rather than assigned
      # them, because a variable's starting value is applied once at boot wherever it is written.
      @was_here = b.var(:_room_was_here, -1)
      @changed = b.var(:_room_changed, 1)
      declare_the_fill
    end

    # WORKING ROOM OF ITS OWN, and the prefix is not tidiness. Every class here names its scratch
    # by what it is for — :here, :spot, :near — and they all land in one flat set of names, so two
    # classes that pick the same word get the same variable and quietly write over each other.
    # This was not theory: :here is also where the view keeps the map cell under the player's
    # feet, and sharing it put a door code where a room number goes.

    # THE ROOMS A WALL THAT SLIDES CAN JOIN. A door is not quite the only way one room opens onto
    # another: shove a secret wall and what is behind it is open too, and no door was involved.
    #
    # Almost never does that matter, and the almost is measured rather than assumed — over the
    # whole first episode, ONE secret wall of sixty-seven has different rooms on either side of
    # it. Every other one opens into the room it was already part of.
    #
    # So the pair is simply joined for good rather than watched. It costs one join in a fill that
    # runs once a frame, on the one floor that has such a wall and on no other; what it buys is
    # that nothing standing in the secret room can ever fail to be drawn. The other way round —
    # watching whether the wall has moved — is more code in the same loop for every floor, to save
    # nothing anybody can see.
    def always_joined
      @floors.flat_map { |floor| floor.pushwalls.walls.map { |wall| rooms_round(floor.level, wall) } }
             .select { |pair| pair.length == 2 }
             .uniq
    end

    def rooms_round(level, wall)
      [[1, 0], [-1, 0], [0, 1], [0, -1]].filter_map do |dx, dy|
        x = wall.x + dx
        y = wall.y + dy
        level.area(x, y)&.+(1) if level.inside?(x, y)
      end.uniq
    end

    def whole(*names) = names.map { |name| @b.var(:"_room_#{name}", 0) }

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

      # Which room the player is in was read by the caller, which is where the decision to run
      # this at all was made — see #where_the_player_stands.
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
        # THE ROOMS THAT ARE ALWAYS JOINED, if this cartridge has any — see always_joined.
        @always.each { |near, far| join(near, far) }
        b.repeat(@door_count, estimate: how_many_doors) do |door|
          (@open[door] > AJAR).then do
            @near.set(@side_a[@door_first + door])
            @far.set(@side_b[@door_first + door])
            join(@near, @far)
          end
        end
      end
    end

    # Two rooms are one room from here on. Both ways round, because the walk over the doors meets
    # them in whatever order the level lists them.
    def join(near, far)
      ((@open_room[near] == 1) & (@open_room[far] == 0)).then { @open_room[far] = 1; @spread.set 1 }
      ((@open_room[far] == 1) & (@open_room[near] == 0)).then { @open_room[near] = 1; @spread.set 1 }
    end

    # For the estimate only — the walk is over however many doors THIS floor has, which is a
    # number the game works out, so the report is told what a floor usually holds.
    def how_many_doors
      counts = @floors.counts_of(:doors)
      { usually: [(counts.sum.to_f / counts.length).ceil, 1].max, most: [counts.max, 1].max }
    end
  end
end
