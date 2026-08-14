# frozen_string_literal: true

module Wolf3D
  # The view down the corridor.
  #
  # For each strip across the screen a ray goes out from the player until it meets a wall. How
  # far it got becomes a height — near walls tall, far walls short — and a column of that wall's
  # picture is stretched to it. Do that across the screen and a flat grid of cells looks like
  # rooms you can walk through.
  class FirstPerson
    # These are the view the game should have, not the view that happens to fit a frame.
    COLUMNS = 80          # strips across the screen...
    COLUMN_W = 3          # ...three pixels each
    TURN = 512            # angle units in a full turn
    QUARTER = TURN / 4
    CROSSINGS = 48        # grid lines a ray may cross before it gives up — about 24 cells

    # HOW WIDE THE VIEW IS, which is one angle unit per strip — about 56 degrees across, near
    # the 60 the original uses.
    #
    # It was two units, and that made a view of 111 degrees. A wide view is not a neutral
    # choice: perspective genuinely stretches whatever is at the edge of it, and at 111
    # degrees the strip at the edge covers three times the world the strip in the middle does,
    # where at 60 degrees it covers one and a third. That stretch is what reads as a bend when
    # you look along a wall rather than at it.
    SPREAD = 1

    # The furthest one crossing can be worth. A ray running almost along an axis meets that
    # axis's lines almost never, and one over almost-nothing is too big to hold — so it is
    # held here, at a distance longer than any crossing on a map this size.
    FAR = 128.0

    # Where the map table stops naming walls and starts naming the two things that move. Both
    # are above every picture a level could hold, so none of the three can be confused.
    DOOR = 512
    PUSH = 1024

    # HOW FAR OPEN A DOOR IS: 0 is shut and 1 is out of the way, which is the same thing the
    # ray asks about, so nothing has to be converted where the two meet.
    DOOR_WIDE = 1.0
    DOOR_STEP = 0.05         # a frame, so about half a second to swing
    DOOR_LINGER = 180        # and three seconds standing open before it shuts again
    DOOR_WALKABLE = 0.75     # open this far and you fit through
    DOOR_REACH = 0.75        # how far in front of you a door is close enough to open

    # Which bit of what the player carries each key is.
    KEY_BITS = { gold: 1, silver: 2 }.freeze

    TEX = WallAtlas::SIDE # a wall picture is this many columns across...
    PAIR = TEX * 2        # ...and each wall keeps two of them, lit then dark
    ACROSS = 240          # pixels across the screen
    DOWN = 160            # ...and down it

    # HOW MUCH OF THE SCREEN THE VIEW GETS. The status bar takes the rest, along the bottom, the
    # way the original arranges it — and the eye line sits in the middle of what is left, because
    # the middle of the VIEW is what a horizon is, not the middle of the screen.
    VIEW_H = DOWN - StatusBar::HEIGHT
    HORIZON = VIEW_H / 2

    # HOW TALL A WALL ONE CELL AWAY STANDS, and it is not a free choice. It is the distance
    # from the eye to the screen measured in pixels, and that follows from how wide the view
    # is: a narrower view is a longer lens, and a longer lens makes everything bigger. Pick it
    # independently of SPREAD and the picture is stretched one way or the other — walls too
    # squat for the width of the view, or too tall for it.
    HALF_VIEW = (COLUMNS - 1) * SPREAD / 2.0 # angle units from the middle of the view to its edge
    WALL_SCALE = (ACROSS / 2) / Math.tan(HALF_VIEW * 2 * Math::PI / TURN)

    WALK = 0.07
    TURN_SPEED = 6

    # What the player starts with. A hundred of health and eight bullets, which is what the
    # original hands you at the top of a floor.
    START_HEALTH = 100
    START_AMMO = 8

    CEILING = RubyGBA::Color.rgb(7, 7, 9)
    FLOOR_COLOR = RubyGBA::Color.rgb(12, 11, 10)

    def initialize(build:, level:, atlas:, doors:, pushwalls:, guards: nil, things: nil,
                   scenery: nil)
      @b = build
      @level = level
      @atlas = atlas
      @doors = doors
      @pushwalls = pushwalls
      @guards = guards
      @scenery = scenery
      @things = things
      declare
    end

    # One pass of the game loop: what a press does, and then what you see. What MOVES is not
    # here — see `declare_the_clock`.
    def update
      play
      draw
    end

    # WHAT A PRESS DOES, and it is the half of the game that belongs to a PASS rather than to
    # the clock: a button read on its edge has to be read once per press, not once per frame the
    # pass answered for, or a slow frame would fire three bullets for one pull of the trigger.
    #
    # A DEAD PLAYER DOES NOT SHOOT, which is the whole of dying until there is a screen to say
    # so. The guards go on about their business around the body, which is what the original does
    # too while the death is playing out.
    def play
      (@health > 0).then do
        open_a_door
        fire if @mind
      end
    end

    # ...AND WHAT MOVES, once for each frame that really passed rather than once per pass.
    #
    # THIS IS THE DIFFERENCE BETWEEN SLOW MOTION AND CHOPPINESS, and it is the whole of what
    # this routine is for. Everything below moves a fixed amount: the player walks a fraction of
    # a cell, a door swings a little wider, a guard's state machine advances two of the
    # original's seventieths. Run that once per PASS and a game too heavy for a frame plays at
    # half speed — smoothly, and at the wrong speed. Run it once per FRAME and the world keeps
    # real time however long the picture took, which is what the original does (it moves you
    # `BASEMOVE * MOVESCALE * tics`, where tics is how long the last frame took).
    #
    # A LONG FRAME CANNOT PUT YOU THROUGH A WALL, and here that is true by construction rather
    # than by a rule. The original multiplies its step by how late it is, so it needs a cap
    # (MAXTICS) to stop a big step stepping over a wall between one collision test and the next.
    # This runs the ordinary step again instead — each one with its own collision test — so
    # there is no big step to guard. (The framework caps the catch-up anyway, so a very late
    # pass is never asked to replay half a second.)
    #
    # It is also the half a test of doors wants. The drawing costs about a hundred times what
    # this does — eighty rays and eighty stretched columns against a few dozen statements — so a
    # test that walks a player across a room to see whether a door opens spends all its time on
    # a picture it never looks at. A game loop that only calls #play still runs this, because it
    # is the frame boundary that drives it.
    def declare_the_clock
      @b.once_a_frame(:the_world_moves) do
        (@health > 0).then { walk }

        if @standing
          # Which way the eye points, worked out once a frame: the shot needs it and so does
          # everything the view draws standing in the room.
          @vcos.set(@sin[@view + QUARTER])
          @vsin.set(@sin[@view])
        end
        @mind&.update
      end
    end

    # ONE PRESS, ONE BULLET. The button is read on the press rather than held, so the pistol
    # fires as fast as you can tap it and no faster.
    def fire
      @b.pressed(:b).then do
        (@ammo > 0).then do
          @ammo.sub 1
          @mind.shoot
        end
      end
    end

    # ...and what the player sees of it: the room, a wall column per strip, then whatever is
    # standing in the room, which has to go last so it can be put behind the walls. Then the
    # status bar, which is outside the view and so is not held to it.
    #
    # THE VIEW IS DRAWN INSIDE ITS OWN ROWS rather than over the whole screen with the bar
    # painted on top afterwards, and that is worth its one line. A wall you are close to is
    # drawn taller than the screen — that is what perspective says and the renderer no longer
    # argues with it — so without this the rows under the bar are worked out, written, and then
    # covered. Measured over a floor of the real game, one row in twelve.
    def draw
      @b.inside 0, 0, ACROSS, VIEW_H do
        @b.dma_fill_rect 0, 0, ACROSS, HORIZON, CEILING
        @b.dma_fill_rect 0, HORIZON, ACROSS, VIEW_H - HORIZON, FLOOR_COLOR
        @b.repeat(COLUMNS) { |col| cast(col) }
        @standing&.draw
      end
      @bar.draw
    end

    private

    def declare
      b = @b
      @sin = b.table :sin, (0...TURN).map { |a| Math.sin(a * 2 * Math::PI / TURN) }

      # One over the sine, which is what the walk below needs: how far along a ray it is from
      # one grid line to the next. Worked out here once for every angle rather than divided
      # for every strip of every frame — dividing two numbers that hold a fraction is the
      # dearest arithmetic there is, and reading a table is a fraction of it.
      #
      # INVERTED FROM THE SINE THE GAME WILL ACTUALLY READ, not from the true one. A table
      # holds a number to a fixed number of places, so the sine the walk uses is a hair off
      # the real sine — and if this were the true reciprocal the two would not quite cancel,
      # which shows up as a flat wall whose top edge wanders by a pixel.
      @reach = b.table :reach, (0...TURN).map { |a|
        toward = held(Math.sin(a * 2 * Math::PI / TURN)).abs
        toward > (1.0 / FAR) ? 1.0 / toward : FAR
      }

      # THE MAP AS ONE FLAT TABLE, and it says three things in one number so that the walk asks
      # one question per step rather than two. 0 is open floor. Anything up to DOOR is a wall,
      # and the number is where its lit picture sits in the row of pictures, counting from one —
      # so the walk adds which way the face turns and has the picture. DOOR and above is a
      # doorway, and what is left over is which door.
      #
      # Keeping doors in the same table is what makes them nearly free: the walk already tests
      # "is there anything here", and that test is false almost every step. Only when something
      # IS here does it go on to ask which kind, and by then the ray has stopped anyway.
      @world = b.table :world, @level.each_cell.map { |x, y| cell_value(x, y) }

      # WHICH CELLS HOLD SOMETHING A FOOT CANNOT PASS, and it is a table of its own rather than
      # a fifth meaning in the one above. A barrel is the first thing in this game that stops
      # you without being made of wall: your feet must not go there, and a ray MUST — you can
      # see past a barrel, and a ray that stopped at one would leave a barrel-shaped hole of
      # nothing in the room behind it.
      #
      # The walk over the map is by far the hottest thing here and it reads the table above
      # thousands of times a frame. Keeping this apart means the walk never learns the
      # difference, and the cost lands where it belongs: on the two questions a pair of feet
      # asks each frame.
      @blocked = declare_the_blocking

      # How far open each door is: 0 is shut, 1 is out of the way. A door is only ever moving
      # toward one or the other, so this one number is its whole state, and the count beside it
      # is how long it still has to stand open.
      @open = b.list :door_open, capacity: [@doors.count, 1].max, holds: 0.0
      @linger = b.list :door_linger, capacity: [@doors.count, 1].max

      # Which picture each door wears, worked out while building — a door's panel does not
      # turn, so unlike a wall it needs no choosing as the game runs.
      @door_picture = b.table :door_picture, some(door_pictures), width: :byte
      @door_across = b.table :door_across, some(@doors.doors.map(&:across)), width: :byte
      # Which key each door wants, as the bit the player carries. Nought wants none.
      @door_lock = b.table :door_lock, some(@doors.doors.map { |d| KEY_BITS[d.lock] || 0 }), width: :byte

      # A push wall: where it started, what it is made of, and — as the game runs — which way
      # it was shoved, how far it has got, and how long until its next cell.
      @push_home = b.table :push_home, some(@pushwalls.homes)
      @push_face = b.table :push_face, some(push_pictures), width: :byte
      @push_step = b.list :push_step, capacity: [@pushwalls.count, 1].max
      @push_gone = b.list :push_gone, capacity: [@pushwalls.count, 1].max
      @push_wait = b.list :push_wait, capacity: [@pushwalls.count, 1].max

      # Which keys the player is carrying, one bit each.
      @keys = b.var :keys, 0
      @key_taken = b.list :key_taken, capacity: [key_cells.length, 1].max
      @key_cell = b.table :key_cell, some(key_cells.map { |c| c[:cell] })
      @key_bit = b.table :key_bit, some(key_cells.map { |c| c[:bit] }), width: :byte
      @key_thing = b.table :key_thing, some(key_cells.map { |c| c[:thing] }), width: :half

      b.image :walls, width: @atlas.width, height: @atlas.height, data: @atlas.pixels

      start = @level.start
      @px = b.var :px, start.x + 0.5
      @py = b.var :py, start.y + 0.5
      @view = b.var :view, facing_angle(start.facing)

      # What the player has: what the bar along the bottom shows, and what the game is played by.
      @health = b.var :health, START_HEALTH
      @ammo = b.var :ammo, START_AMMO
      @score = b.var :score, 0

      declare_the_standing
      declare_the_scratch

      # Every door starts shut, and a list starts empty — so it needs its slots before anything
      # can reach one by number.
      @doors.count.times { @open << 0.0 }
      @doors.count.times { @linger << 0 }
      [@pushwalls.count, 1].max.times do
        @push_step << 0
        @push_gone << 0
        @push_wait << 0
      end
      [key_cells.length, 1].max.times { @key_taken << 0 }

      declare_the_bar
      declare_the_clock
    end

    # HOW MANY GOES YOU GET. Fixed for now: there is nothing that can take one off you, because
    # dying is not a thing that happens yet. It is on the bar from the start rather than added
    # later, so that the field is there and the layout is settled when it starts changing.
    LIVES = 3

    # WHICH FLOOR. One, because one is all the cartridge holds.
    FLOOR = 1

    def declare_the_bar
      @bar = StatusBar.new(build: @b, top: VIEW_H,
                           shows: { floor: FLOOR, score: @score, lives: LIVES,
                                    health: @health, ammo: @ammo, keys: @keys })
    end

    # WORKING ROOM. Every one of these is scratch — set, read and finished with inside a single
    # step of a single frame — so they are grouped by the job that uses them rather than listed
    # in one heap, and each group says which kind of number it holds.
    #
    # A variable holds whole numbers unless it is declared with a fraction, so the split is not
    # a tidiness: it is the difference between a cell number and a place inside a cell.
    def declare_the_scratch
      # THE RAY WALK. Where it points, how far along it from one grid line to the next, which
      # cell it is in, and what it met.
      @ang, @hit, @wall, @cell, @colh, @top = whole(:ang, :hit, :wall, :cell, :colh, :top)
      @mapx, @mapy, @stepmx, @stepmy, @side = whole(:mapx, :mapy, :stepmx, :stepmy, :side)
      @dx, @dy, @deltax, @deltay = fraction(:dx, :dy, :deltax, :deltay)
      @sidex, @sidey, @dist, @seen, @wallx = fraction(:sidex, :sidey, :dist, :seen, :wallx)

      # THE PLAYER'S FEET: what is under them, where a step would land, and whether it may.
      @foot, @here, @can, @spot = whole(:foot, :here, :can, :spot)
      @nx, @ny, @stepx, @stepy = fraction(:nx, :ny, :stepx, :stepy)

      # DOORS. Which one, how far along its panel the ray landed, and how far it has slid.
      # +slot+ and +wait+ are shared with the walls that move and with the keys — each is
      # picked up and put down inside one step, so one of each is enough.
      @isdoor, @door, @edge, @slot, @wait = whole(:isdoor, :door, :edge, :slot, :wait)
      @mid, @slid, @swing = fraction(:mid, :slid, :swing)

      # WALLS THAT MOVE: which one, where it is now, and which way the player is leaning on it.
      @push, @pcell, @ahead, @want, @gone = whole(:push, :pcell, :ahead, :want, :gone)
      @across, @along = fraction(:across, :along)
    end

    # Scratch variables, named with the leading underscore this project gives working room.
    def whole(*names) = names.map { |name| @b.var(:"_#{name}", 0) }
    def fraction(*names) = names.map { |name| @b.var(:"_#{name}", 0.0) }

    # A table must hold something, and a floor need hold none of a kind of thing — there are
    # levels with no doors and plenty with nothing secret in them. One unused entry keeps the
    # table legal, and nothing ever reads it because nothing ever meets one of these.
    def some(values) = values.empty? ? [0] : values

    # A floor whose scenery all lets you through — and every floor, until there is scenery at
    # all — needs no table and pays nothing for one.
    def declare_the_blocking
      return nil if @scenery.nil? || @scenery.empty?

      cells = @level.each_cell.map { |x, y| @scenery.blocks?(x, y) ? 1 : 0 }
      return nil if cells.none?(1)

      @b.table :blocked, cells, width: :byte
    end

    # WHAT STANDS IN THE LEVEL, and it is a piece of work of its own: the guards, the scenery,
    # and the one way both of them get on the screen. All this end has to do is bring them into
    # being in the right order and hand over what they need.
    def declare_the_standing
      return unless Billboards.needed?(scenery: @scenery, guards: @guards)

      # Which way the eye points, worked out once a frame. The shot needs it, every standing
      # thing needs it, and it is here rather than with the rest of the working room because a
      # floor with nothing standing in it never wants it.
      @vcos, @vsin = fraction(:vcos, :vsin)

      declare_the_guards
      @standing = Billboards.new(build: @b, things: @things, scenery: @scenery,
                                 guards: @guards, pool: @guard, mind: @mind,
                                 eye: { x: @px, y: @py, cos: @vcos, sin: @vsin, angle: @view })
    end

    def declare_the_guards
      return if @guards.nil? || @guards.empty?

      b = @b
      @guard = b.pool :guard, x: 0.0, y: 0.0, dir: 0, state: 0, ticks: 0, wait: 0, togo: 0.0,
                              hp: 0, shown: 0,
                              capacity: @guards.count,
                              estimate: { usually: @guards.count }
      @guards.guards.each do |guard|
        # A guard stands in the middle of his cell, like the player does.
        state = Guards.starting_state(guard)
        @guard.spawn x: guard.x + 0.5, y: guard.y + 0.5,
                     dir: Guards.direction_of(guard.facing),
                     state: state, ticks: Guards::STATES.fetch(state).ticks,
                     hp: Guards::HIT_POINTS
      end

      @mind = GuardMind.new(build: b, guards: @guards, pool: @guard, level: @level,
                            world: @world, door_open: @open, walls: { door: DOOR, push: PUSH },
                            things: @things, blocked: @blocked,
                            player: { x: @px, y: @py, health: @health, score: @score,
                                      cos: @vcos, sin: @vsin })
    end

    # What one cell of the map table says. See the note where the table is declared.
    def cell_value(x, y)
      number = @doors.number_at(x, y)
      return DOOR + number - 1 if number

      pushing = @pushwalls.number_at(x, y)
      return PUSH + pushing - 1 if pushing
      return 0 unless @level.solid?(x, y)

      lit = wall_picture(@level.wall_code(x, y))
      lit || 0
    end

    # Where a wall code's lit picture sits in the row of pictures, counting from one so that
    # zero can mean open floor.
    def wall_picture(code)
      at = @atlas.position_of(@atlas.texture_index(code, WallAtlas::LIT))
      at && at + 1
    end

    def door_pictures
      @doors.doors.map { |door| @atlas.position_of(@doors.picture_for(door)) }
    end

    # A push wall is made of an ordinary wall, so it wears that wall's picture and picks
    # between its lit and dark form the way any wall does.
    def push_pictures
      return [0] if @pushwalls.empty?

      @pushwalls.codes.map { |code| wall_picture(code) - 1 }
    end

    # Every key lying on this floor: which cell it is on, which bit picking it up sets, and
    # which piece of scenery it is, so that taking it can stop it being drawn.
    def key_cells
      @key_cells ||= @level.each_cell.filter_map do |x, y|
        lock = @level.key_at(x, y)
        next unless lock

        { cell: (y * @level.width) + x, bit: KEY_BITS.fetch(lock),
          thing: @scenery&.index_at(x, y) || 0 }
      end
    end

    # A number as a table will really hold it, to the places a variable with a fraction keeps.
    def held(number) = RubyGBA::Fraction.scale(number, RubyGBA::Fraction::DEFAULT_BITS) /
                       (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

    # Plane 1 says which way the player starts; the angle table runs clockwise from east.
    def facing_angle(facing)
      { east: 0, south: QUARTER, west: QUARTER * 2, north: QUARTER * 3 }.fetch(facing)
    end

    def walk
      b = @b
      b.held(:left).then { @view.sub TURN_SPEED }
      b.held(:right).then { @view.add TURN_SPEED }

      @stepx.set(@sin[@view + QUARTER] * WALK)
      @stepy.set(@sin[@view] * WALK)
      b.held(:down).then { @stepx.flip }
      b.held(:down).then { @stepy.flip }

      (b.held(:up) | b.held(:down)).then do
        # Each direction is tried on its own, so a player pressed against a wall slides along
        # it instead of stopping dead — one of the two moves still lands.
        @nx.set @px
        @nx.add @stepx
        free?(@nx.to_i, @py.to_i).then { @px.set @nx }

        @ny.set @py
        @ny.add @stepy
        free?(@px.to_i, @ny.to_i).then { @py.set @ny }
      end

      pick_up_a_key
      move_the_doors
      move_the_walls
    end

    # Can the player stand here? Open floor, or a doorway whose panel has slid far enough out
    # of the way to fit through.
    #
    # Written as nested tests rather than one joined condition on purpose: joining them with
    # "and" would work out BOTH sides, and the second one reaches into the list of doors by a
    # number that is only a door number when the first side is true.
    def free?(x, y)
      @spot.set((y * @level.width) + x)
      @foot.set(@world[@spot])
      @can.set 0
      (@foot == 0).then { @can.set 1 }
      (@foot >= PUSH).then do
        # A cell a push wall could reach is floor unless the wall is standing in it now.
        @slot.set(@foot - PUSH)
        @pcell.set(@push_home[@slot])
        @pcell.add(@push_gone[@slot] * @push_step[@slot])
        (@pcell != @spot).then { @can.set 1 }
      end.else do
        (@foot >= DOOR).then do
          @slot.set(@foot - DOOR)
          (@open[@slot] > DOOR_WALKABLE).then { @can.set 1 }
        end
      end
      # ...and a barrel in the way stops you on open floor, which nothing else here does.
      (@blocked[@spot] == 1).then { @can.set 0 } if @blocked
      @can == 1
    end

    # Press the button facing a door and it opens. The reach is short on purpose: you have to
    # be at the door, not merely pointing at it from across the room.
    #
    # A PRESS, so this is on the pass with the trigger rather than on the clock with the walk:
    # the button is read on its edge, and a routine run again for each frame a late pass
    # answered for would read the same press two or three times.
    def open_a_door
      b = @b
      b.pressed(:a).then do
        @nx.set @px
        @nx.add(@sin[@view + QUARTER] * DOOR_REACH)
        @ny.set @py
        @ny.add(@sin[@view] * DOOR_REACH)
        @ahead.set((@ny.to_i * @level.width) + @nx.to_i)
        @foot.set(@world[@ahead])

        (@foot >= PUSH).then { shove_a_wall }
          .else do
            (@foot >= DOOR).then do
              @slot.set(@foot - DOOR)
              # A locked door wants its key. Without it, nothing happens at all.
              #
              # Nested rather than joined with "or", because joining works out BOTH sides —
              # and the second side divides by which key is wanted, which is nought for a door
              # that wants none.
              @want.set(@door_lock[@slot])
              @can.set 0
              (@want == 0).then { @can.set 1 }
              (@want > 0).then { ((@keys / @want) % 2 == 1).then { @can.set 1 } }
              (@can == 1).then { @linger[@slot] = DOOR_LINGER }
            end
          end
      end
    end

    # Lean on a secret wall and it goes. Which way it goes is which way you are pushing, taken
    # to the nearer of the two axes — you cannot shove a wall diagonally.
    def shove_a_wall
      @slot.set(@foot - PUSH)
      # Only from its own cell, and only once. A wall already on the move ignores you.
      ((@ahead == @push_home[@slot]) & (@push_step[@slot] == 0)).then do
        @across.set(@sin[@view + QUARTER])
        @across.abs
        @along.set(@sin[@view])
        @along.abs
        (@across > @along).then do
          (@sin[@view + QUARTER] > 0.0).then { @push_step[@slot] = 1 }
                                       .else { @push_step[@slot] = -1 }
        end.else do
          (@sin[@view] > 0.0).then { @push_step[@slot] = @level.width }
                             .else { @push_step[@slot] = -@level.width }
        end
        @push_wait[@slot] = Pushwalls::FRAMES_PER_CELL
      end
    end

    # Every push wall, every frame. One that has been shoved counts down to its next cell and
    # stops after two — which is what makes a secret passage a passage rather than a hole.
    def move_the_walls
      return if @pushwalls.empty?

      @b.repeat(@pushwalls.count) do |wall|
        @wait.set(@push_wait[wall])
        (@wait > 0).then do
          @push_wait[wall] = @wait - 1
          (@wait == 1).then do
            @gone.set(@push_gone[wall] + 1)
            @push_gone[wall] = @gone
            (@gone < Pushwalls::DISTANCE).then { @push_wait[wall] = Pushwalls::FRAMES_PER_CELL }
          end
        end
      end
    end

    # Walk over a key and you have it. Each one is taken once, and what you carry is a bit per
    # kind — which is all a locked door asks about.
    #
    # A key is a piece of scenery like a lamp is, so taking it also has to take it off the
    # floor: without that you would carry the key and go on seeing it lying there.
    def pick_up_a_key
      return if key_cells.empty?

      @here.set((@py.to_i * @level.width) + @px.to_i)
      @b.repeat(key_cells.length) do |key|
        ((@key_taken[key] == 0) & (@key_cell[key] == @here)).then do
          @key_taken[key] = 1
          @keys.add(@key_bit[key])
          @standing&.take(@key_thing[key])
        end
      end
    end

    # Every door, every frame. A door with time left on it is going open; one without is going
    # shut. That one number is the whole of a door's mind, and it is what makes "open, wait,
    # then close" a subtraction rather than a state machine.
    #
    # Standing in the doorway tops the count back up, so a door cannot shut on you.
    def move_the_doors
      return if @doors.empty?

      b = @b
      @here.set(@world[(@py.to_i * @level.width) + @px.to_i])
      b.repeat(@doors.count) do |door|
        (@here == DOOR + door).then { @linger[door] = DOOR_LINGER }
        @wait.set(@linger[door])
        @swing.set(@open[door])
        (@wait > 0).then do
          @linger[door] = @wait - 1
          @swing.approach DOOR_WIDE, DOOR_STEP
        end.else do
          @swing.approach 0.0, DOOR_STEP
        end
        @open[door] = @swing
      end
    end

    # One strip: walk a ray out to the wall it meets, then stretch a column of that wall's
    # picture to the height its distance earns.
    #
    # THE WALK GOES FROM GRID LINE TO GRID LINE, and that is the whole idea. A wall stands ON
    # a grid line, so stepping to the next line lands exactly on the surface — which gives
    # the true distance and the true place along the face. Walking in steps of a fixed size
    # instead stops somewhere INSIDE the wall, and has to make do with both: the distance
    # comes out in lumps, and dividing by it turns a lump into a jump of several pixels, so a
    # flat wall arrives as a staircase and its bricks slide about. It is also fewer steps —
    # about two a cell crossed, against eight.
    def cast(col)
      b = @b
      width = @level.width

      @ang.set @view
      @ang.add(col * SPREAD)
      @ang.sub((COLUMNS - 1) * SPREAD / 2)

      # Which way the ray points, and how far along it from one grid line to the next — one
      # answer for the lines running one way, one for the lines running the other.
      @dx.set(@sin[@ang + QUARTER])
      @dy.set(@sin[@ang])
      @deltax.set(@reach[@ang + QUARTER])
      @deltay.set(@reach[@ang])

      @mapx.set @px.to_i
      @mapy.set @py.to_i
      @hit.set 0
      @wall.set 0
      @side.set 0

      # How far to the FIRST line of each kind, which depends on which way the ray leans:
      # leaning back it is what has already been crossed of this cell, leaning forward it is
      # what is left of it.
      (@dx < 0).then do
        @stepmx.set(-1)
        @sidex.set((@px - @mapx.to_f) * @deltax)
      end.else do
        @stepmx.set(1)
        @sidex.set((@mapx.to_f + 1 - @px) * @deltax)
      end
      (@dy < 0).then do
        @stepmy.set(-1)
        @sidey.set((@py - @mapy.to_f) * @deltay)
      end.else do
        @stepmy.set(1)
        @sidey.set((@mapy.to_f + 1 - @py) * @deltay)
      end

      # Take whichever line is nearer, every time. That is all there is to it — and it stops
      # the moment it meets a wall, which is well before the last crossing it is allowed.
      #
      # HOW SOON IT STOPS is measured rather than felt, because nothing at build time can know
      # it and the estimate would otherwise count the ceiling: walking these same rays over the
      # first floor, from sixty-four places and four ways round each, a ray crosses four and a
      # bit grid lines and no ray in twenty thousand ever ran out. So the ceiling is generous
      # and free, and this is what a frame really pays.
      b.repeat(CROSSINGS, stop_when: @hit == 1, estimate: { usually: 5 }) do
        (@sidex < @sidey).then do
          @sidex.add @deltax
          @mapx.add @stepmx
          @side.set 0
        end.else do
          @sidey.add @deltay
          @mapy.add @stepmy
          @side.set 1
        end
        @cell.set(@world[(@mapy * width) + @mapx])
        (@cell > 0).then do
          # Something is here. Only now is it worth asking WHICH kind, because the ray has
          # stopped either way — every step before this one paid a single test and no more.
          (@cell >= PUSH).then { meet_a_pushwall(width) }
            .else do
              (@cell >= DOOR).then { meet_a_door }.else do
                @hit.set 1
                @wall.set(@cell - 1 + @side)
                @isdoor.set 0
              end
            end
        end
      end

      # The crossing that landed on the wall counted a whole line's worth too far — take that
      # back and what is left reaches the surface itself. A door has already worked out its own
      # distance, because its panel does not stand on a grid line.
      (@isdoor == 0).then do
        (@side == 0).then { @dist.set(@sidex - @deltax) }.else { @dist.set(@sidey - @deltay) }
      end

      # Correct for the fan: a ray angled away from centre travels further to reach the same
      # flat wall, and without this a straight wall bows outward at the edges of the view.
      @seen.set(@dist * @sin[(col * SPREAD) + QUARTER - ((COLUMNS - 1) * SPREAD / 2)])

      # The perspective divide, which is the whole trick: a wall twice as far away covers half
      # as much of the screen.
      #
      # NOTHING IS ADDED TO THE DISTANCE AND NOTHING CAPS THE HEIGHT. Both used to be here,
      # and both were lies about perspective that showed at exactly the moment the player
      # could see them best: adding to the distance holds a near wall short, by nearly half at
      # half a cell away, and capping the height stops the wall growing at all in the last
      # stretch before you touch it. They were there because a tall column used to cost every
      # row it had, on screen or not. It costs what shows now, so the height can be what
      # perspective actually says — and a wall you are nose-to-nose with fills the screen with
      # a few enormous bricks, which is right.
      # Rounded to the nearest whole pixel rather than always down. A wall square-on stands at
      # ONE height, and dropping the fraction puts every strip whose height lands exactly on a
      # whole number at the mercy of the last bit — half of them fall to the pixel below and
      # the top edge of a flat wall wanders.
      @colh.set((WALL_SCALE / @seen + 0.5).to_i)
      @top.set HORIZON
      @top.sub(@colh / 2)

      draw_strip(col)
    end

    # A RAY REACHES A CELL A PUSH WALL COULD BE IN, which is not the same as one it IS in.
    #
    # The map cannot say where a push wall is, because the map is in the cartridge and a push
    # wall moves. So the map marks everywhere one could ever get to, and the answer is worked
    # out here: where it started, plus how far it has gone in the direction it was shoved. If
    # that is this cell it is a wall like any other; if not, this cell is the floor the map
    # always said it was and the ray carries straight on.
    def meet_a_pushwall(width)
      @push.set(@cell - PUSH)
      @pcell.set(@push_home[@push])
      @pcell.add(@push_gone[@push] * @push_step[@push])
      (@pcell == (@mapy * width) + @mapx).then do
        @hit.set 1
        @isdoor.set 0
        @wall.set(@push_face[@push] + @side)
      end
    end

    # A RAY MEETS A DOORWAY, which is not the same as meeting a wall.
    #
    # The panel stands across the MIDDLE of the cell, so the ray does not stop where it came
    # in: it carries on half a cell further and asks what is there. Three things can happen.
    # It can leave the cell sideways before it ever reaches the middle, and then the doorway
    # was just a gap it passed beside. It can reach the middle where the panel has slid away,
    # and pass through. Or it can reach the middle where the panel still is, and stop.
    #
    # The half-cell step is the same for either kind of panel, because the distance from one
    # grid line to the next along this ray is exactly what the walk already keeps.
    def meet_a_door
      @door.set(@cell - DOOR)

      (@door_across[@door] == 0).then do
        @mid.set(@sidex - (@deltax / 2))         # half a cell back from the far side
        @wallx.set(@py + (@mid * @dy))           # ...and where the ray is by then
        @edge.set(@wallx.to_i - @mapy)
      end.else do
        @mid.set(@sidey - (@deltay / 2))
        @wallx.set(@px + (@mid * @dx))
        @edge.set(@wallx.to_i - @mapx)
      end

      # Still inside this cell when it got there? If not the ray went by the doorway rather
      # than into it, and the walk carries on as if nothing were here.
      (@edge == 0).then do
        # The panel has slid this far out of the way, so the ray passes through anything up to
        # there and meets the panel beyond it.
        @slid.set(@open[@door])
        @wallx.sub(@wallx.to_i.to_f) # how far across the cell, with the whole cells taken off
        (@wallx > @slid).then do
          @hit.set 1
          @isdoor.set 1
          @dist.set @mid
          @wall.set(@door_picture[@door])
          @wallx.sub @slid
        end
      end
    end

    # WHICH WAY THE FACE TURNS decides two things, and the walk has already answered it: a ray
    # that stepped across a line running one way met a face running that way, and where along
    # that face it landed is the OTHER coordinate of the point it stopped at.
    #
    # Each wall keeps two pictures side by side, the lit one then the darker one, so the same
    # answer picks between them for nothing — which is where the whole game gets its sense of
    # light.
    def draw_strip(col)
      # A door has already said where along its panel the ray landed, and which picture it
      # wears — its panel does not turn, so there is nothing to pick.
      (@isdoor == 1).then do
        strip(col, (@wall * TEX) + texture_column)
      end.else do
        (@side == 0).then { @wallx.set(@py + (@dist * @dy)) }
                    .else { @wallx.set(@px + (@dist * @dx)) }
        strip(col, (@wall * TEX) + texture_column)
      end
    end

    # Where along the face the ray landed, as one of the picture's columns: the part of the
    # crossing point that is past the grid line the wall stands on.
    def texture_column = (@wallx * TEX).to_i % TEX

    # The whole strip is one walk down the screen. Its pixels all show the same column of the
    # same picture at the same height, so asking for them one at a time worked the same answer
    # out three times over.
    #
    # The height is also left behind for whatever stands in the room, which reads it to know
    # what it is behind. A ray that met nothing leaves nothing, so a guard at the end of an
    # open corridor is not held back by a wall that is not there.
    def strip(col, slice)
      b = @b
      depth = @standing&.depth
      drawn = (@hit == 1).then do
        depth[col] = @colh if depth
        b.draw_column_at :walls, slice: slice, x: col * COLUMN_W, top: @top, height: @colh,
                                 width: COLUMN_W
      end
      drawn.else { depth[col] = 0 } if depth
    end
  end
end
