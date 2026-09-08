# frozen_string_literal: true

require_relative "test_helper"

# THE FIVE KINDS OF ENEMY: the guard, the officer, the SS, the dog and the mutant.
#
# What is really being tested here is that FIVE KINDS COST WHAT ONE COSTS. A state number says
# which kind is in it, so every number a kind decides — its speed, its gun, its toughness, what
# it leaves — is a column of a table read by that one number. So each test below picks a kind's
# number and asks the game being played to show it: a dog that cannot shoot you, an officer that
# outruns a guard, an SS that leaves the machine gun this game's whole middle depends on.
#
# The guard's own behaviour is held to its own tests in test_guards.rb; these are about what the
# other four do DIFFERENTLY. Nearly all of them read the pool rather than the screen, which is a
# hundred times cheaper and the same answers.
class TestEnemies < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Guards = Wolf3D::Guards
  Enemy = Wolf3D::Enemy
  Behaviour = Wolf3D::Behaviour
  Weapons = Wolf3D::Weapons
  Release = Wolf3D::Fixture::Release

  SIDE = 24
  FLOOR = Wolf3D::Level::FLOOR
  WALL = Release::WALL

  # The player stands here looking east, and everything put down for it to meet stands on this
  # row, further east — so how far a thing has got is a single number.
  ROW = 12
  PLAYER_X = 4

  # ---------------------------------------------------------------- reading them off the level

  # EACH KIND HAS ITS OWN EIGHT CODES, and the only way to be sure which eight is to put one of
  # each down and read them back.
  def test_each_kind_is_read_from_its_own_codes
    standing = Enemy::ALL.reject { |kind| kind.name == :dog }
    level = with_things(standing.each_with_index.to_h { |kind, n| [[8 + n, ROW], kind.standing] })

    assert_equal standing.map(&:name), Guards.new(level).guards.map(&:kind)
  end

  def test_the_four_patrolling_codes_come_after_the_four_standing_ones
    level = with_things(Enemy::ALL.each_with_index.to_h { |kind, n| [[8 + n, ROW], kind.patrolling] })
    read = Guards.new(level).guards

    assert_equal Enemy::ALL.map(&:name), read.map(&:kind)
    assert(read.all?(&:patrolling), "every one of them should be walking a beat")
  end

  # A HARDER GAME REPEATS EACH KIND'S BLOCK FURTHER UP, and the step is 36 for four of them and
  # EIGHTEEN for the mutant — whose codes run so near the top of a byte that three blocks 36
  # apart would not fit in one. Reading a mutant 36 up finds nothing at all, which is the wrong
  # answer this is here to catch.
  def test_a_mutants_harder_blocks_are_eighteen_apart_and_everyone_elses_are_thirty_six
    Enemy::ALL.each do |kind|
      codes = { [8, ROW] => kind.standing + kind.harder,
                [9, ROW] => kind.standing + (kind.harder * 2) }
      codes = { [8, ROW] => kind.patrolling + kind.harder,
                [9, ROW] => kind.patrolling + (kind.harder * 2) } unless kind.stands
      read = Guards.new(with_things(codes)).guards

      assert_equal [kind.name, kind.name], read.map(&:kind), "#{kind.name}'s harder blocks"
      assert_equal [Guards::SETTINGS.index(:medium), Guards::SETTINGS.index(:hard)],
                   read.map(&:from), "...and which setting each waits for"
    end
    assert_equal Enemy::MUTANT_HARDER_STEP, Enemy[:mutant].harder
  end

  # A STANDING DOG IS NOT PLACED AT ALL. The original's spawning code has no arm for one, so a
  # code in the dog's standing block puts nothing on the floor — and no floor of the game holds
  # one, which is why nobody ever noticed. Reading it as a dog standing still would give this
  # game an enemy Wolfenstein does not have.
  def test_a_standing_dog_code_places_nothing
    dog = Enemy[:dog]

    assert_empty Guards.new(with_things({ [8, ROW] => dog.standing })).guards,
                 "a standing dog is not a thing this game has"
    assert_equal [:dog], Guards.new(with_things({ [8, ROW] => dog.patrolling })).guards.map(&:kind)
  end

  # A FLOOR SHIPS THE KINDS THAT STAND ON IT AND NOTHING ELSE, which is what keeps a cartridge
  # of nothing but guards exactly the size it was.
  def test_a_floor_names_only_the_kinds_standing_on_it
    level = with_things({ [8, ROW] => Enemy[:ss].standing, [9, ROW] => Enemy[:dog].patrolling })
    guards = Guards.new(level)

    assert_equal %i[dog ss], guards.kinds.sort
    assert_equal (Enemy[:dog].pictures + Enemy[:ss].pictures).sort, guards.pictures
    refute_includes guards.pictures, Enemy[:officer].first_picture, "no officer, no officer art"
  end

  # EACH KIND'S PICTURES ARE A RUN OF THEIR OWN, laid end to end in the file, so no two kinds
  # can be pointing at the same art. The guard starting at 50 is the anchor the rest hang off.
  def test_the_five_runs_of_pictures_follow_one_another_and_never_overlap
    runs = Enemy::ALL.map(&:pictures)

    assert_equal 50, runs.first.min, "the guard's art begins where the scenery's ends"
    runs.each_cons(2) do |before, after|
      assert_equal before.max + 1, after.min, "one kind's art begins where the last one's ended"
    end
    assert_equal runs.sum(&:length), runs.flatten.uniq.length, "and no picture is shared"
  end

  # ---------------------------------------------------------------- what they do differently

  # A DOG HAS NO GUN, so the only way it can hurt you is to reach you. Held as two readings of
  # one run: while it is still closing you are untouched, and once it arrives you are not.
  def test_a_dog_has_to_reach_you_before_it_can_hurt_you
    program = a_floor_of(:dog, at: 14)
    closing = Reference.new.run(program, frames: 60)
    arrived = Reference.new.run(program, frames: 600)

    assert_operator where(closing), :<, 14.5, "it should have set off toward you"
    assert_operator where(closing), :>, PLAYER_X + Guards::BITE_REACH, "and still be out of reach"
    assert_equal FP::START_HEALTH, closing[:health], "so it cannot have touched you yet"

    assert_operator where(arrived), :<=, PLAYER_X + Guards::BITE_REACH, "then it arrives"
    assert_operator arrived[:health], :<, FP::START_HEALTH, "and bites"
  end

  # A BARREL IN A CORRIDOR IS NOTHING TO A GUARD AND EVERYTHING TO A DOG, which is the same rule
  # from the other side and the one that decides how the two are played against. A barrel stops
  # feet, and not eyes and not bullets — so down a one-cell corridor with a barrel across it the
  # guard walks up to it and shoots you over the top, and the dog walks up to it and can do
  # nothing at all, for as long as you care to stand there.
  def test_a_barrel_in_the_way_stops_a_dog_and_not_a_guard
    frames = 800

    assert_operator Reference.new.run(a_corridor_with(:guard), frames: frames)[:health],
                    :<, FP::START_HEALTH, "a guard shoots over it"
    assert_equal FP::START_HEALTH, Reference.new.run(a_corridor_with(:dog), frames: frames)[:health],
                 "and a dog that cannot get past it can do nothing at all"
  end

  # AN OFFICER RUNS YOU DOWN. His chase speed is five times his patrol where a guard's is three,
  # which is the number that makes him the one you cannot back away from.
  def test_an_officer_closes_faster_than_a_guard
    frames = 200
    guard = where(Reference.new.run(a_floor_of(:guard, at: 18), frames: frames))
    officer = where(Reference.new.run(a_floor_of(:officer, at: 18), frames: frames))

    assert_operator officer, :<, guard, "the officer should have covered more ground"
    assert_operator 18.5 - officer, :>, (18.5 - guard) * 1.3, "and by a good margin"
  end

  # HOW MUCH KILLING EACH TAKES is the original's own number, and they are far apart: a dog goes
  # down to anything at all, a guard to a few shots, an SS to four times that.
  def test_each_kind_takes_its_own_amount_of_killing
    assert_equal [1, 25, 50, 100, 55],
                 %i[dog guard officer ss mutant].map { |name| toughness(name) },
                 "read out of the original's own table"

    assert_operator hp(a_dog_shot_once), :<=, 0, "one bullet finishes a dog"
    assert_operator hp(shoot_at(:ss, shots: 4, frames: 200)), :>, 0,
                    "and four do not finish an SS"
  end

  # ...AND THE MUTANT IS THE ONE KIND A HARDER GAME TOUGHENS. Everybody else holds the same
  # number on all four settings; his run 45, 55, 55, 65, so the setting has to be read when the
  # floor starts rather than baked in when the cartridge was built.
  def test_a_mutant_is_tougher_on_a_harder_setting
    assert_equal [45, 55, 55, 65], Enemy[:mutant].hit_points, "the original's own four"
    assert_equal [25], Enemy[:guard].hit_points.uniq, "where a guard's four are one number"

    assert_equal 45, standing_hp_at(:baby), "the easiest game stands up the softest mutant"
    assert_equal 65, standing_hp_at(:hard), "and the hardest the toughest"
  end

  # WHAT KILLING ONE IS WORTH, which is not the same for the five and is the original's own
  # scale: a dog is worth twice a guard and a mutant seven times.
  def test_killing_each_kind_is_worth_the_originals_own_score
    assert_equal({ guard: 100, dog: 200, officer: 400, ss: 500, mutant: 700 },
                 Enemy::ALL.to_h { |kind| [kind.name, kind.points] })

    assert_equal Enemy[:dog].points, a_dog_shot_once[:score],
                 "a dog is worth two hundred, read off the game rather than the table"
  end

  # ---------------------------------------------------------------- what they leave behind

  # THE SS IS WHERE THE MACHINE GUN COMES FROM, and this is the most consequential line in the
  # whole change: the original hands you one off a dead SS when you have not got one, which is
  # most of how a player ever gets their second weapon. Without it a floor of SS is a floor you
  # fight with a pistol.
  def test_a_fallen_ss_leaves_the_machine_gun_you_walk_over
    run = kill_and_collect(:ss, shots: 30, frames: 900)

    assert_operator hp(run), :<=, 0, "he has to be down for this to mean anything"
    assert_equal Weapons::MACHINE_GUN, run[:weapon_best], "and you should be carrying his gun"
  end

  # ...AND A CLIP INSTEAD WHEN YOU ALREADY HAVE ONE, which is the same line's other half and the
  # reason an SS stays worth killing after the first: from then on he feeds the gun he gave you.
  # The gun is picked up off the floor here rather than off an earlier body, which is the same
  # question asked with one SS instead of two.
  def test_an_ss_leaves_a_clip_once_the_gun_is_already_yours
    run = pick_up_the_gun_then_kill_an_ss

    assert_equal Weapons::MACHINE_GUN, run[:weapon_best], "the floor armed you before he fell"
    assert_operator hp(run), :<=, 0, "and he is down"
    assert_equal [Wolf3D::Pickups::CLIP_LEFT], dropped(run).reject(&:zero?).uniq,
                 "so what he left is half a clip, not a second gun"
  end

  # A DOG CARRIES NOTHING AND LEAVES NOTHING, which is the original's own killing code: every
  # other kind places a clip where it fell and the dog places none.
  def test_a_dog_leaves_nothing_where_it_fell
    assert_equal [Wolf3D::Pickups::NOTHING_LEFT], dropped(a_dog_shot_once).uniq,
                 "there is nothing lying where a dog was"
    assert_equal [Wolf3D::Pickups::CLIP_LEFT], dropped(shoot_at(:guard, shots: 8, frames: 300)).uniq,
                 "where a guard leaves half a clip"
  end

  # ---------------------------------------------------------------- what a cartridge pays for

  # A CARTRIDGE WITH NO DOGS EMITS NO HUNTING AND NO BITING, which is what keeps a game of
  # nothing but guards the size it was before there were five kinds.
  def test_a_cartridge_ships_only_the_behaviour_of_the_kinds_it_holds
    guards_only = Behaviour.for([:guard])

    assert_equal Enemy::GUARD.states.length, guards_only.length, "the guard's table and no more"
    refute guards_only.any?(:hunt), "nothing on it hunts"
    refute guards_only.any?(:teeth), "and nothing bites"

    with_dogs = Behaviour.for(%i[guard dog])

    assert with_dogs.any?(:hunt), "a floor with a dog on it hunts"
    assert with_dogs.any?(:teeth), "and bites"
  end

  # THE CONSOLE DRAWS A DOG THE WAY THE INTERPRETER DOES, which is what says the tables the five
  # kinds are made of really lower. A dog is the one that exercises all of them at once: its own
  # run of pictures, its own speed, and states that reach neither a gun nor a flinch.
  def test_the_console_draws_a_dog_the_interpreter_draws
    program = a_drawn_floor_of(:dog, at: 10)
    interp = Reference.new.run(program, frames: 3)
    rom = ROM.assemble(GBA.new.lower(program), title: "DOGS", code: "ZDOG", maker: "01")
    gba = RubyGBA::Verifier.new(rom, frames: 8)

    refute_empty dog_columns(interp), "the interpreter draws him, so there is something to match"
    differ = (0...240).to_a.product((0...160).to_a).reject do |x, y|
      (interp.screen.pixel(x, y) || 0) == gba.pixel_gba(x, y)
    end

    assert_empty differ.first(8), "these pixels differ between the interpreter and the console"
  end

  # A STATE NUMBER SAYS WHICH KIND IS IN IT, which is the whole reason five kinds are affordable:
  # nothing in the pool remembers a kind and nothing branches on one.
  def test_every_state_belongs_to_exactly_one_kind
    all = Behaviour.for(Enemy::ALL.map(&:name))

    Enemy::ALL.each do |kind|
      mine = (0...all.length).select { |n| all.kind_at(n).name == kind.name }

      assert_equal kind.states.length, mine.length, "#{kind.name} owns its own run"
      assert_equal mine, (mine.min..mine.max).to_a, "and the run is unbroken"
    end
  end

  private

  # ENOUGH SPRITES TO REACH THE LAST PICTURE ANY KIND CAN WEAR, which is the officer's, plus the
  # weapons a release keeps last. Everything before them is unused here, and small.
  SPRITES = Enemy::ALL.flat_map(&:pictures).max + 1 + Wolf3D::WeaponAtlas::COUNT

  def fixture = @fixture ||= Release.new(sprites: SPRITES)
  def vswap = @vswap ||= Wolf3D::Vswap.new(fixture.files["VSWAP"])
  def palette = Wolf3D::Palette.game

  ONE = (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

  def pool_field(run, field, slot = 0)
    run.instance_variable_get(:@lists)[:"__pool_guard_#{field}"].get(slot)
  end

  # A POOL HANDS OUT ITS SLOTS FROM THE BACK, so the order a level put its enemies down is not
  # the order they are stored in. Everything below reads the NEAREST one, which is the one a
  # shot down the line meets and the one that reaches you first.
  def nearest(run)
    lists = run.instance_variable_get(:@lists)
    live = (0...lists[:__pool_guard_active].length).select { |n| lists[:__pool_guard_active].get(n) == 1 }
    live.min_by { |slot| pool_field(run, :x, slot) } || 0
  end

  def hp(run) = pool_field(run, :hp, nearest(run))
  def where(run) = pool_field(run, :x, nearest(run)) / ONE

  # What every live slot is lying beside, which is how "he left a gun" is read off a game.
  def dropped(run)
    lists = run.instance_variable_get(:@lists)
    (0...lists[:__pool_guard_active].length)
      .select { |slot| lists[:__pool_guard_active].get(slot) == 1 }
      .map { |slot| pool_field(run, :dropped, slot) }
  end

  def toughness(name) = Enemy[name].toughness(Guards.number_of(Guards::DEFAULT_DIFFICULTY))

  # ONE OF A KIND, FACING YOU, so it notices and the run is about what it does then. A dog is
  # always walking a beat, so facing it your way is also what sends it down the corridor.
  def a_floor_of(name, at:, facing: :west, count: 1)
    program_for(name, at, facing, count) { |b, view| b.game_loop { view.play } }
  end

  # ...and one that really draws, which only the question about the console needs. Every other
  # test here reads the pool instead, which is a hundred times cheaper and the same answers.
  def a_drawn_floor_of(name, at:, facing: :west)
    program_for(name, at, facing, 1, :drawn) { |b, view| b.game_loop { view.update } }
  end

  # How much killing it takes, read off a floor rather than a table: stand still and tap.
  def shoot_at(name, shots:, frames:, at: 8, count: 1)
    firing = ->(f) { f < shots * A_SHOT && f.even? ? [:b] : [] }
    Reference.new.input_each_frame { |f| firing.call(f) }
             .run(a_floor_of(name, at: at, count: count), frames: frames)
  end

  # ...and then walk forward over what it left. The trigger goes up for the last stretch so the
  # player is walking rather than shooting when they reach the body.
  def kill_and_collect(name, shots:, frames:, at: 7, count: 1)
    walking = ->(f) { f < shots * A_SHOT ? (f.even? ? [:b] : []) : [:up] }
    Reference.new.input_each_frame { |f| walking.call(f) }
             .run(a_floor_of(name, at: at, count: count), frames: frames)
  end

  # BACK OVER A MACHINE GUN LYING BEHIND YOU, then stand and empty the thing into the SS coming
  # down the room. What he leaves is decided when he falls, so by then the gun is already yours
  # — and stepping BACKWARD is what keeps the player off the cell he falls in, which would
  # otherwise pick up what he left before the test could read it.
  WALKING_BACK_FOR = 20

  def pick_up_the_gun_then_kill_an_ss
    @pick_up_the_gun_then_kill_an_ss ||= begin
      code = Enemy[:ss].standing + Guards::FACINGS.index(:west)
      level = with_things({ [12, ROW] => code,
                            [3, ROW] => Wolf3D::Scenery::FIRST_CODE + MACHINE_GUN_ON_THE_FLOOR })
      program = build(level) { |b, view| b.game_loop { view.play } }
      firing = ->(f) { f < WALKING_BACK_FOR ? [:down] : (f.even? ? [:b] : []) }
      Reference.new.input_each_frame { |f| firing.call(f) }.run(program, frames: 900)
    end
  end

  # Which piece of scenery is a machine gun lying on the floor, read off the original's own
  # table of what walking onto a thing gives you.
  MACHINE_GUN_ON_THE_FLOOR =
    Wolf3D::Scenery::BONUSES.find { |_, (kind, which)| kind == :weapon && which == :machine_gun }.first

  # HOW LONG ONE SHOT REALLY TAKES: the weapon's own cycle, plus the pass the trigger needs to
  # come back up before it can be pressed again.
  A_SHOT = Wolf3D::Weapons::CYCLE + 2

  # ONE BULLET AT ARM'S LENGTH, which a dog's single hit point cannot survive. Close enough that
  # the pistol cannot miss: past four cells a shot has to beat the distance to land at all.
  def a_dog_shot_once = @a_dog_shot_once ||= shoot_at(:dog, shots: 1, frames: 40, at: 6)

  # A mutant standing up on a game set +how+, which is the only way to see the setting being
  # read WHEN THE FLOOR STARTS rather than baked in when the cartridge was built. The floor is
  # started again after the setting is written, which is what a game does when you pick.
  def standing_hp_at(how)
    program = program_for(:mutant, 10, :west, 1, how) do |b, view|
      b.game_loop do
        view.difficulty.set Guards.number_of(how)
        b.call :start_the_floor
      end
    end
    hp(Reference.new.run(program, frames: 2))
  end

  # A ONE-CELL CORRIDOR WITH A BARREL ACROSS IT, and one of +name+ on the far side of the barrel.
  def a_corridor_with(name)
    kind = Enemy[name]
    code = (kind.stands ? kind.standing : kind.patrolling) + Guards::FACINGS.index(:west)
    level = with_things({ [14, ROW] => code, [6, ROW] => Wolf3D::Scenery::FIRST_CODE + BARREL },
                        corridor: true)
    @corridors ||= {}
    @corridors[name] ||= build(level) { |b, view| b.game_loop { view.play } }
  end

  # A piece of scenery a body cannot walk through, read off the original's own list.
  BARREL = Wolf3D::Scenery::BLOCKING.first

  # WHICH STRIPS OF THE SCREEN A DOG IS SHOWING IN, read across the eye line. The fixture paints
  # every sprite one flat colour of its own, so the colour of a pixel says which picture drew it
  # — and a dog's eight walking poses are eight colours nothing else on this floor wears.
  def dog_columns(run, row: FP::HORIZON)
    inks = (0...Enemy::POSES).map { |n| palette[(Release::SPRITE_INK + Enemy[:dog].first_picture + n) & 0xFF] }
    (0...240).select { |x| inks.include?(run.screen.pixel(x, row)) }
  end

  # Built once per shape, since building one takes far longer than running it.
  def program_for(name, at, facing, count, tag = nil, &loop_body)
    @programs ||= {}
    @programs[[name, at, facing, count, tag, loop_body.source_location]] ||=
      build(a_level_with(name, at, facing, count), &loop_body)
  end

  # One of them on the player's row, or several in a line — which the questions about what is
  # left lying need, so there is a second one to walk over the first one's gift with.
  def a_level_with(name, at, facing, count)
    kind = Enemy[name]
    code = (kind.stands ? kind.standing : kind.patrolling) + Guards::FACINGS.index(facing)
    with_things((0...count).to_h { |n| [[at + (n * 4), ROW], code] })
  end

  def build(level, &loop_body)
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Guards.new(level)
    scenery = Wolf3D::Scenery.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, palette, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, palette,
                                    (guards.pictures + scenery.pictures +
                                     Wolf3D::Pickups.pictures(guards)).uniq.sort)

    RubyGBA.game("ENEMIES", code: "ZENM", maker: "01") do
      screen :bitmap, tear_free: true
      view = FP.new(build: self, level: level, atlas: atlas, doors: doors, pushwalls: pushwalls,
                    guards: guards, things: things, scenery: scenery, startable: true)
      loop_body.call(self, view)
    end.program
  end

  # A walled field with the player on ROW looking east, and whatever else you name. +corridor+
  # walls off every row but the player's, so nothing can walk round what is put in the way.
  def with_things(things, corridor: false)
    cells = Array.new(SIDE * SIDE, FLOOR)
    standing = Array.new(SIDE * SIDE, 0)
    SIDE.times do |y|
      SIDE.times do |x|
        edge = x.zero? || y.zero? || x == SIDE - 1 || y == SIDE - 1
        cells[(y * SIDE) + x] = WALL if edge || (corridor && y != ROW)
      end
    end
    standing[(ROW * SIDE) + PLAYER_X] = Wolf3D::Level::FACINGS.key(:east)
    things.each { |(x, y), code| standing[(y * SIDE) + x] = code }

    Wolf3D::Level.new(name: "Enemies", width: SIDE, height: SIDE, walls: cells, things: standing)
  end
end
