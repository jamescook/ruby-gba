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

    def initialize(build:, guards:, pool:, level:, world:, player:, door_open:, walls:)
      @b = build
      @guards = guards
      @pool = pool
      @level = level
      @world = world      # the flat map table the ray walk reads
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
      @picture_of = b.table :guard_picture, states.map { |s| Guards.picture_position(s) }, width: :byte
      @turns_of = b.table :guard_turns, states.map { |s| s.turns ? 1 : 0 }, width: :byte
      @ticks_of = b.table :guard_ticks, states.map(&:ticks), width: :byte
      @becomes_of = b.table :guard_becomes, states.map { |s| Guards.state_number(s.becomes) }, width: :byte
      @think_of = b.table :guard_think, states.map { |s| Guards::THINKING.fetch(s.think) }, width: :byte

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
      @patrol_step = Guards.speed
      @chase_step = Guards.speed(chasing: true)
      @width = @level.width
      @reach = reach

      declare_the_scratch
      pool = @pool
      b.func(:guard_thinking, fast: false) { pool.each { |guard| think(guard) } }
    end

    # At nothing at all he cannot miss the chance; beyond that it falls away with distance.
    def shot_chance(away)
      return CHANCES if away.zero?

      [(16 * Guards::TICKS_PER_PASS) / away, CHANCES].min
    end

    def declare_the_scratch
      b = @b
      @state, @dir, @job, @try, @slot, @cellx, @celly, @clear, @done, @ahead, @way, @picked,
        @tx, @ty, @away =
        %i[gstate gdir gjob gtry gslot gcellx gcelly gclear gdone gahead gway gpicked
           gtx gty gaway].map { |name| b.var(:"_#{name}", 0) }
      @dx, @dy, @absx, @absy, @stepx, @stepy, @far, @atx, @aty, @pace =
        %i[gdx gdy gabsx gabsy gstepx gstepy gfar gatx gaty gpace]
        .map { |name| b.var(:"_#{name}", 0.0) }
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
    # pass is enough for every other: the shortest state in the table is three units long and a
    # pass is worth two, so a pass can never step clean over one.
    def step_the_state(guard)
      (@ticks_of[@state] > 0).then do
        guard.ticks.sub Guards::TICKS_PER_PASS
        (guard.ticks <= 0).then do
          guard.state.set(@becomes_of[@state])
          guard.ticks.add(@ticks_of[guard.state])
        end
      end
    end

    # --- looking for you -------------------------------------------------------------

    # Looking has two halves. He has to be able to SEE you, and then he has to REACT — a moment
    # of up to about a second before he turns and comes. That delay is why the game feels fair:
    # you get a beat between being seen and being come after.
    def look(guard)
      (guard.wait > 0).then do
        guard.wait.sub Guards::TICKS_PER_PASS
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
    def line_of_sight(guard)
      b = @b
      aim_at_the_player(guard)
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
    def aim_at_the_player(guard)
      @absx.set @dx
      @absx.abs
      @absy.set @dy
      @absy.abs
      @far.set @absx
      (@absy > @far).then { @far.set @absy }
      (@far < 1.0).then { @far.set 1.0 }

      @stepx.set(@dx / @far)
      @stepy.set(@dy / @far)
      @atx.set guard.x
      @aty.set guard.y
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

    # A cell a guard can walk into: open floor, or a doorway whose panel has slid out of the
    # way. The same question the player's feet ask, asked of a guard.
    def free_to_walk
      @ahead.set(@world[(@celly * @width) + @cellx])
      @clear.set 0
      (@ahead == 0).then { @clear.set 1 }
      (@ahead >= @walls[:door]).then do
        (@ahead < @walls[:push]).then do
          @slot.set(@ahead - @walls[:door])
          (@open[@slot] > FirstPerson::DOOR_WALKABLE).then { @clear.set 1 }
        end
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
