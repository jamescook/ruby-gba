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
    # HOW THE SCREEN IS DIVIDED ACROSS, and the width is not a free choice — it is what the
    # screen's memory wants, and picking it right makes the strips cheaper than picking it
    # small does.
    #
    # This screen keeps a colour NUMBER per pixel, one byte each, and its memory cannot take
    # a single byte — the smallest thing that can be written is a PAIR of them. So a strip
    # that starts on an even pixel and is an even number wide writes whole pairs and nothing
    # else; one that does not has to read the pair the odd end lands in, change one half of
    # it, and put both back, at every row of every strip.
    #
    # Four is the width where that goes away. A strip starts at `col * COLUMN_W`, and four
    # times anything is even, which is something the BUILD can prove rather than the game
    # having to test it — so the walk down the strip is emitted once instead of once for each
    # answer, and every row is two clean writes. Three could never be even, so it cost a
    # read-and-patch at one end of every row and both copies of the walk in the bargain.
    #
    # And a wider strip means FEWER of them: sixty rays where there were eighty, for the same
    # 240 pixels. A ray is the expensive half of this renderer, so that is a quarter of the
    # expensive half gone for nothing given up — the picture is the same number of pixels
    # either way, drawn in wider pieces.
    COLUMNS = 60
    COLUMN_W = 4

    # HOW FINELY AN ANGLE IS COUNTED, and it went up when the strips got wider so that the
    # view did not get narrower with them.
    #
    # How wide the view is comes out as COLUMNS * SPREAD, and SPREAD has to be a whole number
    # because it is what an angle steps by to reach the next strip, and an angle is a place in
    # a table. With 512 units in a turn, sixty strips one unit apart would have been a 42
    # degree view — a keyhole. Counting a turn in 1024 units instead makes each unit half as
    # much, so three of them is about what one of the old ones was, and sixty strips three
    # apart is a 62 degree view: WIDER than the 56 this had before, and nearer the 60 the
    # original uses.
    #
    # The tables that hold a sine and a distance for every angle double in length. They live
    # in the cartridge and are read, never written, so that costs nothing but room — and 1024
    # is still a power of two, which is what keeps an angle that walked off either end cheap
    # to bring back round (see the note on `table` about wrapping against clamping).
    TURN = 1024
    QUARTER = TURN / 4
    CROSSINGS = 48        # grid lines a ray may cross before it gives up — about 24 cells

    # ...and how many it really crosses, for the estimate only. See the note where the walk is
    # written: measured over the first floor, from sixty-four places and four ways round each, a
    # ray crosses four and a bit grid lines and no ray in twenty thousand ever ran out.
    USUAL_CROSSINGS = 5

    # HOW WIDE THE VIEW IS: three angle units per strip, which over sixty strips is about 62
    # degrees across — a shade wider than the 60 the original uses.
    #
    # A wide view is not a neutral choice. Perspective genuinely stretches whatever sits at
    # the edge of it, and that stretch is what reads as a bend when you look ALONG a wall
    # rather than at it. This was once two units of a 512-unit turn, which made a view of 111
    # degrees, and at 111 the strip at the edge covers three times the world the strip in the
    # middle does; at 60 it covers one and a third.
    SPREAD = 3

    # The furthest one crossing can be worth. A ray running almost along an axis meets that
    # axis's lines almost never, and one over almost-nothing is too big to hold — so it is
    # held here, at a distance longer than any crossing on a map this size.
    FAR = 128.0

    # ...AND THE NEAREST A WALL CAN BE SEEN AT, which is a limit of the NUMBER rather than a
    # claim about perspective, and the two are worth keeping apart.
    #
    # The height of a column is one number divided by the distance, and a number here holds
    # about 32768 before it runs out. Nearer than about a fiftieth of a cell that division has
    # nothing left to give: it stops at 32768, and then rounding the answer to the nearest whole
    # pixel adds a half to a number with no room for one, which turns it NEGATIVE. A negative
    # height draws nothing, and it is written into what the room's standing things read to know
    # what is in front of them — so a strip too close showed no wall AND let every guard in the
    # level show through it. Walk one step too near a corner and you can see through the world.
    #
    # A fiftieth of a cell is nearer than a player can be pushed by anything but this, and at
    # that distance the wall fills the screen several times over either way — what the cap
    # changes is which two texels of the brick are stretched across it, which is nothing anyone
    # can see. It is not the height cap this renderer used to have and does not want back: that
    # one held a wall short across the whole last half-cell, where a player can see it plainly.
    NEAREST = 0.02

    # Where the map table stops naming walls and starts naming the things that are more than a
    # wall. Each is above every picture a level could hold, so none of them can be confused.
    #
    # THEY ARE TESTED FROM THE TOP DOWN, biggest first, which is why LIFT sits above the other
    # two rather than below them: a lever is a wall you cannot walk into and cannot shove, so
    # anything that asks "can I stand here" or "did I just shove this" has to rule it out before
    # it reaches the tests for the two that move. One comparison, and only on a cell that already
    # holds something — the walk's own step is untouched.
    DOOR = 512
    PUSH = 1024
    LIFT = 2048

    # HOW FAR OPEN A DOOR IS: 0 is shut and 1 is out of the way, which is the same thing the
    # ray asks about, so nothing has to be converted where the two meet.
    DOOR_WIDE = 1.0
    DOOR_STEP = 0.05         # a frame, so about half a second to swing
    DOOR_LINGER = 180        # and three seconds standing open before it shuts again

    # How long the lever stands pulled before the floor ends, WHEN THE COPY OF THE GAME BEING
    # BUILT FROM DOES NOT HOLD THE LIFT'S RECORDING — the shareware release does not. Otherwise
    # the recording decides it: see lift_wait_frames.
    #
    # Forty is what the registered copy's own sound comes to, so the two agree and a shareware
    # build feels the same as a registered one.
    LIFT_WAIT = 40
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

    # How far a press of left or right turns you in one pass. Twelve of the turn's 1024 units
    # is 4.2 degrees, which is what the original turns in one of its own units of time — and
    # is the same speed this turned at before, when a unit was twice as big and six of them
    # said it. A finer angle count does not mean a faster player; it means a smaller step is
    # available, which is what let the view be cut into sixty strips without narrowing it.
    TURN_SPEED = 12

    # What the player starts with. A hundred of health and eight bullets, which is what the
    # original hands you at the top of a floor.
    START_HEALTH = 100
    START_AMMO = 8

    CEILING = RubyGBA::Color.rgb(7, 7, 9)
    FLOOR_COLOR = RubyGBA::Color.rgb(12, 11, 10)

    # +floors+ is every floor the cartridge holds. A game with one floor may hand over its pieces
    # loose instead — `level:`, `doors:` and the rest — which is what a test builds and what a
    # cartridge with nowhere to go is; the two are the same thing with one floor in it.
    # +startable+ says a menu will ask for a game to begin, which is what makes the routine
    # that puts a floor back worth emitting on a cartridge where nothing else would want it.
    # +sound_on+ is the menu's own sound switch, or nil where there is no menu to turn it off.
    def initialize(build:, atlas:, level: nil, doors: nil, pushwalls: nil, guards: nil,
                   things: nil, scenery: nil, vswap: nil, lifts: nil, floors: nil, bar_art: nil,
                   startable: false, sound_on: nil)
      @floors = floors || Floors.of(level: level, doors: doors, pushwalls: pushwalls,
                                    lifts: lifts, guards: guards, scenery: scenery)
      here = @floors.first_floor
      @b = build
      @atlas = atlas
      # THE FIRST FLOOR'S OWN PIECES, which is what the build-time questions with no floor in them
      # ask: how wide a map is, and what a wall code's picture is. Everything that differs from
      # one floor to the next goes through @floors instead.
      @level = here.level
      @doors = here.doors
      @pushwalls = here.pushwalls
      @lifts = here.lifts
      @guards = here.guards
      @scenery = here.scenery
      @things = things
      @vswap = vswap # the player's own copy of the recorded sounds, or nil for a silent build
      @bar_art = bar_art # Wolfenstein's own art for the bar, or nil to draw it plainly
      @startable = startable
      @sound_on = sound_on
      declare
    end

    # WHICH FLOORS THIS CARTRIDGE HOLDS, so a menu can offer the episodes they make up.
    attr_reader :floors

    # BEGIN A GAME on the floor +slot+ of the ones this cartridge holds — a fresh player with
    # three goes and no score, on a floor put back the way it was built.
    #
    # WHICH FLOOR IS SET FIRST, because everything the floor's own start does reads through
    # it: which slice of the map, which doors, which guards, and where you stand.
    def begin_a_new_game(slot)
      @floor.set slot
      @lives.start_again
      @b.call :start_the_floor
    end

    # Whether the game has ended, or nil where nothing can kill you. See {Lives#over}.
    def over = @lives.over

    # WHAT PACES THE WORLD, and it is a real choice with no free answer.
    #
    # :by_the_frame — everything moves once for each frame that really went by, so the world
    #   keeps real time however heavy the frame is. That is what the original does (it moves you
    #   `BASEMOVE * MOVESCALE * tics`, where tics is how long the last frame took). What it costs
    #   is that a game running at half the frame rate moves in double steps.
    # :by_the_pass — everything moves once per pass of the game loop, so a game too heavy for a
    #   frame runs in slow motion: smooth, uniform, and at the wrong speed.
    #
    # ON A GAME THAT KEEPS UP THE TWO ARE THE SAME THING, exactly — a pass IS a frame — so this
    # only means anything while the frame is over budget, which this one still is.
    #
    # WHY IT IS SET TO THE PASS. Choppiness is the world's speed times how long a pass takes, so
    # at a fixed frame rate there is no setting that is both smooth and the right speed; the two
    # above are the ends of one dial. Measured, a pass here takes two frames, so pacing by the
    # frame turns a six-unit turn step into 8.4 degrees between one picture and the next where
    # the original delivers 4.2. TURNING is what a player feels that in, because a turn moves
    # every pixel on the screen and because turning is aiming: what you can hit is decided by the
    # smallest turn the game will make. Played on hardware it reads as the aim being coarse, and
    # slow motion is the better of the two faults until the frame fits.
    #
    # So this is a note about the frame rate rather than about pacing. Get a pass under a frame
    # and the dial has one setting.
    PACING = :by_the_pass

    # One pass of the game loop: what happens, and then what you see of it.
    def update
      play
      draw
    end

    # WHAT A PRESS DOES, plus — while the world is paced by the pass — what moves.
    #
    # A PRESS IS ALWAYS HERE whichever way the world is paced, because a button read on its edge
    # has to be read once per press. Move the trigger onto the clock and one pull of it fires a
    # bullet for every frame a late pass answered for.
    #
    # A DEAD PLAYER DOES NOT SHOOT, which is the whole of dying until there is a screen to say
    # so. The guards go on about their business around the body, which is what the original does
    # too while the death is playing out.
    def play
      move_the_world if PACING == :by_the_pass
      still_playing.then do
        open_a_door
        fire if @mind
      end
      # ...and outside that, because a lift already on its way does not stop because the thing
      # that pulled it has since been shot.
      run_the_lift if lifts?
    end

    # Is the game still the player's to play? Until something can kill you it always is.
    def still_playing = @dying ? @dying.alive : (@health > 0)

    # EVERYTHING THAT MOVES, in one place so that where it is CALLED FROM is the only thing that
    # decides how the world is paced. See PACING.
    #
    # A DEAD PLAYER'S WORLD STOPS. Once something has killed you, none of this runs — not the
    # walking, not the doors, not the guards. The death has its own short story to tell (turn
    # toward what killed you, then the view goes red) and it tells it over a still world, which
    # is what the original does and is also what makes it affordable: the eighty rays a normal
    # frame spends nearly all of itself on are simply not cast.
    def move_the_world
      still_playing.then { walk }
      @dying&.turn

      if @standing
        # Which way the eye points, worked out once a move: the shot needs it and so does
        # everything the view draws standing in the room.
        @vcos.set(@sin[@view + QUARTER])
        @vsin.set(@sin[@view])
      end
      # WHICH ROOMS ARE OPEN TO THE PLAYER, worked out before anybody thinks and once for all of
      # them — the answer is the same for every guard on the floor, and it is what most of them
      # are about to be told they need not think at all.
      still_playing.then { @rooms.refresh } if @rooms
      still_playing.then { @mind.update } if @mind
    end

    # ...and the other way of pacing it: once for each frame that really passed, so the world
    # keeps real time however long the picture took.
    #
    # A LONG FRAME CANNOT PUT YOU THROUGH A WALL this way, and by construction rather than by a
    # rule. The original multiplies its step by how late it is, so it needs a cap (MAXTICS) to
    # stop a big step straddling a wall between one collision test and the next. This runs the
    # ordinary step AGAIN instead — each one with its own collision test — so there is no big
    # step to guard. (The framework caps the catch-up anyway, so a very late pass is never asked
    # to replay half a second.)
    def declare_the_clock
      return unless PACING == :by_the_frame

      @b.once_a_frame(:the_world_moves) { move_the_world }
    end

    # ONE PRESS, ONE BULLET. The button is read on the press rather than held, so the pistol
    # fires as fast as you can tap it and no faster.
    def fire
      @b.pressed(:b).then do
        (@ammo > 0).then do
          @ammo.sub 1
          @sounds.pistol
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
    # ONCE THE VIEW STARTS GOING RED IT IS NOT REDRAWN. The dots are added to the picture that is
    # already there, so anything painting over it would rub them out — and the whole of what the
    # fizzle costs is affordable precisely because none of this is being done underneath it.
    def draw
      return draw_the_world unless @dying

      @dying.showing_the_world.then { draw_the_world }
      @dying.draw
      # ...and, once that has finished, whether there is another go in you — and if there is not,
      # the words over the red it left.
      @lives.update
    end

    def draw_the_world
      @b.call :draw_the_view
      @bar.draw
    end

    # HOW MUCH OF THE FLOOR HAS BEEN FOUND, and how much there was to find. The three counts are
    # variables the game moves; the three totals are settled while building, because they are
    # facts about the map. A percentage is one over the other, and the original gives a bonus for
    # a hundred per cent of any of them.
    #
    # PUBLIC because the tally at the end of a floor is the whole reason they exist, and that
    # screen is not written yet — it wants the game's own lettering, which is a piece of work of
    # its own. Counting them is not, so they are counted, and the screen will find them here.
    attr_reader :kills, :secrets, :treasures

    def kill_total = @guards&.count || 0
    def secret_total = @pushwalls.count
    def treasure_total = @pickups&.treasure_total || 0

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
        toward = as_a_table_holds_it(Math.sin(a * 2 * Math::PI / TURN)).abs
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
      @world = b.table :world, @floors.flat_map { |floor|
        floor.level.each_cell.map { |x, y| cell_value(floor, x, y) }
      }

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
      # SIZED FOR THE WORST FLOOR, not for all of them added together, because only one floor is
      # ever being played. Every list below is the state of the floor under your feet.
      @open = b.list :door_open, capacity: room_for(:doors), holds: 0.0
      @linger = b.list :door_linger, capacity: room_for(:doors)

      # Which picture each door wears, worked out while building — a door's panel does not
      # turn, so unlike a wall it needs no choosing as the game runs.
      #
      # ...and every floor's doors end to end, reached by adding where this floor's start. That
      # is the shape of every table from here down.
      @door_picture = b.table :door_picture, at_least_one(over_floors { |f| door_pictures(f) }), width: :byte
      @door_across = b.table :door_across, at_least_one(over_floors { |f| f.doors.doors.map(&:across) }),
                             width: :byte
      # Which key each door wants, as the bit the player carries. Nought wants none.
      @door_lock = b.table :door_lock,
                           at_least_one(over_floors { |f| f.doors.doors.map { |d| KEY_BITS[d.lock] || 0 } }),
                           width: :byte

      # A push wall: where it started, what it is made of, and — as the game runs — which way
      # it was shoved, how far it has got, and how long until its next cell.
      #
      # WHERE IT STARTED IS A CELL OF ITS OWN FLOOR, with nothing added, because it is compared
      # against cells the game works out while playing that floor and those are local too.
      @push_home = b.table :push_home, at_least_one(over_floors { |f| f.pushwalls.homes })
      @push_face = b.table :push_face, at_least_one(over_floors { |f| push_pictures(f) }), width: :byte
      @push_step = b.list :push_step, capacity: room_for(:pushwalls)
      @push_gone = b.list :push_gone, capacity: room_for(:pushwalls)
      @push_wait = b.list :push_wait, capacity: room_for(:pushwalls)

      # Which keys the player is carrying, one bit each. A key is a thing lying on the floor like
      # a clip of ammunition is, so picking one up belongs to Pickups; this is only what is
      # carried, which is the one number a locked door asks about.
      @keys = b.var :keys, 0

      # THE LIFT, as three numbers, and all three are one-per-game rather than one-per-lift
      # because a floor ends the first time anybody pulls anything: there is never a second lift
      # on its way.
      #
      # WHICH CELL holds the lever that was pulled, so the walk can give that one cell the pulled
      # picture and leave the car's other levers alone. Minus one for none, because nought is a
      # real cell.
      @pulled = b.var :lift_pulled, -1
      # ...WHETHER IT WAS THE SECRET LIFT, which is a different question and is the one that
      # decides where you come out. Read off where the player was standing, not off the lever.
      @lift_secret = b.var :lift_secret, 0
      # ...and HOW LONG until the floor ends.
      @lift_wait = b.var :lift_wait, 0
      # WHICH FLOOR IS BEING PLAYED, counting from nought in the order the cartridge holds them,
      # and WHERE ITS SLICE OF EACH TABLE BEGINS.
      #
      # These are what make more than one floor possible. Every table in the cartridge holds all
      # the floors end to end, and reading one is the same read with the matching number below
      # added — set once when a floor starts, unchanged while it is played. In the walk that
      # reads the map thousands of times a frame that is a single add.
      #
      # THEY ARE SET FROM AN ARM PER FLOOR rather than looked up in yet more tables, because
      # starting a floor happens a handful of times in a whole game: a great deal of code that
      # never runs while anybody is playing. See #go_to_this_floor.
      # THEY START AT THE FIRST FLOOR'S OWN NUMBERS, not at nothing, because at boot no floor has
      # been STARTED — the game simply begins on the first one. Left at nothing the game would
      # come up on a floor with no doors, no walls that move and nobody on it, until something
      # sent the player back to the beginning and quietly fixed it.
      @floor = b.var :floor, 0
      @map_base = b.var :_map_base, @floors.map_base(0)
      @door_first = b.var :_door_first, @floors.first_of(:doors, 0)
      @door_count = b.var :_door_count, @floors.count_of(:doors, 0)
      @push_first = b.var :_push_first, @floors.first_of(:pushwalls, 0)
      @push_count = b.var :_push_count, @floors.count_of(:pushwalls, 0)
      @guard_first = b.var :_guard_first, @floors.first_of(:guards, 0)
      @guard_count = b.var :_guard_count, @floors.count_of(:guards, 0)
      @piece_first = b.var :_piece_first, @floors.first_of(:pieces, 0)
      @piece_count = b.var :_piece_count, @floors.count_of(:pieces, 0)
      # ...and the cell that means the secret lift on THIS floor, or minus one where it has none.
      # One comparison when a lever goes down, instead of an arm per floor there too.
      @secret_car = b.var :_secret_car, (@floors.first_floor.lifts&.secret_cars&.first || -1)

      b.image :walls, width: @atlas.width, height: @atlas.height, data: @atlas.pixels

      @px = b.var :px, start_x
      @py = b.var :py, start_y
      @view = b.var :view, start_view

      # What the player has: what the bar along the bottom shows, and what the game is played by.
      @health = b.var :health, START_HEALTH
      @ammo = b.var :ammo, START_AMMO
      @score = b.var :score, 0

      # HOW MUCH OF THE FLOOR HAS BEEN FOUND: how many of its guards are down, how many of its
      # secret walls have been shoved, how many of its treasures are in your pocket. Three
      # numbers the game keeps for the tally at the end of a floor, and they belong to the FLOOR
      # rather than to the game — every one goes back to nothing when a floor starts, which is
      # what makes them a percentage of something.
      #
      # The score is the opposite and is deliberately not here: it is kept across floors and
      # comes back to nothing only when a whole game starts again.
      @kills = b.var :kills, 0
      @secrets = b.var :secrets, 0
      @treasures = b.var :treasures, 0

      # DYING AND THE GOES YOU GET COME FIRST, because what stands in the level reaches both: the
      # guard who lands the last shot sets the death off, and a thing you pick up can hand you
      # another go.
      declare_the_dying
      @lives = Lives.new(build: b, score: @score, dying: @dying)
      # Which way the eye points, worked out once a move. The shot needs it, every standing thing
      # needs it, and it is here rather than with the rest of the working room because a floor
      # with nothing standing in it never wants it.
      @vcos, @vsin = fraction(:vcos, :vsin) if Billboards.needed?(scenery: @scenery, guards: @guards)

      # ...then the guards, then what is lying on the floor (which every floor has whether
      # anything DRAWS it or not — a level with a locked door has a key on it), then the guards'
      # minds, and last the drawing. Each needs the one before it; see each for why.
      # The recorded sounds come before the guards' minds, because a guard shouting, shooting and
      # dying is most of what there is to hear.
      @sounds = Sounds.new(build: b, vswap: @vswap, switch: @sound_on)
      # ...and before both of them, because a guard asks it whether to think and every piece of
      # scenery asks it whether to be looked at.
      declare_the_rooms
      declare_the_guards
      declare_the_pickups
      declare_the_guards_minds
      declare_the_standing
      declare_the_scratch

      # Every door starts shut, and a list starts empty — so it needs its slots before anything
      # can reach one by number. Enough for the busiest floor, since that is what the lists hold.
      room_for(:doors).times do
        @open << 0.0
        @linger << 0
      end
      room_for(:pushwalls).times do
        @push_step << 0
        @push_gone << 0
        @push_wait << 0
      end
      declare_the_floor_start
      declare_the_bar
      declare_the_view
      declare_the_clock
    end

    # DRAWING THE VIEW IS A ROUTINE, and the reason is about SIZE rather than about tidiness.
    #
    # The console keeps 32K of quick memory where code runs about two and a half times faster,
    # and the framework fills it with the routines a frame spends its time in. Written straight
    # into the game loop, everything below is part of one enormous block — the whole loop body,
    # emitted inline — and a block that big is offered less of the memory than it needs, so it
    # misses and the WHOLE FRAME runs from the cartridge at a third of the speed. Measured: 23K
    # wanted against 20.6K offered, and freeing 17K elsewhere did not move the offer by a byte.
    #
    # As a routine it is placed or not on its own, and what it leaves behind in the loop is small
    # enough to be placed too. `rom.explain` lists what was kept and what just missed, which is
    # the only way to see any of this from outside.
    #
    # THE CLIP IS INSIDE THE ROUTINE, not around the call, and it has to be: a routine is built
    # once for wherever it is called from, so it cannot carry a caller's clipping with it.
    def declare_the_view
      # INSISTED ON, because it is the routine the frame is. The framework's own choice puts the
      # game loop's body in first and then has too little left for this, which is the wrong way
      # round: the loop body is mostly the CALL to this. Marked, they both fit.
      @b.func(:draw_the_view, fast: true) do
        @b.inside 0, 0, ACROSS, VIEW_H do
          @b.dma_fill_rect 0, 0, ACROSS, HORIZON, CEILING
          @b.dma_fill_rect 0, HORIZON, ACROSS, VIEW_H - HORIZON, FLOOR_COLOR
          @b.repeat(COLUMNS) { |col| cast(col) }
          @standing&.draw
        end
      end
    end

    # WHERE THE LEVEL PUTS YOU, in one place because it is wanted twice: once to start with, and
    # again every time the floor is started over. The angle table runs clockwise from east.
    def start_x = @level.start.x + 0.5
    def start_y = @level.start.y + 0.5
    def start_view = facing_angle(@level.start.facing)

    # WHICH FLOOR. One, because one is all the cartridge holds.
    FLOOR = 1

    def declare_the_bar
      @bar = StatusBar.new(build: @b, top: VIEW_H, art: @bar_art,
                           shows: { floor: FLOOR, score: @score, lives: @lives.left,
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

    # How long the lever stands pulled. The original plays the lift's own recording and then
    # waits for it to finish, so the recording IS the pause and the number is read off it here
    # rather than chosen. A copy of the game without that recording falls back to LIFT_WAIT.
    def lift_wait_frames = @sounds&.level_done_frames || LIFT_WAIT

    # Scratch variables, named with the leading underscore this project gives working room.
    def whole(*names) = names.map { |name| @b.var(:"_#{name}", 0) }
    def fraction(*names) = names.map { |name| @b.var(:"_#{name}", 0.0) }

    # A table must hold something, and a floor need hold none of a kind of thing — there are
    # levels with no doors and plenty with nothing secret in them. One unused entry keeps the
    # table legal, and nothing ever reads it because nothing ever meets one of these.
    def at_least_one(values) = values.empty? ? [0] : values

    # Every floor's share of one kind of thing, end to end, in the order the floors are played.
    # Where a floor's own share begins is `Floors#first_of`, and the two must agree — so both
    # walk the floors in the same order and neither is written twice.
    def over_floors(&) = @floors.flat_map(&)

    # ...and how many of a thing the busiest floor holds, which is what the lists the game plays
    # with are sized for. At least one, because a list must have room for something.
    def room_for(kind) = [@floors.most(kind), 1].max

    # Does no floor in the cartridge hold any of this at all? Then none of the code for it is
    # emitted — a game with no doors anywhere pays nothing for doors.
    def no_floor_has?(kind) = @floors.most(kind).zero?

    # HOW MANY A LOOP OVER THEM REALLY MAKES, for the estimate only — nothing about how the game
    # runs reads it. A loop counted by a variable has no number anywhere in the program, neither
    # how many passes it makes nor the most it could, so unsaid it would be charged nothing at
    # all and the report would call the whole of it free. The floors are right here, so both
    # numbers are known: what a floor holds on average, and what the busiest one holds.
    def how_many(kind)
      counts = @floors.counts_of(kind)
      { usually: [(counts.sum.to_f / counts.length).ceil, 1].max, most: [counts.max, 1].max }
    end

    # A floor whose scenery all lets you through — and every floor, until there is scenery at
    # all — needs no table and pays nothing for one.
    # ...for every floor end to end, like the map itself and reached the same way. A floor whose
    # scenery all lets you through contributes its own run of noughts rather than being left out,
    # because the floors after it are found by counting cells.
    def declare_the_blocking
      return nil if @floors.none? { |floor| floor.scenery && !floor.scenery.empty? }

      cells = @floors.flat_map do |floor|
        floor.level.each_cell.map { |x, y| floor.scenery&.blocks?(x, y) ? 1 : 0 }
      end
      return nil if cells.none?(1)

      @b.table :blocked, cells, width: :byte
    end

    # WHAT STANDS IN THE LEVEL, and it is a piece of work of its own: the guards, the scenery,
    # and the one way both of them get on the screen. All this end has to do is bring them into
    # being in the right order and hand over what they need — and the order is a real one, so it
    # is set out where they are declared rather than left to be worked out from here.
    def declare_the_standing
      return unless anything_stands_anywhere?

      # A one-floor game hands over its own scenery and nothing else; a cartridge with more says
      # where this floor's pieces begin and how many it has, which is what the walk over them
      # needs and all it needs.
      many = @floors.count > 1
      @standing = Billboards.new(build: @b, things: @things, scenery: @scenery,
                                 floors: (@floors if many),
                                 piece_first: (@piece_first if many),
                                 piece_count: (@piece_count if many),
                                 rooms: @rooms, piece_room: declare_the_pieces_rooms,
                                 guards: @guards, pool: @guard, mind: @mind, pickups: @pickups,
                                 eye: { x: @px, y: @py, cos: @vcos, sin: @vsin, angle: @view })
    end

    # WHICH ROOM EACH PIECE OF SCENERY STANDS IN, worked out while building because a lamp does not
    # move. One byte each, every floor end to end like everything else, so the walk over them can
    # ask whether a piece is even worth looking at before it works out where on the screen it goes.
    def declare_the_pieces_rooms
      return nil if @rooms.nil?

      @b.table :thing_room, at_least_one(over_floors { |floor|
        (floor.scenery&.pieces || []).map do |piece|
          (floor.level.area(piece.x, piece.y)&.+(1)) || Rooms::NOWHERE
        end
      }), width: :byte
    end

    # Does anything stand in ANY floor the cartridge holds? A game with nothing anywhere pays for
    # none of the drawing that puts things in rooms.
    def anything_stands_anywhere?
      @floors.any? { |floor| Billboards.needed?(scenery: floor.scenery, guards: floor.guards) }
    end

    # DYING NEEDS SOMETHING THAT CAN KILL YOU, so a floor with no guards on it declares none of
    # this and pays for none of it.
    def declare_the_dying
      return if @guards.nil? || @guards.empty?

      @dying = Dying.new(build: @b, eye: { x: @px, y: @py, angle: @view, sin: @sin })
    end

    # THINGS ON THE FLOOR YOU PICK UP BY WALKING OVER THEM. It sits between the guards and their
    # minds, and that is the whole of why the three are declared apart: a clip is kept as a field
    # of the guard who dropped it, so this needs the pool — and a guard's mind is what tells it he
    # has fallen, so the mind needs this.
    #
    # It reads the floor for itself where no scenery was handed over. A game built without drawing
    # still has keys lying on it, and the tests of the locked doors are exactly that game.
    def declare_the_pickups
      @pickups = Pickups.new(build: @b, floors: @floors, pool: @guard, lives: @lives,
                             bases: { map: @map_base, piece: @piece_first },
                             player: { x: @px, y: @py, health: @health, ammo: @ammo,
                                       score: @score, keys: @keys, treasures: @treasures })
    end

    # THE GUARDS THEMSELVES: where each stands and what state he is in. Their minds come after the
    # things on the floor, because a guard who falls leaves one.
    # THE POOL HOLDS ONE FLOOR'S WORTH, not every floor's, because only one floor is ever being
    # played — so it is sized for the busiest and refilled from the tables when a floor starts.
    def declare_the_guards
      return if no_floor_has?(:guards)

      b = @b
      # +dropped+ is whether he is lying beside the clip of ammunition he left when he fell. It is
      # a field of his rather than a place of its own because where the clip lies is where he
      # lies — see Pickups#a_guard_fell.
      # +awake+ is whether he has ever been on the screen. Once he has, he thinks for ever after
      # wherever he stands; until then he thinks only while his room is open to the player. That
      # is the original's own rule (it calls him "active") and it is what keeps a floor of
      # twenty-nine guards affordable — see Rooms.
      @guard = b.pool :guard, x: 0.0, y: 0.0, dir: 0, state: 0, ticks: 0, wait: 0, togo: 0.0,
                              hp: 0, shown: 0, awake: 0, turn: 0, dropped: 0,
                              capacity: room_for(:guards),
                              estimate: { usually: how_many(:guards)[:usually] }
      # THE FIRST FLOOR'S GUARDS AT BOOT, written out rather than read from the tables, because
      # at boot there is no floor to have started yet. Every floor after this one is filled by
      # #put_the_guards_back from the same tables the first floor's numbers came from.
      (@floors.first_floor.guards&.guards || []).each_with_index do |guard, n|
        # A guard stands in the middle of his cell, like the player does.
        state = Guards.starting_state(guard)
        @guard.spawn x: guard.x + 0.5, y: guard.y + 0.5,
                     dir: Guards.direction_of(guard.facing),
                     state: state, ticks: Guards::STATES.fetch(state).ticks,
                     hp: Guards::HIT_POINTS,
                     # ...and thinks on every other frame, alternately with his neighbours, so
                     # the floor's thinking is spread evenly over the frames rather than
                     # arriving all at once.
                     turn: n % 2
      end
      declare_where_the_guards_start
    end

    def declare_the_guards_minds
      return if @guards.nil? || @guards.empty?

      b = @b
      @mind = GuardMind.new(build: b, guards: @guards, pool: @guard, level: @level,
                            world: @world, door_open: @open, walls: { door: DOOR, push: PUSH },
                            things: @things, blocked: @blocked, dying: @dying, pickups: @pickups,
                            sounds: @sounds, rooms: @rooms,
                            floors: @floors, map_base: @map_base,
                            player: { x: @px, y: @py, health: @health, score: @score,
                                      kills: @kills, cos: @vcos, sin: @vsin })
    end

    # WHICH ROOMS ARE OPEN TO THE PLAYER'S, which is what stops a guard on the far side of the
    # floor walking a line of sight at you through six walls. It is a fact about the level rather
    # than about guards — see Rooms — and guards are only the first thing to ask it. A cartridge
    # whose floors are one room each, or which has no doors to join rooms with, builds none of it
    # and pays nothing.
    def declare_the_rooms
      return unless Rooms.needed?(@floors)

      @rooms = Rooms.new(build: @b, floors: @floors, map_base: @map_base,
                         door_first: @door_first, door_count: @door_count, door_open: @open,
                         player: { x: @px, y: @py })
    end

    # WHERE EVERY GUARD STARTED, so the floor can be started again. All of it is settled while
    # the cartridge is built and none of it ever changes, so it lives in the cartridge — the same
    # facts the spawns above are made of, kept where a routine can read them back by number.
    def declare_where_the_guards_start
      b = @b
      everyone = over_floors { |floor| floor.guards&.guards || [] }
      starting = everyone.map { |guard| Guards.starting_state(guard) }
      @guard_home_x = b.table :guard_home_x, at_least_one(everyone.map { |g| g.x + 0.5 })
      @guard_home_y = b.table :guard_home_y, at_least_one(everyone.map { |g| g.y + 0.5 })
      @guard_home_dir = b.table :guard_home_dir,
                                at_least_one(everyone.map { |g| Guards.direction_of(g.facing) }),
                                width: :byte
      @guard_home_state = b.table :guard_home_state, at_least_one(starting), width: :byte
      @guard_home_ticks = b.table :guard_home_ticks,
                                  at_least_one(starting.map { |s| Guards::STATES.fetch(s).ticks }),
                                  width: :byte
    end

    # STARTING THE FLOOR AGAIN, which is everything the level holds that CHANGES put back the way
    # it was built. That is the whole of what a life costs and it is worth listing: where the
    # player stands and what they carry, every door, every wall that slides, every key still lying
    # about, everything picked up, and every guard.
    #
    # Everything here had its starting value applied once at boot, by the declaration that made
    # it. This is the same values written a second time — which is why the ones that are worked
    # out rather than written down (where the player starts, where each guard stands) are read
    # from one place by both.
    #
    # A ROUTINE, not code in the game loop, and for the usual reason: it is a great deal of code
    # that runs at most a few times a game, and the console's quick memory belongs to the eighty
    # rays a frame spends its time in.
    def declare_the_floor_start
      # Emitted when anything can ask for it. Dying is one such thing; so is a lift, which puts
      # the floor back the way it started when it arrives; and so is a menu, whose NEW GAME is
      # this plus a fresh player.
      return if @dying.nil? && !lifts? && !@startable

      @b.func(:start_the_floor, fast: false) { start_the_floor_again }
    end

    def start_the_floor_again
      # WHICH FLOOR'S SLICE OF EVERY TABLE, first, because everything below reads through it.
      go_to_this_floor
      @health.set START_HEALTH
      @ammo.set START_AMMO
      @keys.set 0
      # ...and none of the floor has been found yet, which is what makes these a share of it.
      @kills.set 0
      @secrets.set 0
      @treasures.set 0
      # The lever comes back up and the lift forgets it was ever called.
      if lifts?
        @pulled.set(-1)
        @lift_secret.set 0
        @lift_wait.set 0
      end
      shut_every_door
      put_the_secret_walls_back
      @pickups&.put_them_all_back
      put_the_guards_back
      @dying&.start_again
    end

    # POINT EVERY TABLE AT THIS FLOOR, and put the player where it starts you.
    #
    # ONE ARM PER FLOOR, which looks extravagant and is the cheap way round. The alternative is
    # yet more tables — a first and a count per floor per kind of thing — read at run time. This
    # runs a handful of times in a whole game and never while anybody is playing, so the room it
    # takes in the cartridge buys a table read saved on every door, wall and lever for ever.
    #
    # A ONE-FLOOR CARTRIDGE gets one arm with nothing to compare, so it costs what it always did.
    def go_to_this_floor
      @floors.each_with_index do |floor, n|
        settle = lambda do
          @map_base.set @floors.map_base(n)
          @door_first.set @floors.first_of(:doors, n)
          @door_count.set @floors.count_of(:doors, n)
          @push_first.set @floors.first_of(:pushwalls, n)
          @push_count.set @floors.count_of(:pushwalls, n)
          @guard_count.set @floors.count_of(:guards, n)
          @guard_first.set @floors.first_of(:guards, n)
          @piece_first.set @floors.first_of(:pieces, n)
          @piece_count.set @floors.count_of(:pieces, n)
          @secret_car.set(floor.lifts&.secret_cars&.first || -1)
          @px.set(floor.level.start.x + 0.5)
          @py.set(floor.level.start.y + 0.5)
          @view.set facing_angle(floor.level.start.facing)
        end
        @floors.count == 1 ? settle.call : (@floor == n).then { settle.call }
      end
    end

    def shut_every_door
      return if no_floor_has?(:doors)

      @b.repeat(@door_count, estimate: how_many(:doors)) do |door|
        @open[door] = 0.0
        @linger[door] = 0
      end
    end

    def put_the_secret_walls_back
      return if no_floor_has?(:pushwalls)

      @b.repeat(@push_count, estimate: how_many(:pushwalls)) do |wall|
        @push_step[wall] = 0
        @push_gone[wall] = 0
        @push_wait[wall] = 0
      end
    end

    # EVERYBODY OUT, THEN THIS FLOOR'S PEOPLE IN.
    #
    # A KILLED GUARD IS NEVER TAKEN OUT OF THE POOL while a floor is being played — he lies where
    # he fell, in a state that lasts for ever, because a body is part of the room. So the pool
    # arrives here full of whoever was on the last floor, alive or not, and the count is a
    # different one from the floor about to start.
    #
    # Emptying it and filling it again is the honest way to say that, and it is the pool's own
    # two verbs rather than anything reaching inside it. It also costs nothing worth counting:
    # this runs when a floor starts and never while one is being played.
    def put_the_guards_back
      return if @guard.nil?

      @guard.each(&:remove)
      @b.repeat(@guard_count, estimate: how_many(:guards)) do |n|
        @slot.set(@guard_first + n)
        @guard.spawn x: @guard_home_x[@slot], y: @guard_home_y[@slot],
                     dir: @guard_home_dir[@slot],
                     state: @guard_home_state[@slot], ticks: @guard_home_ticks[@slot],
                     hp: Guards::HIT_POINTS, wait: 0, togo: 0.0, shown: 0, awake: 0, dropped: 0,
                     turn: n % 2
      end
    end

    # What one cell of the map table says. See the note where the table is declared.
    # WHAT ONE CELL OF THE MAP TABLE SAYS. See the note where the table is declared.
    #
    # EVERY NUMBER IN IT IS LOCAL TO ITS OWN FLOOR — door three of this floor, not door
    # ninety-one of the cartridge — because what it names is state the game keeps while playing
    # that floor, and only one floor is ever being played. The tables of things settled while
    # building hold every floor end to end and are reached by adding where this floor's slice
    # starts; the two must not be confused, and keeping the map local is what stops them being.
    def cell_value(floor, x, y)
      level = floor.level
      number = floor.doors.number_at(x, y)
      return DOOR + number - 1 if number

      pushing = floor.pushwalls.number_at(x, y)
      return PUSH + pushing - 1 if pushing

      # A lever, before the plain-wall test below, which would otherwise claim it: a lever IS a
      # wall, and the only thing that makes it more than one is that using it ends the floor.
      lever = floor.lifts&.number_at(x, y)
      return LIFT + lever - 1 if lever

      return 0 unless level.solid?(x, y)

      lit = wall_picture(level.wall_code(x, y))
      lit || 0
    end

    # Where a wall code's lit picture sits in the row of pictures, counting from one so that
    # zero can mean open floor.
    def wall_picture(code)
      at = @atlas.position_of(@atlas.texture_index(code, WallAtlas::LIT))
      at && at + 1
    end

    def door_pictures(floor)
      floor.doors.doors.map { |door| @atlas.position_of(floor.doors.picture_for(door)) }
    end

    # A push wall is made of an ordinary wall, so it wears that wall's picture and picks
    # between its lit and dark form the way any wall does.
    def push_pictures(floor)
      floor.pushwalls.codes.map { |code| wall_picture(code) - 1 }
    end

    # A number as a table will really hold it, to the places a variable with a fraction keeps.
    def as_a_table_holds_it(number) = RubyGBA::Fraction.scale(number, RubyGBA::Fraction::DEFAULT_BITS) /
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

      @pickups.update
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
      @foot.set(@world[@map_base + @spot])
      @can.set 0
      (@foot == 0).then { @can.set 1 }
      # A lever is a wall and stays one however hard you walk at it, so everything below is
      # skipped for one — and skipped rather than added to, so a lever's number can never be read
      # as a door's or a push wall's. Only on a floor that has a lift; see the walk.
      if lifts?
        (@foot < LIFT).then { what_a_foot_finds }
      else
        what_a_foot_finds
      end
      # ...and a barrel in the way stops you on open floor, which nothing else here does.
      (@blocked[@map_base + @spot] == 1).then { @can.set 0 } if @blocked
      @can == 1
    end

    # A doorway you can fit through, or a cell a push wall has left. Everything else under a foot
    # is either plain floor, which is settled above, or something solid, which needs no test.
    def what_a_foot_finds
      (@foot >= PUSH).then do
        # A cell a push wall could reach is floor unless the wall is standing in it now.
        @slot.set(@foot - PUSH)
        @pcell.set(@push_home[@push_first + @slot])
        @pcell.add(@push_gone[@slot] * @push_step[@slot])
        (@pcell != @spot).then { @can.set 1 }
      end.else do
        (@foot >= DOOR).then do
          @slot.set(@foot - DOOR)
          (@open[@slot] > DOOR_WALKABLE).then { @can.set 1 }
        end
      end
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
        @foot.set(@world[@map_base + @ahead])

        if lifts?
          (@foot >= LIFT).then { pull_the_lever }.else { use_what_moves }
        else
          use_what_moves
        end
      end
    end

    # The button meeting a wall that slides away, or a door.
    def use_what_moves
      (@foot >= PUSH).then { shove_a_wall }
          .else do
            (@foot >= DOOR).then do
              @slot.set(@foot - DOOR)
              # A locked door wants its key. Without it, nothing happens at all.
              #
              # Nested rather than joined with "or", because joining works out BOTH sides —
              # and the second side divides by which key is wanted, which is nought for a door
              # that wants none.
              @want.set(@door_lock[@door_first + @slot])
              @can.set 0
              (@want == 0).then { @can.set 1 }
              (@want > 0).then { ((@keys / @want) % 2 == 1).then { @can.set 1 } }
              (@can == 1).then do
                # ...and it is heard only when it was SHUT. Pressing at a door already open tops
                # its count back up, which is not a door opening and does not sound like one.
                (@open[@slot] == 0.0).then { @sounds.door_opens }
                @linger[@slot] = DOOR_LINGER
              end
            end
          end
    end

    # PULL THE LEVER AND THE FLOOR IS OVER.
    #
    # It does not end on this frame, and the wait is not padding: the lever swaps to its pulled
    # picture and the player gets to see it do that before the screen changes. A lift that ended
    # the floor on the same frame you pulled it would never show the second picture at all. The
    # original waits here too, and for a reason worth keeping — it plays the lift's sound and
    # then waits for the sound to finish before showing the tally.
    #
    # SO THE WAIT IS THE SOUND, and that is where the number comes from rather than from taste:
    # the recording is two thirds of a second, which is forty frames. See LIFT_WAIT.
    #
    # ONLY FACING EAST OR WEST. The original decides which cell you are using by snapping your
    # angle to a cardinal direction, and it allows a lever on two of the four — a lever you are
    # facing north or south at does nothing at all. It reads as a quirk and it is load-bearing:
    # it is the reason id could ship a blank picture for the lever's other face. Here the test is
    # the same one written the way this renderer thinks, which is that the east-west part of
    # where you are looking is the bigger part.
    #
    # A LEVER ALREADY PULLED IGNORES YOU, so leaning on the button does not restart the count.
    def pull_the_lever
      @across.set(@sin[@view + QUARTER])
      @across.abs
      @along.set(@sin[@view])
      @along.abs
      ((@across > @along) & (@pulled < 0)).then do
        @pulled.set @ahead
        @lift_wait.set lift_wait_frames
        # WHERE THE LIFT GOES is decided by the cell the player is standing on, not by the lever
        # — which is the original's own test, and is why nothing here has to model a car. A floor
        # has one such cell or none, so this is a comparison against a number settled at build
        # time rather than a table to look in.
        # One comparison, whatever the cartridge holds: which cell means the secret lift on THIS
        # floor was settled when the floor started (see #go_to_this_floor), so there is no arm
        # per floor here and no table to read.
        if @floors.any? { |floor| floor.lifts && !floor.lifts.secret_cars.empty? }
          @here.set((@py.to_i * @level.width) + @px.to_i)
          (@here == @secret_car).then { @lift_secret.set 1 }
        end
        @sounds.level_done
      end
    end

    # The floor ends when that count runs out.
    def run_the_lift
      (@lift_wait > 0).then do
        @lift_wait.sub 1
        (@lift_wait == 0).then { go_to_the_next_floor }
      end
    end

    # WHERE THE LIFT TAKES YOU, read off the original (wl_game.cpp) rather than remembered. Three
    # rules and they are tested in this order, which matters:
    #
    #   COMING BACK FROM THE SECRET FLOOR puts you on the normal run, not one further along it.
    #     The original keeps a small table of where each episode comes back to; for the first it
    #     is the second floor.
    #   GOING TO THE SECRET FLOOR is what the secret lever does, and there is one such floor per
    #     episode — the last of the ten.
    #   OTHERWISE the next floor along.
    #
    # A CARTRIDGE HOLDING FEWER FLOORS THAN A WHOLE EPISODE has no secret floor, so neither of the
    # first two rules is emitted at all and every lever simply goes to the next floor. Clamping
    # them to a floor it does have was tried and is wrong in a way worth remembering: the floor a
    # missing one clamps to is the FIRST, so "are you coming back from the secret floor" became
    # "are you on the first floor", which is true at the start of every game.
    #
    # AND WHEN IT RUNS OUT OF FLOORS it goes round to the first. That is not the original, which
    # has an episode to end; this has nowhere to put an ending yet, and going round beats stopping
    # dead on a lever that does nothing.
    SECRET_FLOOR = 9
    BACK_FROM_SECRET = 1

    def go_to_the_next_floor
      if @floors.count > SECRET_FLOOR
        (@floor == SECRET_FLOOR).then { @floor.set BACK_FROM_SECRET }
          .else do
            (@lift_secret == 1).then { @floor.set SECRET_FLOOR }.else { on_to_the_next_floor }
          end
      elsif @floors.count > 1
        on_to_the_next_floor
      end
      @b.call :start_the_floor
    end

    def on_to_the_next_floor
      @floor.add 1
      (@floor > @floors.count - 1).then { @floor.set 0 }
    end

    # Lean on a secret wall and it goes. Which way it goes is which way you are pushing, taken
    # to the nearer of the two axes — you cannot shove a wall diagonally.
    def shove_a_wall
      @slot.set(@foot - PUSH)
      # Only from its own cell, and only once. A wall already on the move ignores you.
      ((@ahead == @push_home[@push_first + @slot]) & (@push_step[@slot] == 0)).then do
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
        # Found, and counted once: this arm only runs for a wall standing in its own cell that
        # is not already moving, so leaning on the same wall again cannot count it twice.
        @secrets.add 1
        @sounds.secret_wall
      end
    end

    # Every push wall, every frame. One that has been shoved counts down to its next cell and
    # stops after two — which is what makes a secret passage a passage rather than a hole.
    def move_the_walls
      return if no_floor_has?(:pushwalls)

      @b.repeat(@push_count, estimate: how_many(:pushwalls)) do |wall|
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

    # Every door, every frame. A door with time left on it is going open; one without is going
    # shut. That one number is the whole of a door's mind, and it is what makes "open, wait,
    # then close" a subtraction rather than a state machine.
    #
    # Standing in the doorway tops the count back up, so a door cannot shut on you.
    def move_the_doors
      return if no_floor_has?(:doors)

      b = @b
      @here.set(@world[@map_base + (@py.to_i * @level.width) + @px.to_i])
      b.repeat(@door_count, estimate: how_many(:doors)) do |door|
        (@here == DOOR + door).then { @linger[door] = DOOR_LINGER }
        @wait.set(@linger[door])
        @swing.set(@open[door])
        (@wait > 0).then do
          @linger[door] = @wait - 1
          # The last frame of standing open: after this one it starts to swing shut, which is
          # the moment to hear it. Tested here rather than on the way down so it sounds once.
          (@wait == 1).then { @sounds.door_shuts }
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
      b.repeat(CROSSINGS, stop_when: @hit == 1, estimate: { usually: USUAL_CROSSINGS }) do
        (@sidex < @sidey).then do
          @sidex.add @deltax
          @mapx.add @stepmx
          @side.set 0
        end.else do
          @sidey.add @deltay
          @mapy.add @stepmy
          @side.set 1
        end
        @cell.set(@world[@map_base + (@mapy * width) + @mapx])
        (@cell > 0).then do
          # Something is here. Only now is it worth asking WHICH kind, because the ray has
          # stopped either way — every step before this one paid a single test and no more.
          #
          # A floor with no lift on it never asks about one: the map cannot hold a lever there,
          # so the test would be a comparison that is false for ever. The boss floor is exactly
          # that floor — you finish it by killing the boss.
          if lifts?
            (@cell >= LIFT).then { meet_a_lever }.else { meet_what_moves(width) }
          else
            meet_what_moves(width)
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

      # ...AND NO NEARER THAN THIS, which is not about perspective. See NEAREST.
      @seen.clamp(NEAREST, FAR)

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

    # Does this floor have a lift at all? Every lever test is built only when it does — see the
    # note in the walk.
    # Does ANY floor have a lift? The lever code is emitted for the cartridge rather than for one
    # floor, so a game whose second floor has a lift emits it even while the first is being
    # played. A game with none anywhere emits none.
    def lifts? = !no_floor_has?(:lifts)

    # The two things in a cell that are more than a wall, and the wall that is only a wall.
    def meet_what_moves(width)
      (@cell >= PUSH).then { meet_a_pushwall(width) }
        .else do
          (@cell >= DOOR).then { meet_a_door }.else do
            @hit.set 1
            @wall.set(@cell - 1 + @side)
            @isdoor.set 0
          end
        end
    end

    # A RAY MEETS A LEVER, which is a wall that wears one of two pictures.
    #
    # The map cannot say which, for the same reason it cannot say where a push wall is: it lives
    # in the cartridge and cannot be written to. So the map says only "a lever", and which single
    # cell has been pulled is one number in memory.
    #
    # ONE CELL, not the whole lift, which is what the original does — it flips the tile you used
    # and no other. That matters more than it sounds: a car has a lever on two or three of its
    # walls, and flipping them all would show the pulled picture on faces the original never
    # shows it on. See the note on pulled_picture for why those faces are worth avoiding.
    def meet_a_lever
      @hit.set 1
      @isdoor.set 0
      (@pulled == (@mapy * @level.width) + @mapx).then { @wall.set(pulled_picture + @side) }
                                                 .else { @wall.set(lever_picture + @side) }
    end

    # Where the two lever pictures sit in the row of them, worked out while building. A lever
    # does not turn, so which of a picture's two faces shows is the only choice left to the walk.
    def lever_picture = @atlas.position_of(@atlas.texture_index(Elevator::SWITCH, WallAtlas::LIT))

    # THE PULLED LEVER HAS ONLY ONE REAL FACE, and finding that out was the thing that explained
    # the whole shape of this feature.
    #
    # Of the 106 wall pictures in the game, exactly one is a single flat colour: the LIT face of
    # the pulled lever. That looks like a decoding fault until you read what the original does
    # with the lever — you may only pull one while facing EAST or WEST, so the only face of a
    # pulled lever a player can ever be looking at is a vertical one, which is the dark face. id
    # shipped a blank for the face nobody can reach. Reproducing the facing rule is therefore not
    # pedantry about a quirk; it is what keeps the blank off the screen.
    def pulled_picture = @atlas.position_of(@atlas.texture_index(Elevator::PULLED, WallAtlas::LIT))

    # A RAY REACHES A CELL A PUSH WALL COULD BE IN, which is not the same as one it IS in.
    #
    # The map cannot say where a push wall is, because the map is in the cartridge and a push
    # wall moves. So the map marks everywhere one could ever get to, and the answer is worked
    # out here: where it started, plus how far it has gone in the direction it was shoved. If
    # that is this cell it is a wall like any other; if not, this cell is the floor the map
    # always said it was and the ray carries straight on.
    def meet_a_pushwall(width)
      @push.set(@cell - PUSH)
      @pcell.set(@push_home[@push_first + @push])
      @pcell.add(@push_gone[@push] * @push_step[@push])
      (@pcell == (@mapy * width) + @mapx).then do
        @hit.set 1
        @isdoor.set 0
        @wall.set(@push_face[@push_first + @push] + @side)
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

      (@door_across[@door_first + @door] == 0).then do
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
          @wall.set(@door_picture[@door_first + @door])
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
    # HOW TALL A WALL COLUMN USUALLY IS, for the estimate only — nothing about how the game runs
    # reads it. Every height here is worked out as the game runs, because that is what
    # perspective is, so nothing at build time can know how far down the screen a walk goes. The
    # estimate would otherwise guess half the view.
    #
    # Measured on a running cartridge rather than reasoned about: the column heights this
    # renderer produces, sampled over a full turn on the first floor, average about half the
    # view — near walls are clipped at the top rather than drawn shorter, which piles the tall
    # ones up at the ceiling instead of spreading them out.
    USUALLY_TALL = VIEW_H / 2

    def strip(col, slice)
      b = @b
      depth = @standing&.depth
      drawn = (@hit == 1).then do
        depth[col] = @colh if depth
        b.draw_column_at :walls, slice: slice, x: col * COLUMN_W, top: @top, height: @colh,
                                 estimate: { usually: USUALLY_TALL },
                                 width: COLUMN_W
      end
      drawn.else { depth[col] = 0 } if depth
    end
  end
end
