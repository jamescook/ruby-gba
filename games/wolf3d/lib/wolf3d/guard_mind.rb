# frozen_string_literal: true

module Wolf3D
  # WHAT A GUARD DOES with each frame, which is a state machine and almost nothing else.
  #
  # The original's actor table is plain data — a picture, how long to stand in it, what to think
  # about while there, and which row comes next — and the whole of a guard's behaviour is that
  # table plus three things to think about. He looks for you while standing. He walks his beat
  # while patrolling, looking as he goes. He closes on you once he has seen you, and stops to
  # take a shot when he has a clear line.
  #
  # WHAT LIVES HERE AND WHAT DOES NOT: this decides where a guard is and which state he is in.
  # Drawing him is the view's business, and it reads the same pool.
  class GuardMind
    # A guard walks from the middle of one cell to the middle of the next and never stops
    # between them, which is what makes "can he go that way" a question about a single cell.
    CELL = 1.0

    # What each of the three thinking jobs is numbered, so one table can say which to do.
    NOTHING = 0
    LOOK = 1
    PATROL = 2
    CHASE = 3

    # WHETHER HE FIRES is a chance against distance, taken every frame he has a clear line —
    # which is why a guard sometimes just stands there aiming. The original's number is sixteen
    # times the time elapsed, divided by the distance in cells, out of 256. Worked out here for
    # every distance rather than divided as the game runs; at arm's length it is a certainty.
    CHANCES = 256

    # HOW NEAR THE MIDDLE OF THE VIEW a guard has to be for a shot to be about him: a tenth of
    # the screen either side, which is the original's. Turned into a slope so the test needs no
    # divide — a guard is in the sights when how far he is to the side of the line you are
    # looking down is less than this much of how far in front of you he is.
    AIM = (240 / 10) / FirstPerson::WALL_SCALE

    # Nothing is a target.
    NOBODY = -1

    def initialize(build:, guards:, pool:, level:, world:, player:, door_open:, walls:, things:,
                   blocked: nil, dying: nil)
      @b = build
      @dying = dying      # what to tell when a shot takes the last of the health, or nil
      @guards = guards
      @pool = pool
      @level = level
      @world = world      # the flat map table the ray walk reads
      @things = things    # the row of pictures everything standing in the level is drawn from
      @blocked = blocked  # which cells hold scenery a foot cannot pass, or nil for a bare floor
      @player = player    # { x:, y: } as the view keeps them
      @open = door_open   # how far each door has slid
      @walls = walls      # where that table stops naming walls: { door: N, push: N }
      declare
    end

    # What the picture of a state is, and whether it turns — the view reads these to draw.
    attr_reader :picture_of, :turns_of

    # One frame of thinking, for every guard on the floor.
    #
    # KEPT IN A ROUTINE OF ITS OWN, and told to stay out of the quick memory. The framework
    # gives that memory to whatever a frame spends its time in, and the view's own loop — eighty
    # rays and eighty stretched columns — is the thing that wants it. All of this is a great
    # deal of code and hardly any of a frame's work: ten guards think a few dozen statements
    # each, where the view draws thousands of pixels. Leaving it in the loop's own body pushed
    # the loop out of the quick memory and made the WHOLE frame two and a half times dearer,
    # which is the price of running from the cartridge instead.
    def update
      @b.call :guard_thinking
    end

    private

    def declare
      b = @b
      states = Guards::STATES

      # THE STATE TABLE, as tables the game reads by state number. Kept apart rather than as one
      # row per state because each is read on its own.
      @picture_of = b.table :guard_picture,
                            states.map { |s| @things.position_of(Guards.picture_of(s)) }, width: :byte
      @turns_of = b.table :guard_turns, states.map { |s| s.turns ? 1 : 0 }, width: :byte
      @ticks_of = b.table :guard_ticks, states.map(&:ticks), width: :byte
      @becomes_of = b.table :guard_becomes, states.map { |s| Guards.state_number(s.becomes) }, width: :byte
      @think_of = b.table :guard_think, states.map { |s| Guards::THINKING.fetch(s.think) }, width: :byte
      @fires_of = b.table :guard_fires, states.map { |s| s.fires ? 1 : 0 }, width: :byte
      @roused_of = b.table :guard_roused, states.map { |s| Guards.roused?(s) ? 1 : 0 }, width: :byte

      # WHICH WAY EACH DIRECTION GOES, one cell at a time. Nine entries: eight ways round and
      # then nowhere, which is where a guard hemmed in on every side ends up.
      steps = Guards::WAYS + [[0, 0]]
      @step_x = b.table :guard_step_x, steps.map(&:first)
      @step_y = b.table :guard_step_y, steps.map(&:last)

      # A TURNING POINT UNDER A PATROLLING GUARD sends him a new way. Nowhere means carry on.
      @arrow = b.table :guard_arrow,
                       @level.each_cell.map { |x, y| @guards.arrow_at(x, y) || Guards::NOWHERE },
                       width: :byte

      reach = [@level.width, @level.height].max
      @shot = b.table :guard_shot, (0..reach).map { |away| shot_chance(away) }

      @chase1 = Guards.state_number(:chase1)
      @shoot1 = Guards.state_number(:shoot1)
      @hurt1 = Guards.state_number(:hurt1)
      @hurt2 = Guards.state_number(:hurt2)
      @fall1 = Guards.state_number(:fall1)
      @patrol_step = Guards.speed
      @chase_step = Guards.speed(chasing: true)
      @width = @level.width
      @reach = reach

      declare_the_scratch
      # The two pieces asked for from many places, each emitted once. See where each is defined
      # for what that is worth and why it can be done at all.
      declare_the_line_walk
      declare_the_walkable_test

      # WHOSE TURN IT IS. Flipped each time this routine runs, and a guard thinks on the turns
      # that match his — so half of them think each time and a guard is thought about every
      # other one. See Guards::TICKS_PER_THINK for why that is often enough.
      #
      # FLIPPED HERE rather than on its own beat, so that whatever paces the world paces this
      # too. A turn flipped once a FRAME while the world moved once a PASS would flip twice
      # between two moves on a game taking two frames a pass — back to where it started, so the
      # same half would think every time and the other half never.
      @turn = b.var :_gturn, 0
      b.func(:guard_thinking, fast: false) do
        @turn.set((@turn + 1) % 2)
        @pool.each { |guard| (guard.turn == @turn).then { think(guard) } }
      end
    end

    # At nothing at all he cannot miss the chance; beyond that it falls away with distance.
    def shot_chance(away)
      return CHANCES if away.zero?

      [(16 * Guards::TICKS_PER_THINK / Guards::SCALE) / away, CHANCES].min
    end

    def declare_the_scratch
      b = @b
      @state, @dir, @job, @try, @slot, @cellx, @celly, @clear, @done, @ahead, @way, @picked,
        @tx, @ty, @away, @target, @odds, @wound, @spot =
        %i[gstate gdir gjob gtry gslot gcellx gcelly gclear gdone gahead gway gpicked
           gtx gty gaway gtarget godds gwound gspot].map { |name| b.var(:"_#{name}", 0) }
      @dx, @dy, @absx, @absy, @stepx, @stepy, @far, @atx, @aty, @pace, @fwd, @sideways, @nearest,
        @fromx, @fromy =
        %i[gdx gdy gabsx gabsy gstepx gstepy gfar gatx gaty gpace gfwd gsideways gnearest
           gfromx gfromy].map { |name| b.var(:"_#{name}", 0.0) }
    end

    # ONE GUARD, ONE FRAME. Count his state down, move him on when it runs out, then let him
    # think — which is the order the original does it in, and it matters: a state that has just
    # begun thinks on the frame it begins.
    def think(guard)
      @state.set guard.state
      step_the_state(guard)

      @job.set(@think_of[guard.state])
      (@job == LOOK).then { look(guard) }
      (@job == PATROL).then { patrol(guard) }
      (@job == CHASE).then { chase(guard) }
    end

    # A state with no length never runs down — that is how standing goes on forever. One step a
    # think is enough for every other: the shortest state in the table is nine of these units
    # long and a think is worth seven, so a think can never step clean over one.
    def step_the_state(guard)
      (@ticks_of[@state] > 0).then do
        guard.ticks.sub Guards::TICKS_PER_THINK
        (guard.ticks <= 0).then do
          # The shot leaves as he LEAVES the state he aimed in, which is where the original
          # hangs it: aiming, firing and lowering the arm are three pictures and the bullet
          # belongs to the join between the second and the third.
          (@fires_of[@state] == 1).then { fire_at_the_player(guard) }
          guard.state.set(@becomes_of[@state])
          guard.ticks.add(@ticks_of[guard.state])
        end
      end
    end

    # HIS SHOT IS NOT AIMED. It is a chance against distance, and the far half of that chance
    # depends on whether you can SEE him — a guard you are looking at misses more, because you
    # could be dodging. That is the game quietly being fair, and it is in the original's
    # numbers rather than anywhere else.
    #
    # What it does when it lands is by distance too: a byte of randomness shifted down twice
    # inside two cells, three times inside four, four times beyond. So a guard across the room
    # does almost nothing and one in your face does real harm.
    def fire_at_the_player(guard)
      @dx.set(@player[:x] - guard.x)
      @dy.set(@player[:y] - guard.y)
      line_of_sight(guard)
      (@clear == 1).then do
        how_far_away(guard)
        @odds.set(CHANCES - (@away * 8))
        (guard.shown == 1).then { @odds.set(CHANCES - (@away * 16)) }
        (@b.rand(0..CHANCES - 1) < @odds).then { wound_the_player(guard) }
      end
    end

    # THE SHOT THAT TAKES THE LAST OF THE HEALTH IS THE ONE THE DEATH NEEDS TO KNOW ABOUT, and
    # this is the only place that knows which guard fired it. The view turns to face him, so who
    # it was has to be caught here rather than worked out afterwards from a body on the floor.
    def wound_the_player(guard)
      @wound.set(@b.rand(0..CHANCES - 1) / 4)
      (@away >= 2).then { @wound.set(@b.rand(0..CHANCES - 1) / 8) }
      (@away >= 4).then { @wound.set(@b.rand(0..CHANCES - 1) / 16) }
      @player[:health].sub @wound
      (@player[:health] <= 0).then do
        @player[:health].set 0
        @dying&.struck_by(guard)
      end
    end

    # --- looking for you -------------------------------------------------------------

    # Looking has two halves. He has to be able to SEE you, and then he has to REACT — a moment
    # of up to about a second before he turns and comes. That delay is why the game feels fair:
    # you get a beat between being seen and being come after.
    def look(guard)
      (guard.wait > 0).then do
        guard.wait.sub Guards::TICKS_PER_THINK
        (guard.wait <= 0).then do
          guard.wait.set 0
          first_sighting(guard)
        end
      end.else do
        can_see(guard)
        (@clear == 1).then { guard.wait.set(@b.rand(1..Guards::REACTION)) }
      end
    end

    # He has seen you: he breaks into a chase, and from here he moves three times as fast.
    def first_sighting(guard)
      guard.state.set @chase1
      guard.ticks.set(@ticks_of[@chase1])
      guard.togo.set 0.0
    end

    # CAN HE SEE YOU? Three questions in order, cheapest first. Are you near enough that it does
    # not matter which way he faces. Are you in front of him at all. And is anything between you.
    def can_see(guard)
      @dx.set(@player[:x] - guard.x)
      @dy.set(@player[:y] - guard.y)
      near = Guards::AUTOMATIC_SIGHT

      ((@dx > -near) & (@dx < near) & (@dy > -near) & (@dy < near)).then { @clear.set 1 }
        .else do
          in_front(guard)
          (@clear == 1).then { line_of_sight(guard) }
        end
    end

    # IS THE PLAYER IN FRONT OF HIM, which the original answers with one comparison per facing
    # rather than an angle. A guard facing north cannot see anything south of him; each diagonal
    # takes the two halves together.
    def in_front(guard)
      @clear.set 1
      @dir.set guard.dir
      (@dir == 2).then { (@dy > 0.0).then { @clear.set 0 } }   # north
      (@dir == 0).then { (@dx < 0.0).then { @clear.set 0 } }   # east
      (@dir == 6).then { (@dy < 0.0).then { @clear.set 0 } }   # south
      (@dir == 4).then { (@dx > 0.0).then { @clear.set 0 } }   # west
      (@dir == 3).then { (@dy > -@dx).then { @clear.set 0 } }  # northwest
      (@dir == 1).then { (@dy > @dx).then { @clear.set 0 } }   # northeast
      (@dir == 5).then { (@dx > @dy).then { @clear.set 0 } }   # southwest
      (@dir == 7).then { (-@dx > @dy).then { @clear.set 0 } }  # southeast
    end

    # IS ANYTHING BETWEEN THEM: a step at a time from the guard toward the player, stopping at
    # the first thing that blocks. A shut door blocks; an open one does not.
    #
    # The ceiling is the width of the map, which no line can exceed, and the walk leaves as soon
    # as it arrives — so what it usually costs is how far apart they are, not how far apart they
    # could ever be.
    #
    # HOW SOON IT STOPS is measured rather than felt. Walking this same line on the first floor,
    # from every guard on it to eighty-five places the player can stand, it takes five steps in
    # the middle of the range and nine in ten take under seven — because almost every line meets
    # a wall almost at once. Not one of five hundred ever ran out of the sixty-four it is
    # allowed. So the ceiling is generous and free, and five is what a frame really pays.
    def line_of_sight(guard) = walk_the_sight_line_from(guard.x, guard.y)

    # ONE COPY OF THE WALK, NOT FOUR, and that is what this indirection buys.
    #
    # It is asked from four places — a guard looking, a guard about to fire, and a bullet
    # picking its target — and a Ruby method call here is INLINED into the program, so four
    # asks used to mean four copies of the loop, the divide and the wall test. That is a great
    # deal of code for a routine whose whole job is to walk a handful of cells, and code is the
    # thing this game is short of: the console's quick memory holds 32K, the frame's own loop
    # wants nearly all of it, and what a guard emits decides whether both can fit.
    #
    # Every one of its inputs is working room already, so all a caller has to hand over is where
    # the line starts.
    def walk_the_sight_line_from(fromx, fromy)
      @fromx.set fromx
      @fromy.set fromy
      @b.call :walk_the_sight_line
    end

    def declare_the_line_walk
      @b.func(:walk_the_sight_line) { walk_the_sight_line }
    end

    # The line itself, walked from wherever it was told to start — a guard looking for you, or a
    # bullet on its way to him.
    def walk_the_sight_line
      b = @b
      aim_along_the_line(@fromx, @fromy)
      @tx.set(@player[:x].to_i)
      @ty.set(@player[:y].to_i)
      @clear.set 1
      @done.set 0

      b.repeat(@reach, stop_when: @done == 1, estimate: { usually: 5 }) do
        @atx.add @stepx
        @aty.add @stepy
        @cellx.set @atx.to_i
        @celly.set @aty.to_i

        ((@cellx == @tx) & (@celly == @ty)).then { @done.set 1 }.else do
          @ahead.set(@world[(@celly * @width) + @cellx])
          (@ahead > 0).then { blocked_by(@ahead) }
          (@clear == 0).then { @done.set 1 }
        end
      end
    end

    # A step along the line from the guard toward the player, sized so the longer of the two
    # directions moves one whole cell each time — which is what makes the walk visit every cell
    # the line passes through without visiting any twice.
    # ONE DIVIDE AT MOST, NOT TWO, and the one that goes was never doing any work.
    #
    # The step is the direction scaled so the LONGER of the two moves one whole cell. Which
    # means the longer one's step is one whole cell — plus or minus — by construction, and
    # dividing it by its own size can only ever give back the one it already is. So it is set
    # from the sign instead, and only the shorter of the two is divided.
    #
    # That matters here because dividing a number holding a fraction by another is the dearest
    # arithmetic there is — about nine times an ordinary step, where every other divide is a
    # third to three — and these two were a fifth of everything a guard spends in a frame. The
    # walk that follows is unchanged, step for step.
    #
    # And when the two are both under a cell apart the scaling is held at one, so neither is
    # divided at all: the step IS the direction. That is the near case, which is the one a guard
    # about to shoot you is in.
    def aim_along_the_line(fromx, fromy)
      @absx.set @dx
      @absx.abs
      @absy.set @dy
      @absy.abs

      @stepx.set @dx
      @stepy.set @dy
      (@absx > @absy).then do
        (@absx > 1.0).then do
          @stepx.set(1.0)
          (@dx < 0.0).then { @stepx.set(-1.0) }
          @stepy.set(@dy / @absx)
        end
      end.else do
        (@absy > 1.0).then do
          @stepy.set(1.0)
          (@dy < 0.0).then { @stepy.set(-1.0) }
          @stepx.set(@dx / @absy)
        end
      end

      @atx.set fromx
      @aty.set fromy
    end

    # Something is in this cell. A wall stops the line; a doorway stops it only while its panel
    # is still across the way. A cell a secret wall could reach counts as clear, because the
    # wall is usually not in it and a guard blinded by a wall that is not there would be odd.
    def blocked_by(cell)
      (cell < @walls[:push]).then do
        (cell >= @walls[:door]).then do
          @slot.set(cell - @walls[:door])
          (@open[@slot] < FirstPerson::DOOR_WALKABLE).then { @clear.set 0 }
        end.else { @clear.set 0 }
      end
    end

    # --- walking a beat --------------------------------------------------------------

    # A patrolling guard looks for you first — the whole point of a patrol is that it walks into
    # you — and then carries on to the next cell, unless looking has just set him chasing.
    def patrol(guard)
      look(guard)
      (@think_of[guard.state] == PATROL).then do
        (guard.togo <= 0.0).then { choose_a_patrol_way(guard) }
        walk(guard, @patrol_step, patrolling: true)
      end
    end

    # A turning point under his feet sends him a new way; without one he carries straight on.
    # Either way he only sets off if he can actually get there.
    def choose_a_patrol_way(guard)
      @way.set(@arrow[(guard.y.to_i * @width) + guard.x.to_i])
      (@way < Guards::NOWHERE).then { guard.dir.set @way }
      @picked.set 0
      try_this_way(guard, guard.dir)
      (@picked == 0).then { guard.dir.set Guards::NOWHERE }
    end

    # --- coming after you ------------------------------------------------------------

    # A CHASE IS NOT PATHFINDING. Try the way toward the player on the longer axis, then the
    # other, then whatever way he was already going. A guard who can do none of those stands
    # still, which is why the original's guards get stuck on corners.
    #
    # And with a clear line at you he stops to take a shot instead of closing further.
    def chase(guard)
      take_a_shot(guard)
      (@think_of[guard.state] == CHASE).then do
        (guard.togo <= 0.0).then { choose_a_chase_way(guard) }
        walk(guard, @chase_step, patrolling: false)
      end
    end

    def take_a_shot(guard)
      @dx.set(@player[:x] - guard.x)
      @dy.set(@player[:y] - guard.y)
      line_of_sight(guard)
      (@clear == 1).then do
        how_far_away(guard)
        (@b.rand(0..CHANCES - 1) < @shot[@away]).then { start_firing(guard) }
      end
    end

    # How far away in whole cells, taken on whichever of the two axes is the bigger — which is
    # the distance the original's guards judge a shot by.
    def how_far_away(guard)
      @cellx.set(@player[:x].to_i - guard.x.to_i)
      (@cellx < 0).then { @cellx.set(0 - @cellx) }
      @celly.set(@player[:y].to_i - guard.y.to_i)
      (@celly < 0).then { @celly.set(0 - @celly) }
      @away.set @cellx
      (@celly > @away).then { @away.set @celly }
      @away.clamp 0, @reach
    end

    def start_firing(guard)
      guard.state.set @shoot1
      guard.ticks.set(@ticks_of[@shoot1])
      guard.togo.set 0.0
    end

    # Toward the player on the longer axis first, then the other, then on as before.
    def choose_a_chase_way(guard)
      @dx.set(@player[:x] - guard.x)
      @dy.set(@player[:y] - guard.y)
      @absx.set @dx
      @absx.abs
      @absy.set @dy
      @absy.abs

      @way.set 4                                  # west
      (@dx > 0.0).then { @way.set 0 }             # east
      @try.set 2                                  # north
      (@dy > 0.0).then { @try.set 6 }             # south
      # The longer way is tried first, so swap them when the up-and-down one is longer.
      (@absy > @absx).then do
        @cellx.set @way
        @way.set @try
        @try.set @cellx
      end

      @picked.set 0
      try_this_way(guard, @way)
      (@picked == 0).then { try_this_way(guard, @try) }
      (@picked == 0).then { try_this_way(guard, guard.dir) }
      (@picked == 0).then { guard.dir.set Guards::NOWHERE }
    end

    # Can he walk one cell that way? If so he sets off, and from here he is between two cells
    # until he arrives.
    def try_this_way(guard, way)
      @try.set way
      (@try < Guards::NOWHERE).then do
        @cellx.set(guard.x.to_i + @step_x[@try])
        @celly.set(guard.y.to_i + @step_y[@try])
        free_to_walk
        (@clear == 1).then do
          guard.dir.set @try
          guard.togo.set CELL
          @picked.set 1
        end
      end
    end

    # ONE COPY OF THIS TOO, and it is asked from more places than anything else here: a guard
    # picking a way to go tries as many as eight of them, and each try used to emit the whole
    # question again. It reads and writes nothing but working room, so it needs nothing passed
    # to it at all — the caller says which cell in @cellx and @celly, which it was doing anyway.
    def free_to_walk = @b.call(:can_a_guard_walk_there)

    def declare_the_walkable_test
      @b.func(:can_a_guard_walk_there) { walkable }
    end

    # A cell a guard can walk into: open floor, or a doorway whose panel has slid out of the
    # way, and nothing standing in it that a body cannot pass. The same question the player's
    # feet ask, asked of a guard — and a guard is stopped by a barrel exactly as you are.
    def walkable
      @spot.set((@celly * @width) + @cellx)
      @ahead.set(@world[@spot])
      @clear.set 0
      (@ahead == 0).then { @clear.set 1 }
      (@ahead >= @walls[:door]).then do
        (@ahead < @walls[:push]).then do
          @slot.set(@ahead - @walls[:door])
          (@open[@slot] > FirstPerson::DOOR_WALKABLE).then { @clear.set 1 }
        end
      end
      (@blocked[@spot] == 1).then { @clear.set 0 } if @blocked
    end

    public

    # --- being shot at ---------------------------------------------------------------

    # THE PLAYER FIRES. A pistol shot goes to the NEAREST guard who is in the sights and has
    # nothing between him and you — not to whatever the middle strip of the view happens to be
    # pointing at, which is a rule people expect and the original does not have.
    #
    # "In the sights" is a tenth of the screen either side of the middle, as a slope: how far
    # he is to the side of the line you are looking down, against how far in front of you he
    # is. Written that way it is a multiply and a comparison and never a divide.
    def shoot
      b = @b
      alive = RubyGBA::List.new(b, @pool.active_list)
      @target.set NOBODY
      @nearest.set FAR_AWAY

      b.repeat(@pool.capacity) do |slot|
        (alive[slot] == 1).then { consider_as_a_target(slot) }
      end

      (@target != NOBODY).then { hit_the_target }
    end

    private

    # The furthest anything can be, so the first candidate always beats it.
    FAR_AWAY = 1000.0

    # Is this one in the sights, in the open, and nearer than the best so far?
    def consider_as_a_target(slot)
      hp = @pool.field_ref(:hp, slot)
      (hp > 0).then do
        x = @pool.field_ref(:x, slot)
        y = @pool.field_ref(:y, slot)
        @dx.set(x - @player[:x])
        @dy.set(y - @player[:y])

        # Where he is in front of the eye, and to the side of it.
        @fwd.set(@dx * @player[:cos])
        @fwd.add(@dy * @player[:sin])
        @sideways.set(@dy * @player[:cos])
        @sideways.sub(@dx * @player[:sin])
        @absx.set @sideways
        @absx.abs

        ((@fwd > 0.0) & (@fwd < @nearest) & (@absx < (@fwd * AIM))).then do
          # Only now is a line worth walking, and it is walked from him toward you — the same
          # line either way.
          @dx.set(@player[:x] - x)
          @dy.set(@player[:y] - y)
          walk_the_sight_line_from(x, y)
          (@clear == 1).then do
            @nearest.set @fwd
            @target.set slot
          end
        end
      end
    end

    # WHAT A PISTOL DOES, by distance, and the third case can miss outright: past four cells a
    # roll has to beat the distance or the shot goes wide, which is why a pistol across a room
    # is a waste of a bullet.
    def hit_the_target
      x = @pool.field_ref(:x, @target)
      y = @pool.field_ref(:y, @target)
      @cellx.set((@player[:x].to_i - x.to_i))
      (@cellx < 0).then { @cellx.set(0 - @cellx) }
      @celly.set((@player[:y].to_i - y.to_i))
      (@celly < 0).then { @celly.set(0 - @celly) }
      @away.set @cellx
      (@celly > @away).then { @away.set @celly }

      @wound.set(@b.rand(0..CHANCES - 1) / 4)
      (@away >= 2).then { @wound.set(@b.rand(0..CHANCES - 1) / 6) }
      (@away >= 4).then do
        # Far enough away to miss altogether.
        (@b.rand(0..CHANCES - 1) / 12 < @away).then { @wound.set 0 }
      end
      (@wound > 0).then { wound_a_guard }
    end

    # A GUARD WHO HAS NOT NOTICED YOU TAKES DOUBLE, which is the original quietly rewarding you
    # for getting the first one in. Then he either falls over or flinches and comes for you —
    # and a guard who was not already coming starts now, however little the shot took off him.
    def wound_a_guard
      hp = @pool.field_ref(:hp, @target)
      state = @pool.field_ref(:state, @target)
      ticks = @pool.field_ref(:ticks, @target)

      (@roused_of[state] == 0).then { @wound.set(@wound * 2) }
      hp.sub @wound

      (hp <= 0).then do
        state.set @fall1
        ticks.set(@ticks_of[@fall1])
        # A guard is worth a hundred, which is the original's own number. He also drops a clip
        # of ammunition where he falls, and that waits on there being things to pick up at all.
        @player[:score]&.add(Guards::POINTS)
      end.else do
        # Odd or even decides which of the two flinches he wears, so the same wound twice
        # running does not look like a repeat. Landing in one of them is also what rouses a
        # guard who had not noticed you: being shot at counts as being seen.
        state.set @hurt1
        ((hp % 2) == 0).then { state.set @hurt2 }
        ticks.set(@ticks_of[state])
      end
    end

    # Move him the way he is going. When he reaches the middle of the next cell, pick another.
    def walk(guard, pace, patrolling:)
      (guard.dir < Guards::NOWHERE).then do
        @pace.set pace
        guard.x.add(@pace * @step_x[guard.dir].to_f)
        guard.y.add(@pace * @step_y[guard.dir].to_f)
        guard.togo.sub @pace

        (guard.togo <= 0.0).then do
          # Put him exactly in the middle of the cell he has reached, so the rounding of a long
          # patrol never adds up into a drift.
          guard.x.set(guard.x.to_i.to_f + 0.5)
          guard.y.set(guard.y.to_i.to_f + 0.5)
          guard.togo.set 0.0
          patrolling ? choose_a_patrol_way(guard) : choose_a_chase_way(guard)
        end
      end
    end
  end
end
