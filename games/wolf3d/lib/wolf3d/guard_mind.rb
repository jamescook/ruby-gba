# frozen_string_literal: true

module Wolf3D
  # WHAT AN ENEMY DOES with each frame, which is a state machine and almost nothing else.
  #
  # The original's actor table is plain data — a picture, how long to stand in it, what to think
  # about while there, and which row comes next — and the whole of a guard's behaviour is that
  # table plus four things to think about. He looks for you while standing. He walks his beat
  # while patrolling, looking as he goes. He closes on you once he has seen you, and stops to
  # take a shot when he has a clear line. A dog, having no gun, hunts you down instead.
  #
  # ONE MIND FOR ALL FIVE KINDS, and that is not a simplification: a state number already says
  # which kind is in it (see Behaviour), so every number a kind decides — its picture, its speed,
  # how it attacks, how it falls, what it leaves — is a column of a table read by that one
  # number. Nothing here asks what it is looking at, and five kinds cost what one costs.
  #
  # WHAT LIVES HERE AND WHAT DOES NOT: this decides where a guard is and which state he is in.
  # Drawing him is the view's business, and it reads the same pool.
  class GuardMind
    # A guard walks from the middle of one cell to the middle of the next and never stops
    # between them, which is what makes "can he go that way" a question about a single cell.
    CELL = 1.0

    # What each of the thinking jobs is numbered, so one table can say which to do.
    NOTHING = Enemy::THINKING.fetch(nil)
    LOOK = Enemy::THINKING.fetch(:look)
    PATROL = Enemy::THINKING.fetch(:patrol)
    CHASE = Enemy::THINKING.fetch(:chase)
    HUNT = Enemy::THINKING.fetch(:hunt)

    # ...and the two ways of attacking, the same way.
    WITH_A_GUN = Enemy::ATTACKS.fetch(:gun)
    WITH_TEETH = Enemy::ATTACKS.fetch(:teeth)

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
                   behaviour: nil, blocked: nil, dying: nil, pickups: nil, sounds: nil,
                   rooms: nil, floors: nil, map_base: nil, difficulty: nil)
      @b = build
      # THE STATE TABLE OF EVERY KIND THIS CARTRIDGE HOLDS. A build that says nothing gets the
      # guard's alone, which is what every test of the guard himself wants.
      @behaviour = behaviour || Behaviour.for([:guard])
      @difficulty = difficulty # how tough the game is set, or nil where nothing can change it
      @dying = dying      # what to tell when a shot takes the last of the health, or nil
      @pickups = pickups  # what to tell when a guard falls, so he can leave a clip behind
      @sounds = sounds    # the recorded sounds, or nil on a build with none
      @guards = guards
      @pool = pool
      @level = level
      @floors = floors    # every floor the cartridge holds, or nil for a game with one
      @rooms = rooms      # which rooms are open to the player's, or nil where nothing shuts off
      # WHERE THIS FLOOR'S SLICE OF EVERY TABLE BEGINS. The tables hold all the floors end to end,
      # so every read of one adds this — the same number the view adds. Nought for a cartridge
      # with a single floor, which is every test that builds one directly.
      @base = map_base || 0
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

    # ...and which kinds this cartridge holds, for anything that has to ship their pictures.
    attr_reader :behaviour

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
      states = @behaviour.states
      rows = (0...states.length)

      # THE STATE TABLE, as tables the game reads by state number. Kept apart rather than as one
      # row per state because each is read on its own.
      #
      # A picture takes a HALF rather than a byte: a cartridge with all five kinds on it ships
      # nearly three hundred pictures of them, and the scenery stands in the same row.
      @picture_of = b.table :guard_picture,
                            rows.map { |n| @things.position_of(@behaviour.picture_of(n)) }, width: :half
      @turns_of = b.table :guard_turns, states.map { |s| s.turns ? 1 : 0 }, width: :byte
      @ticks_of = b.table :guard_ticks, states.map(&:ticks), width: :byte
      @becomes_of = b.table :guard_becomes, rows.map { |n| @behaviour.becomes_from(n) }, width: :byte
      @think_of = b.table :guard_think, states.map { |s| Enemy::THINKING.fetch(s.think) }, width: :byte
      @attacks_of = b.table :guard_attacks, states.map { |s| Enemy::ATTACKS.fetch(s.fires) },
                            width: :byte
      @roused_of = b.table :guard_roused, states.map { |s| Enemy.roused?(s) ? 1 : 0 }, width: :byte

      # WHAT THE THING IN THIS STATE DOES NEXT, which is where the five kinds really live. Each
      # of these used to be one number, because there was one kind and one answer; now the state
      # a thing is in says which kind it is, so the answer is a column read by the number the
      # mind is already holding. Nothing branches on a kind and nothing remembers one.
      @chase_of = b.table :guard_chase, rows.map { |n| @behaviour.chase_from(n) }, width: :byte
      @attack_of = b.table :guard_attack, rows.map { |n| @behaviour.attack_from(n) }, width: :byte
      @hurt_of = b.table :guard_hurt, rows.map { |n| @behaviour.flinch_from(n) }, width: :byte
      @hurt2_of = b.table :guard_hurt2,
                          rows.map { |n| @behaviour.flinch_from(n, second: true) }, width: :byte
      @fall_of = b.table :guard_fall, rows.map { |n| @behaviour.fall_from(n) }, width: :byte
      # ...and how far it walks each think, which is how an officer runs you down and a dog is
      # quicker than either. Written as a fraction, so it ships as a word.
      @step_of = b.table :guard_step, rows.map { |n| @behaviour.step_from(n) }
      # ...and what killing it is worth, and what it leaves lying where it fell.
      @points_of = b.table :guard_points, rows.map { |n| @behaviour.points_from(n) }, width: :half
      @leaves_of = b.table :guard_leaves, rows.map { |n| @behaviour.leaves_from(n) }, width: :byte

      # WHICH WAY EACH DIRECTION GOES, one cell at a time. Nine entries: eight ways round and
      # then nowhere, which is where a guard hemmed in on every side ends up.
      steps = Guards::WAYS + [[0, 0]]
      @step_x = b.table :guard_step_x, steps.map(&:first)
      @step_y = b.table :guard_step_y, steps.map(&:last)

      # A TURNING POINT UNDER A PATROLLING GUARD sends him a new way. Nowhere means carry on.
      # Every floor's, end to end like the map, and read with this floor's own slice added.
      @arrow = b.table :guard_arrow, every_floors_arrows, width: :byte

      reach = [@level.width, @level.height].max
      @shot = b.table :guard_shot, (0..reach).map { |away| shot_chance(away) }

      # HOW NEAR A DOG JUMPS FROM: about a cell, plus the ground it covers in the think it is
      # deciding on — which is the original's own test, made against the step it is about to take
      # rather than against where it already stands.
      @jump_from = Guards::JUMP_FROM + Enemy[:dog].speed(chasing: true)
      @width = @level.width
      @reach = reach

      declare_the_scratch
      # The two pieces asked for from many places, each emitted once. See where each is defined
      # for what that is worth and why it can be done at all.
      declare_the_line_walk
      declare_the_walkable_test

      # WHOSE TURN IT IS. Flipped each time this routine runs, and a guard thinks on the turns
      # that match his — so half of them think each time and a guard is thought about every
      # other one. See Enemy::TICKS_PER_THINK for why that is often enough.
      #
      # FLIPPED HERE rather than on its own beat, so that whatever paces the world paces this
      # too. A turn flipped once a FRAME while the world moved once a PASS would flip twice
      # between two moves on a game taking two frames a pass — back to where it started, so the
      # same half would think every time and the other half never.
      @turn = b.var :_gturn, 0
      b.func(:guard_thinking, fast: false) do
        @turn.set((@turn + 1) % 2)
        # HALF OF THEM ON ANY ONE FRAME, which is what @turn is for — said here because nothing at
        # build time can read it off the test, and unsaid the report counts every guard thinking
        # on every frame.
        @pool.each { |guard| (guard.turn == @turn).then(estimate: { usually: 1, in: 2 }) { think(guard) } }
      end
    end

    # THE TURNING POINTS OF EVERY FLOOR, in the order the cartridge plays them, so that this table
    # lines up cell for cell with the map. A cartridge with one floor is that floor's own.
    def every_floors_arrows
      floors = @floors&.to_a || [nil]
      floors.flat_map do |floor|
        level = floor&.level || @level
        guards = floor&.guards || @guards
        level.each_cell.map { |x, y| guards&.arrow_at(x, y) || Guards::NOWHERE }
      end
    end

    # At nothing at all he cannot miss the chance; beyond that it falls away with distance.
    def shot_chance(away)
      return CHANCES if away.zero?

      [(16 * Enemy::TICKS_PER_THINK / Enemy::SCALE) / away, CHANCES].min
    end

    def declare_the_scratch
      b = @b
      @state, @dir, @job, @try, @slot, @cellx, @celly, @clear, @done, @ahead, @way, @picked,
        @tx, @ty, @away, @target, @odds, @wound, @spot, @blow, @left =
        %i[gstate gdir gjob gtry gslot gcellx gcelly gclear gdone gahead gway gpicked
           gtx gty gaway gtarget godds gwound gspot gblow gleft].map { |name| b.var(:"_#{name}", 0) }
      @dx, @dy, @absx, @absy, @stepx, @stepy, @far, @atx, @aty, @pace, @fwd, @sideways, @nearest,
        @fromx, @fromy =
        %i[gdx gdy gabsx gabsy gstepx gstepy gfar gatx gaty gpace gfwd gsideways gnearest
           gfromx gfromy].map { |name| b.var(:"_#{name}", 0.0) }
    end

    # ONE GUARD, ONE FRAME. Count his state down, move him on when it runs out, then let him
    # think — which is the order the original does it in, and it matters: a state that has just
    # begun thinks on the frame it begins.
    def think(guard)
      return thinks_it_through(guard) if @rooms.nil?

      # ...UNLESS HE HAS NO REASON TO, which is the original's own first line here (wl_play.cpp,
      # DoActor): a guard thinks if he has ever been seen, or if the room he is in is open to the
      # room the player is in. Everyone else stands exactly as he was.
      #
      # Nearly all of a think is the line of sight he walks to you, and it is walked whether he is
      # next door or on the far side of the floor. The second floor of the first episode has
      # twenty-nine guards and, wherever you stand on it, about one and a half of them are in the
      # room with you.
      ((guard.awake == 1) | @rooms.open_to_the_player?(guard.x, guard.y))
        .then { thinks_it_through(guard) }
    end

    def thinks_it_through(guard)
      @state.set guard.state
      step_the_state(guard)

      # EXACTLY ONE OF THESE RUNS. They are the arms of one choice — a guard is standing, or
      # walking his beat, or coming after you, or (a dog) hunting you down — and nothing at build
      # time can see that, so unsaid the report counts all of them on every guard on every frame.
      # It is not a small lie: nearly all of a job is the line of sight it walks, so counting
      # three jobs where one runs put `guard_thinking` at three times its real cost and sent a
      # whole afternoon after the wrong thing. One in however many there are, and the worst frame
      # is unchanged either way.
      #
      # HALF AGAIN ON TOP OF THAT: a guard thinks on alternate frames (see @turn), so the body
      # this sits in runs for half the pool on any one frame. That one is said where the loop is.
      #
      # A CARTRIDGE WITH NO DOGS HAS NO HUNTING ARM, so it pays nothing for one.
      arms = @behaviour.jobs
      @job.set(@think_of[guard.state])
      (@job == LOOK).then(estimate: { usually: 1, in: arms }) { look(guard) }
      (@job == PATROL).then(estimate: { usually: 1, in: arms }) { patrol(guard) }
      (@job == CHASE).then(estimate: { usually: 1, in: arms }) { chase(guard) } if hunts?(:chase)
      (@job == HUNT).then(estimate: { usually: 1, in: arms }) { hunt(guard) } if hunts?(:hunt)
    end

    # Does anything on this cartridge think this way at all?
    def hunts?(job) = @behaviour.any?(job)

    # A state with no length never runs down — that is how standing goes on forever. One step a
    # think is enough for every other: the shortest state in the table is nine of these units
    # long and a think is worth seven, so a think can never step clean over one.
    def step_the_state(guard)
      (@ticks_of[@state] > 0).then do
        guard.ticks.sub Enemy::TICKS_PER_THINK
        (guard.ticks <= 0).then do
          # The shot leaves as he LEAVES the state he aimed in, which is where the original
          # hangs it: aiming, firing and lowering the arm are three pictures and the bullet
          # belongs to the join between the second and the third.
          attack_the_player(guard)
          guard.state.set(@becomes_of[@state])
          guard.ticks.add(@ticks_of[guard.state])
        end
      end
    end

    # A GUN OR A SET OF TEETH, and which is a column of the state table like everything else. A
    # cartridge with no dogs on it has only the one answer, so it asks only the one question.
    def attack_the_player(guard)
      unless @behaviour.any?(:teeth)
        return (@attacks_of[@state] == WITH_A_GUN).then { fire_at_the_player(guard) }
      end

      @blow.set(@attacks_of[@state])
      (@blow == WITH_A_GUN).then { fire_at_the_player(guard) }
      (@blow == WITH_TEETH).then { bite_the_player(guard) }
    end

    # A DOG HAS NO GUN, so the only way it can hurt you is to reach you — and its jaws close at
    # the end of the second picture of the jump, whether or not anything is in the way. There is
    # no line of sight to walk and no distance to fall off with: it is near enough or it is not,
    # and what it takes is a byte of randomness shifted down four. Which is why a dog at your
    # feet is worse than a guard across the room, and why backing away from one works.
    def bite_the_player(guard)
      @dx.set(@player[:x] - guard.x)
      @dx.abs
      @dy.set(@player[:y] - guard.y)
      @dy.abs
      ((@dx <= Guards::BITE_REACH) & (@dy <= Guards::BITE_REACH)).then do
        (@b.rand(0..CHANCES - 1) < Guards::BITE_CHANCE).then do
          @wound.set(@b.rand(0..CHANCES - 1) / Guards::BITE_SHIFT)
          take_it_out_of_the_player(guard)
        end
      end
    end

    # HIS SHOT IS NOT AIMED. It is a chance against distance, and the far half of that chance
    # depends on whether you can SEE him — a guard you are looking at misses more, because you
    # could be dodging. That is the game quietly being fair, and it is in the original's
    # numbers rather than anywhere else.
    #
    # What it does when it lands falls off with distance too, so a guard across the room does
    # almost nothing and one in your face does real harm.
    def fire_at_the_player(guard)
      # HEARD WHETHER OR NOT IT LANDS, and before either question is asked. A guard fires; the
      # chance and the line of sight decide what it does to you, not whether he pulled.
      @sounds&.guard_fires
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

    # WHAT A SHOT THAT LANDS TAKES OFF YOU, by distance: a byte of randomness shifted down twice
    # inside two cells, three times inside four, four times beyond.
    def wound_the_player(guard)
      @wound.set(@b.rand(0..CHANCES - 1) / 4)
      (@away >= 2).then { @wound.set(@b.rand(0..CHANCES - 1) / 8) }
      (@away >= 4).then { @wound.set(@b.rand(0..CHANCES - 1) / 16) }
      take_it_out_of_the_player(guard)
    end

    # THE BLOW THAT TAKES THE LAST OF THE HEALTH IS THE ONE THE DEATH NEEDS TO KNOW ABOUT, and
    # this is the only place that knows who struck it. The view turns to face him, so who it was
    # has to be caught here rather than worked out afterwards from a body on the floor.
    #
    # A bullet and a set of teeth both come through here, which is where the original puts the
    # setting's own softening too — at the health rather than at the shot, so every wound goes
    # through it.
    def take_it_out_of_the_player(guard)
      gently
      @player[:health].sub @wound
      (@player[:health] <= 0).then do
        @player[:health].set 0
        @dying&.struck_by(guard)
      end
    end

    # THE EASIEST SETTING TAKES A QUARTER OF WHAT THE BLOW WOULD TAKE, and it is nearly the only
    # thing about an enemy that how tough you said you were changes. How well it shoots and how
    # far it sees are the same on all four; how much killing it takes is the same too, except for
    # a mutant, whose four differ.
    #
    # IT IS THE EASIEST SETTING ALONE. The second one hurts you exactly as much as the hardest
    # does, which is worth saying out loud because the two easiest agree about the other thing
    # the setting decides: neither of them brings in a single extra guard.
    def gently
      return if @difficulty.nil?

      (@difficulty == Guards::GENTLE).then { @wound.set(@wound / Guards::GENTLE_PART) }
    end

    # --- looking for you -------------------------------------------------------------

    # Looking has two halves. He has to be able to SEE you, and then he has to REACT — a moment
    # of up to about a second before he turns and comes. That delay is why the game feels fair:
    # you get a beat between being seen and being come after.
    def look(guard)
      (guard.wait > 0).then do
        guard.wait.sub Enemy::TICKS_PER_THINK
        (guard.wait <= 0).then do
          guard.wait.set 0
          first_sighting(guard)
        end
      end.else do
        heard_or_saw(guard)
        (@clear == 1).then { guard.wait.set(@b.rand(1..Guards::REACTION)) }
      end
    end

    # A NOISE COUNTS AS A SIGHTING, which is the original's whole hearing model in one line:
    # `if (!madenoise && !CheckSight(ob)) return false`. It does not tell him where you are and
    # it does not make him chase — it gets him past the "can I see you" gate, and he still takes
    # his moment to react. Nothing about it can walk a guard at you through a wall.
    #
    # AND IT DOES NOT CARRY THROUGH ONE. A noise reaches a guard whose room is open to the room
    # you are standing in, and no further — the same rooms-joined-by-open-doors question the
    # whole think is gated on, asked again HERE because a guard who has been seen once thinks
    # wherever he stands. Without it, one shot would be heard through a wall for the rest of the
    # floor by everybody who had ever laid eyes on you. The original asks it twice for the same
    # reason (DoActor, then SightPlayer).
    #
    # A GUARD LYING IN WAIT HEARS NOTHING, which is what the ambush tile is for: he must SEE you.
    # That is the man behind the door who is meant to catch you walking past, and a gunshot two
    # rooms away giving him away would be the end of him. (The original drops the flag the moment
    # he does see you. Nothing here ever puts a guard back to standing, so it would never be
    # asked again.)
    # Written as nested tests rather than one joined condition, which is what this codebase does
    # wherever a side costs something: asking which room a guard is in is a table read and a list
    # read, and on the overwhelming majority of passes there is no noise to ask about.
    def heard_or_saw(guard)
      return can_see(guard) if @player[:noise].nil?

      @clear.set 0
      ((@player[:noise] > 0) & (guard.ambush == 0)).then { a_noise_reaches(guard) }
      # ...and if it did not reach him, he is back to looking, which is what he was doing anyway.
      (@clear == 0).then { can_see(guard) }
    end

    # A floor whose rooms are never shut off from each other — one room, or no doors to join two
    # with — has nothing to ask, and everyone on it hears everything.
    def a_noise_reaches(guard)
      return @clear.set(1) if @rooms.nil?

      @rooms.open_to_the_player?(guard.x, guard.y).then { @clear.set 1 }
    end

    # He has seen you: he breaks into a chase, and from here he moves several times as fast —
    # three for a guard, four for an SS, five for an officer, which is a table read rather than a
    # number because the state he lands in is the one that says how fast his kind runs.
    def first_sighting(guard)
      @blow.set(@chase_of[guard.state])
      guard.state.set @blow
      guard.ticks.set(@ticks_of[@blow])
      guard.togo.set 0.0
      # "Halt!" — which is the one sound in this game that tells you something you could not
      # otherwise know: that you have been seen, and by how many.
      @sounds&.notices_you
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
          @ahead.set(@world[@base + (@celly * @width) + @cellx])
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
        walk(guard, patrolling: true)
      end
    end

    # A turning point under his feet sends him a new way; without one he carries straight on.
    # Either way he only sets off if he can actually get there.
    def choose_a_patrol_way(guard)
      @way.set(@arrow[@base + (guard.y.to_i * @width) + guard.x.to_i])
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
        walk(guard, patrolling: false)
      end
    end

    # A DOG CLOSES INSTEAD OF STOPPING FOR A SHOT, and that is the whole difference between
    # hunting and chasing. It picks its way toward you exactly as a guard does; where a guard
    # asks whether he has a clear line, a dog asks whether it is near enough to jump — and it
    # asks about the step it is ABOUT to take, so it leaves the ground a stride early.
    def hunt(guard)
      near_enough_to_jump(guard)
      (@think_of[guard.state] == HUNT).then do
        (guard.togo <= 0.0).then { choose_a_chase_way(guard) }
        walk(guard, patrolling: false)
      end
    end

    # Near enough on EACH axis on its own rather than as a distance, which is the original's own
    # test and is why a dog catches you round a corner it could not see you through.
    def near_enough_to_jump(guard)
      @dx.set(@player[:x] - guard.x)
      @dx.abs
      @dy.set(@player[:y] - guard.y)
      @dy.abs
      ((@dx <= @jump_from) & (@dy <= @jump_from)).then { start_attacking(guard) }
    end

    def take_a_shot(guard)
      @dx.set(@player[:x] - guard.x)
      @dy.set(@player[:y] - guard.y)
      line_of_sight(guard)
      (@clear == 1).then do
        how_far_away(guard)
        (@b.rand(0..CHANCES - 1) < @shot[@away]).then { start_attacking(guard) }
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

    # He raises his gun, or the dog gathers itself — which of the two is a column of the state
    # table, so this is one piece of code and not two.
    def start_attacking(guard)
      @blow.set(@attack_of[guard.state])
      guard.state.set @blow
      guard.ticks.set(@ticks_of[@blow])
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
      @spot.set(@base + (@celly * @width) + @cellx)
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
    #
    # +with_knife+ is true while the knife is the thing in your hands, or nil on a game with one
    # weapon — and then none of the knife's own arm is emitted. What it changes is the DAMAGE
    # and the REACH, never the search: a knife goes for the same man down the same line, and the
    # only question it asks differently is whether he is near enough to touch.
    def shoot(with_knife: nil)
      @target.set NOBODY
      @nearest.set FAR_AWAY

      @pool.each { |guard| consider_as_a_target(guard) }

      (@target != NOBODY).then { hit_the_target(with_knife) }
    end

    private

    # The furthest anything can be, so the first candidate always beats it.
    FAR_AWAY = 1000.0

    # Is this one in the sights, in the open, and nearer than the best so far?
    def consider_as_a_target(guard)
      (guard.hp > 0).then do
        x = guard.x
        y = guard.y
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
            @target.set guard.index
          end
        end
      end
    end

    # HOW BADLY THE MAN IN THE SIGHTS IS HURT. How far away he is decides it, in whole cells,
    # and the weapon does not — every gun in this game does the same damage, so a chain gun is
    # not a harder-hitting pistol, it is more pistol shots.
    def hit_the_target(with_knife)
      x = @pool.field_ref(:x, @target)
      y = @pool.field_ref(:y, @target)
      @cellx.set((@player[:x].to_i - x.to_i))
      (@cellx < 0).then { @cellx.set(0 - @cellx) }
      @celly.set((@player[:y].to_i - y.to_i))
      (@celly < 0).then { @celly.set(0 - @celly) }
      @away.set @cellx
      (@celly > @away).then { @away.set @celly }

      if with_knife
        with_knife.then { what_a_knife_does }.else { what_a_gun_does }
      else
        what_a_gun_does
      end
      (@wound > 0).then { wound_a_guard }
    end

    # ...AND WHAT A GUN DOES, by distance, where the third case can miss outright: past four
    # cells a roll has to beat the distance or the shot goes wide, which is why a pistol across
    # a room is a waste of a bullet and why backing away from a fight works.
    def what_a_gun_does
      @wound.set(@b.rand(0..CHANCES - 1) / 4)
      (@away >= 2).then { @wound.set(@b.rand(0..CHANCES - 1) / 6) }
      (@away >= 4).then do
        # Far enough away to miss altogether.
        (@b.rand(0..CHANCES - 1) / 12 < @away).then { @wound.set 0 }
      end
    end

    # ...AND WHAT A KNIFE DOES, which is not a gun at zero range. It takes about a quarter of
    # what a close shot takes, and instead of falling off with distance it simply stops: inside
    # a cell and a half it cuts, outside it the swing meets nothing at all.
    #
    # The distance it asks about is the one the search already worked out — how far in FRONT of
    # the eye the man is, which is what the original measures a knife by too.
    def what_a_knife_does
      @wound.set 0
      (@nearest < Weapons::KNIFE_REACH).then { @wound.set(@b.rand(0..CHANCES - 1) / 16) }
    end

    # A GUARD WHO HAS NOT NOTICED YOU TAKES DOUBLE, which is the original quietly rewarding you
    # for getting the first one in. Then he either falls over or flinches and comes for you —
    # and a guard who was not already coming starts now, however little the shot took off him.
    def wound_a_guard
      hp = @pool.field_ref(:hp, @target)
      state = @pool.field_ref(:state, @target)
      ticks = @pool.field_ref(:ticks, @target)

      # A MAN WHO IS HIT CRIES OUT, and that is a noise like a gunshot — the original's own flag
      # is commented "true when shooting or screaming" and it is set here, where the damage is
      # done, rather than with the weapon. It is what makes a knife that LANDS bring the room
      # while one that misses does not.
      @player[:noise]&.set(FirstPerson::HEARD_FOR)
      (@roused_of[state] == 0).then { @wound.set(@wound * 2) }
      hp.sub @wound

      (hp <= 0).then do
        # WHAT KILLING HIM IS WORTH AND WHAT HE WAS CARRYING, both read BEFORE he starts falling
        # over — a state number is what says which kind he is, and in a moment it will say he is
        # a body instead.
        @player[:score]&.add(@points_of[state])
        @left.set(@leaves_of[state])
        @blow.set(@fall_of[state])
        state.set @blow
        ticks.set(@ticks_of[@blow])
        # ...and one off the floor's tally, which is a different thing from the score: the score
        # is kept across floors and this is how much of THIS floor has been cleared.
        @player[:kills]&.add(1)
        # ...and he leaves what he was carrying in the cell he fell in, which is the loop the
        # whole game runs on: shoot a guard, take what he was carrying, shoot the next one. Half
        # a clip from most of them, a machine gun from an SS, and nothing at all from a dog.
        @pickups&.a_guard_fell(@target, leaving: @left)
        # ...and one of his eight screams, picked as the game runs so a firefight does not
        # sound like a loop.
        @sounds&.a_guard_dies
      end.else do
        # Odd or even decides which of the two flinches he wears, so the same wound twice
        # running does not look like a repeat. Landing in one of them is also what rouses a
        # guard who had not noticed you: being shot at counts as being seen.
        @blow.set(@hurt_of[state])
        ((hp % 2) == 0).then { @blow.set(@hurt2_of[state]) }
        state.set @blow
        ticks.set(@ticks_of[@blow])
      end
    end

    # Move him the way he is going. When he reaches the middle of the next cell, pick another.
    #
    # HOW FAR HE GOES IS A COLUMN OF THE STATE TABLE, because it is the one thing about walking
    # that differs between the kinds and between the beat and the chase — and the state he is in
    # already says both. So an officer running you down and a dog trotting past cost the same
    # here as a guard did.
    def walk(guard, patrolling:)
      (guard.dir < Guards::NOWHERE).then do
        @pace.set(@step_of[guard.state])
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
