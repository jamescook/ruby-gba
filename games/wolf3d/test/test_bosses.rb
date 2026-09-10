# frozen_string_literal: true

require_relative "test_helper"

# HANS GROSSE AND GRETEL, who guard the way out of the first and fifth episodes.
#
# THEY ARE THE SAME MACHINERY THE OTHER FIVE KINDS ARE, which is the thing worth holding: a
# state number says which kind is in it, so a boss's speed, his gun, his toughness and what he
# leaves are columns of the same tables a guard reads. Nothing here is a boss class. What is
# different is only what the numbers say — and three facts about the SHAPE, which is what these
# tests are mostly about:
#
#   ONE CODE, not eight. The five rank-and-file kinds have four facings standing and four
#     patrolling, repeated for a harder game. A boss is one code that stands on every setting.
#   NO PATROL AND NO FLINCH. He waits where he was put, and a shot that does not kill him does
#     not slow him down either.
#   NO TURNING. Every picture faces you, so he is eleven pictures where a guard is forty-nine.
#
# AND WHAT MAKES HIM MATTER: he leaves the gold key, and the gold key opens the door to the way
# out of the episode. Killing him is not itself the ending — see Level::EXIT.
class TestBosses < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Guards = Wolf3D::Guards
  Enemy = Wolf3D::Enemy
  Behaviour = Wolf3D::Behaviour
  Release = Wolf3D::Fixture::Release

  SIDE = 24
  FLOOR = Wolf3D::Level::FLOOR
  WALL = Release::WALL
  ROW = 12
  PLAYER_X = 4

  BOSSES = %i[hans gretel].freeze

  # ------------------------------------------------------------------ read off a floor

  # ONE CODE APIECE, and it is read whichever setting the game is set to — a boss is not
  # something a harder game adds.
  def test_a_boss_is_one_code_that_stands_on_every_setting
    BOSSES.each do |name|
      kind = Enemy[name]
      read = Guards.new(with_things({ [8, ROW] => kind.standing })).guards

      assert_equal [name], read.map(&:kind)
      assert_equal [Guards::SETTINGS.index(:baby)], read.map(&:from),
                   "#{name} stands on the easiest setting, so he stands on all four"
      assert_equal 1, kind.codes
      assert_equal 1, kind.blocks
    end
  end

  # HE LIES IN WAIT WHEREVER HE IS PUT, whatever the cell under him says — the original gives
  # him that outright rather than reading it off the map. It is what makes the fight begin when
  # you walk in and see him, rather than when he hears a shot two rooms away.
  def test_a_boss_lies_in_wait_without_being_stood_on_an_ambush_tile
    boss = Guards.new(with_things({ [8, ROW] => Enemy[:hans].standing })).guards.first

    assert boss.ambush, "a boss waits to SEE you"
    refute boss.patrolling, "and he never walks a beat"
  end

  # HE FACES NOWHERE, which is the original's own `nodir` and is what makes him notice you
  # whichever side you come in on: the test for whether he can see you has an arm per direction
  # and none for nowhere, so a thing facing nowhere falls straight through it.
  def test_a_boss_faces_nowhere_so_he_sees_you_from_any_side
    boss = Guards.new(with_things({ [8, ROW] => Enemy[:hans].standing })).guards.first

    assert_nil boss.facing
    assert_equal Guards::NOWHERE, Guards.direction_of(boss.facing)
    refute_equal Guards::NOWHERE, Guards.direction_of(:east), "where a guard faces a real way"
  end

  # A CODE ONE ABOVE HIS IS NOT HIM, which is what having a block of one means and is the thing
  # that would break quietly if the block size were ever read as eight again.
  def test_the_codes_either_side_of_a_boss_are_not_him
    hans = Enemy[:hans].standing

    assert_equal [:hans], Guards.new(with_things({ [8, ROW] => hans })).guards.map(&:kind)
    assert_empty Guards.new(with_things({ [8, ROW] => hans + 1 })).guards,
                 "the code above his belongs to nobody"
  end

  # ------------------------------------------------------------------ what the tables say

  def test_a_boss_takes_the_originals_own_killing_at_each_setting
    assert_equal [850, 950, 1050, 1200], Enemy[:hans].hit_points
    assert_equal Enemy[:hans].hit_points, Enemy[:gretel].hit_points,
                 "the two are the same fight in different colours"
  end

  def test_a_boss_has_no_beat_to_walk_and_no_flinch_to_take
    BOSSES.each do |name|
      kind = Enemy[name]

      refute kind.has?(:path1), "#{name} waits where he was put"
      refute kind.has?(:hurt1), "#{name} does not flinch"
      assert kind.has?(:stand), "...but he does stand and look"
      assert kind.has?(:chase1), "...and chase once he has seen you"
    end
  end

  # A WOUND THAT DOES NOT KILL HIM LEAVES HIM EXACTLY WHERE HE WAS, which is the original's own
  # arrangement: its damage code switches on the kind and has arms for the guard, the officer,
  # the mutant and the SS — and none at all for a boss. No arm means no new state.
  #
  # THAT IS THE WHOLE OF WHY HE IS FRIGHTENING. He fires six times to a burst, and a hit that
  # moved him would cancel it — so you could hold the trigger down and he would never get a shot
  # away. Left alone he finishes the burst whatever you do to him.
  def test_a_wound_that_does_not_kill_a_boss_leaves_him_exactly_where_he_was
    b = Behaviour.for([:hans])

    %i[stand chase1 shoot2].each do |name|
      here = b.number_of(:hans, name)

      assert_equal here, b.flinch_from(here), "a wounded boss in #{name} stays in #{name}"
      assert_equal here, b.flinch_from(here, second: true)
      assert_equal 0, b.flinches_from(here), "...so the wounding skips the flinch entirely"
    end
  end

  # ...WHERE A GUARD REALLY DOES FLINCH, which is the other half of the same rule and is what
  # says this is a difference between the kinds rather than the flinch being broken.
  def test_a_guard_still_flinches
    b = Behaviour.for([:guard])
    chasing = b.number_of(:guard, :chase1)

    assert_equal 1, b.flinches_from(chasing)
    assert_equal b.number_of(:guard, :hurt1), b.flinch_from(chasing)
    assert_equal b.number_of(:guard, :hurt2), b.flinch_from(chasing, second: true)
  end

  # SIX SHOTS TO A BURST, where a guard fires once and an SS four times. The first picture is
  # three times as long as the rest, which is the beat between the guns coming up and the burst
  # arriving — and the whole of what makes the fight survivable.
  def test_a_boss_fires_six_times_to_a_guards_once
    firing = ->(kind) { Enemy[kind].states.count { |s| s.fires == :gun } }

    assert_equal 6, firing.call(:hans)
    assert_equal 6, firing.call(:gretel)
    assert_equal 1, firing.call(:guard)
    assert_equal 4, firing.call(:ss)

    first, second = Enemy[:hans].states.select { |s| s.name.to_s.start_with?("shoot") }.first(2)
    assert_equal first.ticks, second.ticks * 3, "the guns take three beats to come up"
  end

  def test_a_boss_walks_at_a_guards_pace_until_he_sees_you_and_then_at_three_times_it
    assert_in_delta Enemy[:guard].speed, Enemy[:hans].speed, 0.0001
    assert_in_delta Enemy[:hans].speed * 3, Enemy[:hans].speed(chasing: true), 0.0001
  end

  # AND THE NUMBER THAT DECIDES WHETHER THE FIGHT IS WINNABLE AT ALL, which is worth pinning
  # because nothing else in the game says it: you walk two and a half times faster than he
  # chases. Backing away while firing is the fight, and it works.
  def test_you_walk_faster_than_a_boss_chases
    # A think is every other pass, so half the distance per think is the distance per pass.
    chasing = Enemy[:hans].speed(chasing: true) / 2

    assert_operator chasing, :<, FP::WALK,
                    "a boss you cannot back away from could not be beaten without strafing"
    assert_in_delta 0.39, chasing / FP::WALK, 0.02
  end

  # ------------------------------------------------------------------ the gold key

  def test_a_boss_leaves_the_gold_key_where_he_falls
    b = Behaviour.for([:hans])

    assert_equal Enemy::LEAVES.fetch(:gold_key),
                 b.leaves_from(b.number_of(:hans, :stand))
    assert_equal Enemy::LEAVES.fetch(:clip),
                 Behaviour.for([:guard]).leaves_from(0), "where a guard leaves a clip"
  end

  # WHAT IS LEFT LYING IS DRAWN, so the key needs a picture in the row every dropped thing is
  # drawn from — and it must be the gold one, not the silver.
  def test_the_key_a_boss_leaves_has_the_gold_keys_own_picture
    pictures = Wolf3D::Pickups.dropped_pictures

    assert_equal Wolf3D::Scenery.gold_key_picture,
                 pictures[Enemy::LEAVES.fetch(:gold_key)]
  end

  # ------------------------------------------------------------------ the way out

  # THE EXIT TILE IS WHAT ENDS AN EPISODE, and only two floors of the whole game carry one —
  # which are exactly the two floors the two bosses stand on. That is not a coincidence: the
  # boss stands between you and the gold-locked door, and the way out is behind it.
  def test_only_the_two_boss_floors_can_be_walked_out_of
    return skip("needs a copy of the game") unless Wolf3D.maps

    maps = Wolf3D.maps
    with_a_way_out = (0...maps.count).select { |n| maps[n].exits.any? }
    with_a_boss = (0...maps.count).select do |n|
      Guards.new(maps[n]).kinds.any? { |name| Enemy[name].boss? && maps[n].exits.any? }
    end

    assert_equal with_a_way_out, with_a_boss,
                 "every floor with a way out has the boss who carries its key"
    assert_equal 2, with_a_way_out.length
  end

  def test_the_way_out_of_a_floor_is_cells_lying_side_by_side
    return skip("needs a copy of the game") unless Wolf3D.maps

    Wolf3D.maps.each do |level|
      cells = level.exits.map { |x, y| (y * level.width) + x }.sort
      next if cells.empty?

      assert_equal cells.length - 1, cells.last - cells.first,
                   "#{level.name} — the view reads the way out as a RANGE of cells"
    end
  end

  # ------------------------------------------------------------------ played, not tabulated

  # HE COMES FOR YOU. Everything above is a table; this is a game being played, and it is what
  # says the tables are wired to anything at all.
  def test_a_boss_sets_off_toward_you_once_he_has_seen_you
    run = Reference.new.run(a_floor_with_a_boss(at: 14), frames: 200)

    assert_operator where(run), :<, 13.5, "he should have started down the room at you"
  end

  # ...AND HE DOES NOT GO DOWN LIKE A GUARD. Emptying a pistol into him — a dozen rounds, which
  # would clear a room of guards — leaves him standing, which is the whole of what eight hundred
  # and fifty hit points means.
  def test_a_boss_shrugs_off_what_would_kill_a_room_full_of_guards
    run = Reference.new
                   .input_each_frame { |f| f.even? ? [:b] : [] }
                   .run(a_floor_with_a_boss(at: 8), frames: 350)
    # The game is played on the setting a cartridge boots at until somebody picks another.
    full = Enemy[:hans].toughness(Guards.number_of(Guards::DEFAULT_DIFFICULTY))

    assert_operator hp(run), :>, 0, "a pistol does not finish him"
    assert_operator hp(run), :<, full, "...but it told"
    assert_operator hp(run), :>, full / 2, "and it is nowhere near half of him"
  end

  # ------------------------------------------------------------------ fighting him

  # STEPPING SIDEWAYS, which is what makes a boss fight a fight rather than a retreat. The
  # player starts facing east, so a step to either shoulder is a step along y and not along x —
  # which is also what says the sideways vector is a quarter turn off the facing and not the
  # facing itself.
  def test_the_shoulder_buttons_step_sideways
    still = played([])
    left = played([:l])
    right = played([:r])

    assert_operator left[:py] / ONE, :<, still[:py] / ONE, "L steps north when you face east"
    assert_operator right[:py] / ONE, :>, still[:py] / ONE, "R steps south"
    assert_in_delta still[:px] / ONE, left[:px] / ONE, 0.2, "and neither walks you forward"
  end

  # ...AND IT DOES NOT TURN YOU, which is the whole difference between a sidestep and a turn:
  # you keep looking at what you are shooting at.
  def test_stepping_sideways_leaves_you_looking_where_you_were
    still = played([])
    left = played([:l])

    assert_equal still[:view], left[:view], "a sidestep is not a turn"
  end

  # A SIDESTEP GOES THROUGH THE SAME WALL TEST the forward step does, or strafing into a wall
  # would put you through it. The room is walled at x=1, and the player stands on the row below
  # the top wall, so holding L walks him into it.
  def test_stepping_sideways_into_a_wall_stops_you
    against_the_wall = played([:l], frames: 600)

    assert_operator against_the_wall[:py] / ONE, :>, 1.0, "he must not be inside the wall"
  end

  # KILLING HIM OUTRIGHT IS NOT TESTED HERE, and it is worth saying why rather than leaving the
  # gap to be found. Measured on this floor: a chain gun picked up off the floor holds fourteen
  # rounds and a round takes about thirty-two off him, so one magazine is four hundred and fifty
  # against his thousand and fifty. The fight is not short by design — it wants a floor with
  # ammunition lying about it and several hundred frames — so it belongs to a cartridge somebody
  # plays rather than to a test that has to finish in a second.
  #
  # WHAT WOULD BE LOST IS COVERED ELSEWHERE. That he leaves the gold key when he falls is a
  # column of the state table, asserted above; that a thing left lying is picked up walking over
  # it is the same machinery a guard's clip and an SS's machine gun use, and test_enemies plays
  # both of those out end to end.

  # ------------------------------------------------------------------ helpers

  private

  # Hold these buttons for a while and hand back what the game came to. The boss is put far
  # enough away that he is still walking over rather than shooting, so what moves the player is
  # the pad and nothing else.
  def played(keys, frames: 120)
    Reference.new.input_each_frame { keys }.run(a_floor_with_a_boss(at: 20), frames: frames)
  end

  # ONE BOSS DOWN THE ROOM, facing you.
  def a_floor_with_a_boss(at:)
    @programs ||= {}
    @programs[at] ||= program_of(with_things({ [at, ROW] => Enemy[:hans].standing }))
  end

  def program_of(level)
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Guards.new(level)
    scenery = Wolf3D::Scenery.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, palette, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, palette,
                                    (guards.pictures + scenery.pictures +
                                     Wolf3D::Pickups.pictures(guards)).uniq.sort)

    RubyGBA.game("BOSSES", code: "ZBOS", maker: "01") do
      screen :bitmap, tear_free: true
      view = FP.new(build: self, level: level, atlas: atlas, doors: doors, pushwalls: pushwalls,
                    guards: guards, things: things, scenery: scenery, startable: true)
      game_loop { view.update }
    end.program
  end

  # Stand and empty the pistol into him. +then_walk+ walks forward afterwards, over whatever he
  # left. He is drawn, because a shot goes to a man the view put on the screen.
  ONE = (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

  # ENOUGH SPRITES TO REACH THE LAST PICTURE A BOSS CAN WEAR, plus the weapons a release keeps
  # last. Gretel's run sits a long way up — four bosses this cartridge does not build yet stand
  # between her and Hans — so a fixture for a boss is a good deal bigger than one for a guard.
  SPRITES = Enemy::ALL.flat_map(&:pictures).max + 1 + Wolf3D::WeaponAtlas::COUNT

  def fixture = @fixture ||= Release.new(sprites: SPRITES)
  def vswap = @vswap ||= Wolf3D::Vswap.new(fixture.files["VSWAP"])
  def palette = Wolf3D::Palette.game

  def pool_field(run, field, slot = 0)
    run.instance_variable_get(:@lists)[:"__pool_guard_#{field}"].get(slot)
  end

  def live_slots(run)
    lists = run.instance_variable_get(:@lists)
    (0...lists[:__pool_guard_active].length).select { |n| lists[:__pool_guard_active].get(n) == 1 }
  end

  def nearest(run) = live_slots(run).min_by { |slot| pool_field(run, :x, slot) } || 0
  def hp(run) = pool_field(run, :hp, nearest(run))
  def where(run) = pool_field(run, :x, nearest(run)) / ONE
  def dropped(run) = live_slots(run).map { |slot| pool_field(run, :dropped, slot) }

  def with_things(things)
    cells = Array.new(SIDE * SIDE, FLOOR)
    standing = Array.new(SIDE * SIDE, 0)
    SIDE.times do |y|
      SIDE.times do |x|
        cells[(y * SIDE) + x] = WALL if x.zero? || y.zero? || x == SIDE - 1 || y == SIDE - 1
      end
    end
    standing[(ROW * SIDE) + PLAYER_X] = Wolf3D::Level::FACINGS.key(:east)
    things.each { |(x, y), code| standing[(y * SIDE) + x] = code }

    Wolf3D::Level.new(name: "Bosses", width: SIDE, height: SIDE, walls: cells, things: standing)
  end
end
