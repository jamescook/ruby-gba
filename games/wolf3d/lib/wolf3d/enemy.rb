# frozen_string_literal: true

module Wolf3D
  # WHAT ONE KIND OF ENEMY IS: the guard, the officer, the SS, the dog, the mutant, and the two
  # bosses who fit the same shape.
  #
  # THEY DIFFER IN NUMBERS AND IN NOTHING ELSE, which is the whole design of this file and of
  # the original's. An enemy is a place, a facing, eight poses, a state table and a mind, and
  # every one of them is that same thing with different numbers in it: how much killing it
  # takes, how fast it moves, how many pictures it fires over, what it leaves when it falls. So
  # there is no dog class and no SS class and nothing to inherit — there is one row of numbers
  # per kind, and one mind that reads them.
  #
  # THE STATE TABLE IS THE BEHAVIOUR rather than a description of it. Each row is a picture, how
  # long to stand in it, what to think about while there, and which row comes next. Read out of
  # the original (wl_act2.cpp): guessing these gives something that merely resembles Wolfenstein.
  #
  # +codes+ is how many plane-1 codes the kind's block holds and +blocks+ how many times that
  # block repeats for a harder game. The five rank-and-file kinds are 8 and 3 — four facings
  # standing, four patrolling, repeated for the ones a harder game adds. A boss is 1 and 1: he
  # is one code, he stands on every setting, and he has no facing to pick because his pictures
  # do not turn.
  class Enemy < Data.define(:name, :standing, :harder, :first_picture, :hit_points, :points,
                            :patrol_speed, :chase_times, :leaves, :states, :stands,
                            :codes, :blocks)
    # How many pictures of one thing there are, one for each way you can be standing from it.
    POSES = 8

    # The original's unit of distance: so many of these to a cell.
    CELL = 1 << 16

    # HOW LONG A STATE LASTS is counted in the original's own units — seventieths of a second —
    # and the numbers in the tables below are its numbers, unchanged.
    #
    # THE COUNTER RUNS IN THIRDS OF ONE, so that a rate which is not a whole number of the
    # original's units can still be carried by a counter that steps in whole numbers. An enemy
    # moves once every two passes and the rate wanted is a little over one unit a pass, which is
    # not a whole number either way round; in thirds it is.
    SCALE = 3

    # HOW FAST AN ENEMY'S CLOCK RUNS, and the unit it is measured in is the thing to get right.
    #
    # MEASURE IT PER PASS, NOT PER SECOND. Everything in this game moves once per pass of the
    # game loop: the player walks WALK of a cell, doors slide DOOR_STEP, push walls count down
    # one. That is what FirstPerson::PACING means, and it is why a heavy frame slows the whole
    # world down together instead of tearing it apart. An enemy is in that world, so its clock is
    # per pass too — a think every other pass, this many thirds each time.
    #
    # SECONDS ARE NOT A UNIT THIS GAME HAS. On a game that keeps up a pass is a frame and the
    # two agree, so it is easy to derive this number from "sixty passes a second" and not notice
    # the assumption. On a game that does NOT keep up the seconds answer is wrong, and it is
    # wrong in a way that is invisible in the code and shows up in play as guards moving at a
    # different speed from the world they stand in. Derive it from a pass.
    #
    # WHAT THE RIGHT ANSWER IS, then, is whatever puts an enemy on the same footing as the
    # player, and the player says what that is. He walks 0.07 of a cell a pass where the original
    # walks 0.0801 of one a unit, so a pass is worth 0.87 of a unit; he turns 4.2 degrees a pass
    # where the original turns 3.5 a unit running, so a pass is worth 1.21. A pass of this game
    # is worth about ONE of the original's units, and a think — every other pass — about two.
    # Seven thirds is 2.33 a think, 1.17 a pass, which sits inside that band.
    # TestGuards holds it there; see the test for what going outside it costs.
    #
    # WHY EVERY OTHER PASS. Thinking is the most expensive thing an enemy does and half of it is
    # asking a question whose answer cannot change in one pass — can it see you, is anything in
    # the way. Measured, a guard costs about eleven scanlines of a frame, and a real floor has
    # ten of them; halving that is worth more than anything else available here, and it costs a
    # reaction that is on average half a pass later.
    #
    # They are split between the two passes rather than all thinking on the same one, so the cost
    # is the same every pass instead of nothing then double.
    #
    # It never steps over a state: the shortest in any of the tables is three of the original's
    # units, which is nine of ours, and a think advances seven.
    TICKS_PER_THINK = 7

    # +fires+ marks a state whose END is an attack — a shot, or a dog's jaws: the original hangs
    # its actions on leaving a state rather than on being in one, so a guard aims, fires, and
    # lowers his arm across three pictures and the bullet leaves on the middle one.
    State = Data.define(:name, :picture, :turns, :ticks, :think, :becomes, :fires)

    # +ticks+ is written in the ORIGINAL'S units, so the tables below stay its tables and can be
    # read against them line for line. It is kept in thirds of one — see SCALE — and the
    # conversion happens here, once, rather than at every number.
    def self.state(name, picture, ticks, think, becomes, turns: true, fires: nil)
      State.new(name: name, picture: picture, ticks: ticks * SCALE, think: think,
                becomes: becomes, turns: turns, fires: fires)
    end

    # WHERE EACH OF A KIND'S PICTURES SITS in its own run of them, counting from the first.
    # Eight of it standing still, then four sets of eight walking, then the ones that do not
    # turn: hurt, dying, dead, and attacking. The order is the file's rather than one anyone
    # would choose — the two flinches sit either side of the pictures it falls over in.
    Poses = Data.define(:still, :walk, :hurt, :fall, :dead, :attack)

    # A MAN: eight standing, thirty-two walking, then the six that do not turn and his gun. The
    # guard and the SS are laid out exactly this way.
    MAN = Poses.new(still: 0, walk: [8, 16, 24, 32], hurt: [40, 44],
                    fall: [41, 42, 43], dead: 45, attack: [46, 47, 48])

    # ...and one who takes an extra picture to fall over, which pushes everything after it up.
    LONGER_FALL = [41, 42, 43, 45].freeze
    OFFICER_POSES = Poses.new(still: 0, walk: MAN.walk, hurt: MAN.hurt,
                              fall: LONGER_FALL, dead: 46, attack: [47, 48, 49])
    MUTANT_POSES = Poses.new(still: 0, walk: MAN.walk, hurt: MAN.hurt,
                             fall: LONGER_FALL, dead: 46, attack: [47, 48, 49, 50])
    # A dog has no standing pictures at all, and no flinch — see DOG_STATES.
    DOG_POSES = Poses.new(still: nil, walk: [0, 8, 16, 24], hurt: [],
                          fall: [32, 33, 34], dead: 35, attack: [36, 37, 38])

    # A BOSS IS ELEVEN PICTURES AND NOT SEVENTY, because none of his turn: the original marks
    # every one of his states "does not rotate", so he faces the player whichever way he is
    # walking and there is one picture per state rather than eight. Four walking, three firing,
    # the body, and three of falling over — in the file's own order, which puts the body BEFORE
    # the falling rather than after it.
    #
    # He has no standing picture of his own either: he stands in the first of his walking ones.
    BOSS_POSES = Poses.new(still: 0, walk: [0, 1, 2, 3], hurt: [],
                           fall: [8, 9, 10], dead: 7, attack: [4, 5, 6])

    # --- what every kind does the same way ------------------------------------------------

    # THE BEAT AND THE CHASE, which every kind walks the same way: four pictures at twenty and
    # fifteen with a five-unit step between the pairs, then the same four at ten and eight with
    # three-unit steps — which is why anything that has seen you visibly hurries. Only the
    # pictures differ, and what it is thinking about while it closes: a dog has no gun, so it is
    # hunting you down rather than looking for a shot.
    def self.walking(poses, closing: :chase)
      w = poses.walk
      [
        state(:path1,   w[0], 20, :patrol, :path1s),
        state(:path1s,  w[0], 5,  nil,     :path2),
        state(:path2,   w[1], 15, :patrol, :path3),
        state(:path3,   w[2], 20, :patrol, :path3s),
        state(:path3s,  w[2], 5,  nil,     :path4),
        state(:path4,   w[3], 15, :patrol, :path1),

        state(:chase1,  w[0], 10, closing, :chase1s),
        state(:chase1s, w[0], 3,  nil,     :chase2),
        state(:chase2,  w[1], 8,  closing, :chase3),
        state(:chase3,  w[2], 10, closing, :chase3s),
        state(:chase3s, w[2], 3,  nil,     :chase4),
        state(:chase4,  w[3], 8,  closing, :chase1)
      ]
    end

    # Standing lasts forever — a length of nought never runs down — and only looks. A dog is the
    # one kind with no such state.
    def self.standing_still(poses, turns: true)
      [state(:stand, poses.still, 0, :look, :stand, turns: turns)]
    end

    # THE CHASE WITHOUT THE BEAT, which is what a boss walks. He is put down where he is and
    # stays there until he sees you, so the four patrolling states have nothing to run them and
    # the original gives him none at all. The chase itself is the same six pictures at the same
    # lengths every other kind chases at; only the turning differs, and his do not.
    def self.chasing_only(poses)
      walking(poses).reject { |s| s.name.to_s.start_with?("path") }
                    .map { |s| State.new(**s.to_h, turns: false) }
    end

    # Hurt but not finished: it flinches and comes straight back at you. Which of the two
    # pictures it wears is whether the hits it has left are an odd number, which is the
    # original's way of making the same wound look different twice running.
    def self.flinching(poses)
      poses.hurt.each_with_index.map do |picture, n|
        state(:"hurt#{n + 1}", picture, 10, nil, :chase1, turns: false)
      end
    end

    # ...and finished: a few pictures of falling and then a body on the floor, which lasts for
    # good because its length is nought.
    def self.falling(poses, ticks)
      poses.fall.each_with_index.map { |picture, n|
        state(:"fall#{n + 1}", picture, ticks, nil,
              n + 1 < poses.fall.length ? :"fall#{n + 2}" : :dead, turns: false)
      } + [state(:dead, poses.dead, 0, nil, :dead, turns: false)]
    end

    # --- and what each of them does its own way -------------------------------------------

    # A GUARD raises his gun, fires and lowers it across three pictures at twenty each, and the
    # bullet leaves on the middle one.
    GUARD_STATES = [
      *standing_still(MAN),
      *walking(MAN),
      state(:shoot1, MAN.attack[0], 20, nil, :shoot2, turns: false),
      state(:shoot2, MAN.attack[1], 20, nil, :shoot3, turns: false, fires: :gun),
      state(:shoot3, MAN.attack[2], 20, nil, :chase1, turns: false),
      *flinching(MAN),
      *falling(MAN, 15)
    ].freeze

    # AN OFFICER raises his gun in a third of the time a guard takes and lowers it in half —
    # which is what makes him the one you cannot stand and trade shots with. He takes an extra
    # picture to fall over.
    OFFICER_STATES = [
      *standing_still(OFFICER_POSES),
      *walking(OFFICER_POSES),
      state(:shoot1, OFFICER_POSES.attack[0], 6,  nil, :shoot2, turns: false),
      state(:shoot2, OFFICER_POSES.attack[1], 20, nil, :shoot3, turns: false, fires: :gun),
      state(:shoot3, OFFICER_POSES.attack[2], 10, nil, :chase1, turns: false),
      *flinching(OFFICER_POSES),
      *falling(OFFICER_POSES, 11)
    ].freeze

    # AN SS CARRIES A MACHINE GUN, and the table is where that lives: nine pictures instead of
    # three, and FOUR of them fire. He is not a guard who hits harder — every gun in this game
    # does the same damage — he is a guard who gets four shots off for your one.
    SS_STATES = [
      *standing_still(MAN),
      *walking(MAN),
      state(:shoot1, MAN.attack[0], 20, nil, :shoot2, turns: false),
      state(:shoot2, MAN.attack[1], 20, nil, :shoot3, turns: false, fires: :gun),
      state(:shoot3, MAN.attack[2], 10, nil, :shoot4, turns: false),
      state(:shoot4, MAN.attack[1], 10, nil, :shoot5, turns: false, fires: :gun),
      state(:shoot5, MAN.attack[2], 10, nil, :shoot6, turns: false),
      state(:shoot6, MAN.attack[1], 10, nil, :shoot7, turns: false, fires: :gun),
      state(:shoot7, MAN.attack[2], 10, nil, :shoot8, turns: false),
      state(:shoot8, MAN.attack[1], 10, nil, :shoot9, turns: false, fires: :gun),
      state(:shoot9, MAN.attack[2], 10, nil, :chase1, turns: false),
      *flinching(MAN),
      *falling(MAN, 15)
    ].freeze

    # A MUTANT has a gun in its chest and fires twice a burst, the first shot before the arm is
    # even up. Four attacking pictures, and it goes down in seven-unit steps rather than fifteen
    # — the fastest death in the game.
    MUTANT_STATES = [
      *standing_still(MUTANT_POSES),
      *walking(MUTANT_POSES),
      state(:shoot1, MUTANT_POSES.attack[0], 6,  nil, :shoot2, turns: false, fires: :gun),
      state(:shoot2, MUTANT_POSES.attack[1], 20, nil, :shoot3, turns: false),
      state(:shoot3, MUTANT_POSES.attack[2], 10, nil, :shoot4, turns: false, fires: :gun),
      state(:shoot4, MUTANT_POSES.attack[3], 20, nil, :chase1, turns: false),
      *flinching(MUTANT_POSES),
      *falling(MUTANT_POSES, 7)
    ].freeze

    # A DOG IS THE ODD ONE, in three ways that all come from the same fact: it has no gun.
    #
    # It never STANDS — the original has no arm for a standing dog at all, and no floor of the
    # game puts one down, so a code in its standing block reads as nothing here too. It closes on
    # you rather than stopping for a shot, which is the +hunt+ it thinks about. And instead of
    # firing it JUMPS, five pictures with its teeth on the second — which is why a dog can only
    # hurt you by reaching you, and why backing away from one works.
    #
    # It has no flinch either: one hit point means every hit that lands is the last one.
    DOG_STATES = [
      *walking(DOG_POSES, closing: :hunt),
      state(:jump1, DOG_POSES.attack[0], 10, nil, :jump2, turns: false),
      state(:jump2, DOG_POSES.attack[1], 10, nil, :jump3, turns: false, fires: :teeth),
      state(:jump3, DOG_POSES.attack[2], 10, nil, :jump4, turns: false),
      state(:jump4, DOG_POSES.attack[0], 10, nil, :jump5, turns: false),
      state(:jump5, DOG_POSES.walk[0],   10, nil, :chase1, turns: false),
      *falling(DOG_POSES, 15)
    ].freeze

    # A BOSS IS A GUARD WITH THE DIALS TURNED UP, and the whole of him is in this one table.
    #
    # He does not PATROL: he waits where the floor put him until he sees you. He does not
    # FLINCH: a shot that does not kill him does not slow him down either, and against eight
    # hundred and fifty hit points that is what makes standing and trading shots with him a way
    # to die. He does not TURN: every picture faces you. And where a guard fires once over three
    # pictures, he fires SIX TIMES over eight — a chaingun, which is why the room he is in has
    # nowhere to stand.
    #
    # The first picture is thirty units long and every one after it is ten, so there is a beat
    # between seeing the guns come up and being hit by them. That gap is the whole fight.
    BOSS_STATES = [
      *standing_still(BOSS_POSES, turns: false),
      *chasing_only(BOSS_POSES),
      state(:shoot1, BOSS_POSES.attack[0], 30, nil, :shoot2, turns: false),
      state(:shoot2, BOSS_POSES.attack[1], 10, nil, :shoot3, turns: false, fires: :gun),
      state(:shoot3, BOSS_POSES.attack[2], 10, nil, :shoot4, turns: false, fires: :gun),
      state(:shoot4, BOSS_POSES.attack[1], 10, nil, :shoot5, turns: false, fires: :gun),
      state(:shoot5, BOSS_POSES.attack[2], 10, nil, :shoot6, turns: false, fires: :gun),
      state(:shoot6, BOSS_POSES.attack[1], 10, nil, :shoot7, turns: false, fires: :gun),
      state(:shoot7, BOSS_POSES.attack[2], 10, nil, :shoot8, turns: false, fires: :gun),
      state(:shoot8, BOSS_POSES.attack[0], 10, nil, :chase1, turns: false),
      *falling(BOSS_POSES, 15)
    ].freeze

    # --- the seven of them ------------------------------------------------------------------

    # WHERE EACH KIND'S CODES AND PICTURES ARE.
    #
    # Plane 1 gives each kind eight codes — four facings standing, four patrolling — and repeats
    # the eight twice more further up for the ones a harder game adds. All but the mutant repeat
    # 36 apart; his repeat 18, because his codes run so near the top of a byte that three blocks
    # 36 apart would not fit in one.
    #
    # The pictures are a plain list in VSWAP — a demo picture, a death-cam picture, forty-eight
    # pieces of scenery, and then the five kinds in this order — so each kind's run begins where
    # the last one's ended. Checked against a real VSWAP rather than counted off the source: the
    # shapes change at exactly these numbers, a man's tall narrow box giving way to a dog's short
    # wide one at 99 and back again at 138.
    #
    # +hit_points+ is one number per setting, because the mutant is the one kind a harder game
    # toughens. +patrol_speed+ is the original's own — so many CELLths of a cell per unit of its
    # time — and +chase_times+ how much faster it goes once it has seen you, which is the number
    # that makes an officer frightening and a dog quick.
    #
    # THE GUARD IS FIRST, and stays first: he is the one kind on all but one floor of the game,
    # and a cartridge lays its state table out in this order, so his state numbers are the whole
    # table's numbers too.
    HARDER_STEP = 36
    MUTANT_HARDER_STEP = 18

    # A RANK-AND-FILE KIND IS EIGHT CODES REPEATED THREE TIMES — four facings standing and the
    # same four patrolling, repeated for the ones a harder game adds. A boss is one code, once:
    # he stands on every setting, and he has no facing to pick because none of his pictures
    # turn. See +codes+ and +blocks+ on the class above.
    RANKS = { codes: 8, blocks: 3 }.freeze
    BOSS = { codes: 1, blocks: 1, harder: 0 }.freeze

    # HOW MUCH KILLING A BOSS TAKES, one number per setting. The two share it, which the
    # original's own table does too — Hans and Gretel are the same fight in different colours.
    BOSS_HIT_POINTS = [850, 950, 1050, 1200].freeze
    BOSS_POINTS = 5000

    # WHERE THE BOSS PICTURES SIT. Checked against a real VSWAP rather than counted off the
    # source, the same way the rank-and-file numbers were: the four Pac-Man ghosts sit between
    # the officer and Hans, and between Hans and Gretel sit Schabbs, the syringes he throws,
    # both Hitlers, Giftmacher, and the rockets — none of which this cartridge builds yet.
    ALL = [
      new(name: :guard, standing: 108, harder: HARDER_STEP, first_picture: 50,
          hit_points: [25] * 4, points: 100, patrol_speed: 512, chase_times: 3,
          leaves: :clip, states: GUARD_STATES, stands: true, **RANKS),
      new(name: :dog, standing: 134, harder: HARDER_STEP, first_picture: 99,
          hit_points: [1] * 4, points: 200, patrol_speed: 1500, chase_times: 2,
          leaves: nil, states: DOG_STATES, stands: false, **RANKS),
      new(name: :ss, standing: 126, harder: HARDER_STEP, first_picture: 138,
          hit_points: [100] * 4, points: 500, patrol_speed: 512, chase_times: 4,
          leaves: :machine_gun, states: SS_STATES, stands: true, **RANKS),
      new(name: :mutant, standing: 216, harder: MUTANT_HARDER_STEP, first_picture: 187,
          hit_points: [45, 55, 55, 65], points: 700, patrol_speed: 512, chase_times: 3,
          leaves: :clip, states: MUTANT_STATES, stands: true, **RANKS),
      new(name: :officer, standing: 116, harder: HARDER_STEP, first_picture: 238,
          hit_points: [50] * 4, points: 400, patrol_speed: 512, chase_times: 5,
          leaves: :clip, states: OFFICER_STATES, stands: true, **RANKS),
      # HANS GROSSE, who guards the way out of the first episode, and GRETEL, who guards the way
      # out of the fifth. They walk at a guard's pace until they see you and then at three times
      # it, which is the original's own pair of numbers for them.
      new(name: :hans, standing: 214, first_picture: 296,
          hit_points: BOSS_HIT_POINTS, points: BOSS_POINTS, patrol_speed: 512, chase_times: 3,
          leaves: :gold_key, states: BOSS_STATES, stands: true, **BOSS),
      new(name: :gretel, standing: 197, first_picture: 385,
          hit_points: BOSS_HIT_POINTS, points: BOSS_POINTS, patrol_speed: 512, chase_times: 3,
          leaves: :gold_key, states: BOSS_STATES, stands: true, **BOSS)
    ].freeze

    BY_NAME = ALL.to_h { |kind| [kind.name, kind] }.freeze

    def self.[](name) = BY_NAME.fetch(name)

    GUARD = self[:guard]

    # What each of the thinking jobs is numbered, so one table can say which to do. A dog HUNTS
    # where everything else chases: it closes on you instead of stopping for a shot.
    THINKING = { nil => 0, look: 1, patrol: 2, chase: 3, hunt: 4 }.freeze

    # ...and what each attack is numbered, the same way.
    ATTACKS = { nil => 0, gun: 1, teeth: 2 }.freeze

    # WHAT EACH ONE LEAVES WHERE IT FALLS, numbered so a table can say it. Nought is nothing,
    # which is a dog: it carries no ammunition and drops none. A boss leaves the GOLD KEY, and
    # that is what killing him is for — the way out of the floor is behind a gold-locked door.
    LEAVES = { nil => 0, clip: 1, machine_gun: 2, gold_key: 3 }.freeze

    # One who has noticed you keeps knowing it, through being hurt and into falling over. The one
    # thing it changes: one who has NOT noticed you takes double from a shot, which is the
    # original quietly rewarding you for getting the first one in.
    UNROUSED = %i[stand path1 path1s path2 path3 path3s path4].freeze

    def self.roused?(state) = !UNROUSED.include?(state.name)

    # --- one kind, asked about itself -------------------------------------------------------

    # The four patrolling codes come straight after the four standing ones.
    def patrolling = standing + (codes / 2)

    # Is this one of the two who guard the way out of an episode? Asked where the difference
    # shows: a boss is one code rather than eight, and has no facing to be put down with.
    def boss? = codes == 1

    # The pictures this kind needs: every one any of its states can wear. A state that turns
    # needs all eight of its own, because which one shows depends on where the player is standing
    # — a guard facing east still has his back to you from the other side of the room. A state
    # that does not turn needs the one.
    def pictures
      states.flat_map { |s| s.turns ? (0...POSES).map { |n| s.picture + n } : [s.picture] }
            .uniq.sort.map { |offset| first_picture + offset }
    end

    # Which picture a state wears, as VSWAP numbers sprites.
    def picture_of(state) = first_picture + state.picture

    # Where a state sits in this kind's own run of them, or nil for one it does not have.
    def state_number(name) = states.index { |s| s.name == name }

    def has?(name) = states.any? { |s| s.name == name }

    # How much killing it takes on the setting numbered +setting+ — the four run in the order
    # Guards::SETTINGS names them. The mutant is the one kind whose four differ; the rest hold
    # the same number four times.
    def toughness(setting) = hit_points.fetch(setting)

    # HOW FAR IT WALKS PER THINK, which is every other frame. The division by SCALE is what turns
    # our thirds back into the original's units, so the distance per second comes out as the
    # original's however the counting is arranged.
    def speed(chasing: false)
      patrol_speed * (chasing ? chase_times : 1) * TICKS_PER_THINK / SCALE / CELL.to_f
    end
  end
end
