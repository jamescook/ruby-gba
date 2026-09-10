# frozen_string_literal: true

require_relative "test_helper"

# WHAT A GUARD HEARS. Until this, a guard noticed you by sight and by nothing else: fire a pistol
# in a room full of men with their backs to you and not one of them turned round.
#
# The original keeps one flag for it — `madenoise`, "true when shooting or screaming" — set where
# a gun goes off and where a man is hit, cleared once a tic, and read in the one line that lets a
# guard look your way without having to see you first. Everything here is that line's behaviour.
class TestHearing < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Guards = Wolf3D::Guards
  Weapons = Wolf3D::Weapons
  Release = Wolf3D::Fixture::Release

  SIDE = 16
  FLOOR = Wolf3D::Level::FLOOR
  WALL = Release::WALL
  AMBUSH = Wolf3D::Level::AMBUSH

  STANDING = Guards.state_number(:stand)

  # WHERE THE PLAYER STANDS, facing east, and where a guard goes to be OUT OF THE SIGHTS: far
  # enough to the side that a shot can never be about him, so anything that wakes him is
  # something he heard rather than something that hit him. A shot is aimed within about an eighth
  # of the distance either side; three cells off at four cells away is nowhere near it.
  PLAYER = [8, 8].freeze
  LISTENER = [12, 4].freeze

  # ...and where one goes to be shot AT: dead ahead. Near enough to touch, or a room away.
  UNDER_THE_KNIFE = [9, 8].freeze
  OUT_OF_REACH = [12, 8].freeze

  # --- a gun --------------------------------------------------------------------------

  # A GUNSHOT TURNS A MAN WHO COULD NOT SEE YOU. He has his back to you, he is off to one side so
  # the shot was never about him, and he still comes.
  def test_a_gunshot_turns_a_guard_who_could_not_see_you
    quiet = play(guards: [[*LISTENER, :east]], firing: false)
    shot = play(guards: [[*LISTENER, :east]], firing: true)

    assert_equal 1, still_standing(quiet, 1), "with nothing to hear he stands where he was put"
    assert_equal 0, still_standing(shot, 1), "and a gunshot brings him"
  end

  # EVERY MAN ON THE FLOOR HEARS IT, and not half of them. Guards think on alternate passes, so a
  # noise that stood for one pass would reach whichever half happened to be thinking — a coin
  # toss nobody could see. Four with their backs turned, and all four come.
  def test_a_gunshot_turns_every_man_in_the_room_and_not_half_of_them
    backs_turned = (3..6).map { |y| [LISTENER.first, y, :east] }
    shot = play(guards: backs_turned, firing: true)

    assert_equal 0, still_standing(shot, backs_turned.length),
                 "every one of the four should have heard it"
  end

  # --- a knife ------------------------------------------------------------------------

  # A KNIFE THAT MEETS NOTHING IS SILENT, which is the tactic the whole flag is worth having for:
  # the man ahead is a room away, so the swing reaches nobody, and the man to the side hears
  # nothing. The same swing with a gun in your hands brings him (above).
  def test_a_knife_that_meets_nothing_is_silent
    swung = play(guards: [[*LISTENER, :east], [*OUT_OF_REACH, :east]], firing: true, knife: true)

    assert_equal 2, still_standing(swung, 2), "a swing at thin air is not a noise"
  end

  # ...AND ONE THAT LANDS IS HEARD, because what makes the noise is the man crying out. That is
  # where the original sets its flag too — in the damage, not in the weapon — and it is why the
  # knife is silent only while it misses.
  def test_a_knife_that_lands_is_heard_across_the_room
    stuck = play(guards: [[*LISTENER, :east], [*UNDER_THE_KNIFE, :east]],
                 firing: true, knife: true)

    assert_equal 0, still_standing(stuck, 2),
                 "the man you knifed cried out, and the man across the room heard it"
  end

  # --- who does not hear it -----------------------------------------------------------

  # A GUARD LYING IN WAIT HEARS NOTHING. That is what the ambush tile is for — the man behind the
  # door meant to catch you walking past — and a gunshot two rooms away giving him away would be
  # the end of him. His neighbour, on ordinary floor, comes.
  def test_a_guard_lying_in_wait_is_not_brought_by_a_gunshot
    beside = [LISTENER.first, LISTENER.last + 1]
    shot = play(guards: [[*LISTENER, :east], [*beside, :east]],
                ambush: [LISTENER], firing: true)
    waiting, ordinary = guards_in(shot, 2).partition { |g| g[:ambush] }

    assert waiting.first[:standing], "the man lying in wait must SEE you"
    refute ordinary.first[:standing], "where the man beside him only had to hear you"
  end

  # A NOISE CARRIES AS FAR AS AN OPEN DOOR AND NO FURTHER, which is the original's own scoping and
  # is not a distance: the rooms a shut door closes off do not hear it. Both men here have their
  # backs turned and neither can see a thing; the one sharing your room comes and the one behind
  # the wall does not.
  #
  # THE FAR MAN IS IN PLAIN SIGHT THROUGH AN ARCHWAY, and that is the whole of what makes this
  # test bite. A hole in a wall is not a door, so the two rooms are still not joined — but he can
  # be SEEN through it, and a man who has been seen once thinks for ever after wherever he
  # stands. Without an archway he would not be thinking at all, and would stay standing whether
  # the noise was scoped or not: the test would pass for the wrong reason, which it did until
  # this was measured by breaking the scoping and watching it stay green.
  def test_a_noise_does_not_carry_into_a_room_a_shut_door_closes_off
    shot = watch_two_rooms(firing: true)
    left = guards_in(shot, 2).select { |g| g[:standing] }

    assert_equal 1, left.length, "one of the two should have heard it and one should not"
    # The wall between the rooms runs down x = 7, and the man who never moved is still where he
    # was put — so which side of it he is on says which of them stayed.
    assert_operator left.first[:x], :>, 7, "the one left standing is the one behind the wall"
  end

  # --- how long it lasts --------------------------------------------------------------

  # LONG ENOUGH FOR EVERY GUARD TO HAVE THOUGHT ONCE, and not a pass longer — which is what stops
  # one shot rousing the floor a man at a time for ever. The original clears its flag at the top
  # of every tic and every actor thinks on every tic; here they think on alternate passes, so the
  # same thing takes two.
  def test_the_noise_runs_out_once_every_guard_has_had_a_chance_to_hear_it
    made = (0..(Weapons::CYCLE + 4)).map { |passes| noise_after(passes) }
    loud = made.each_index.select { |n| made[n].positive? }

    assert_equal FP::HEARD_FOR, loud.length,
                 "the noise should stand on exactly #{FP::HEARD_FOR} passes, not #{loud.inspect}"
    assert_equal loud.first + FP::HEARD_FOR - 1, loud.last, "and on consecutive ones"
    assert_equal 0, made.last, "long forgotten by the end of the weapon's cycle"
  end

  # --- and on the console --------------------------------------------------------------

  # THE CARTRIDGE HEARS WHAT THE ORACLE HEARS. What can be read back off a running cartridge is
  # its variables, and the flag is one — the guard's own state is a pool field and lives in a
  # list, which nothing outside the game can name. So this holds the flag itself against the
  # oracle, on the pass a round leaves the barrel.
  def test_the_console_makes_the_same_noise_the_interpreter_makes
    program = game(arena(guards: [[*LISTENER, :east]]), drawing: true)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "NOISE", code: "ZNOI", maker: "01")

    passes = shot_lands_on
    oracle = Reference.new.input_each_frame { |f| tapping(f) }
                     .run(program, frames: passes + 1)
    console = RubyGBA::Verifier.new(rom, frames: (passes + 1) * 3,
                                         keys: ->(f) { f == 3 ? RubyGBA::Constants::KEY_B : 0 },
                                         vars: backend.var_addresses)

    assert_operator oracle[:noise], :>, 0, "the oracle should be mid-noise on this pass"
    assert_equal oracle[:ammo], console.var(:ammo), "and both should have spent the round"
  end

  private

  def fixture = @fixture ||= Release.new
  def vswap = @vswap ||= Wolf3D::Vswap.new(fixture.files["VSWAP"])
  def palette = Wolf3D::Palette.game

  # Which pass a round leaves the barrel on, counting from the tap: the gun comes up for one
  # stage and fires at the end of the second. See Weapons.
  def shot_lands_on = (Weapons::STAGE_PASSES * 2) + 1

  # Long enough for a man who heard it to have finished reacting and set off. The reaction is up
  # to about a second, counted down on the passes he thinks, which is every other one.
  REACTED = 140

  ONE = (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

  # EVERY GUARD ON THE FLOOR, as the three things these tests ask about him. Read by slot and
  # then picked apart by what he IS, because the order a pool hands out its slots is not the
  # order the level lists its men — so nothing here may name a man by number.
  def guards_in(run, count)
    lists = run.instance_variable_get(:@lists)
    (0...count).map do |slot|
      { x: (lists[:__pool_guard_x].get(slot) / ONE).round,
        ambush: lists[:__pool_guard_ambush].get(slot) == 1,
        standing: lists[:__pool_guard_state].get(slot) == STANDING }
    end
  end

  # ...and how many of them never moved, which is what nearly every test here counts. A man who
  # has been roused walks, so he cannot be found by where he was put — but a man who is STILL
  # STANDING is by definition where you left him.
  def still_standing(run, count) = guards_in(run, count).count { |g| g[:standing] }

  # Tap the trigger on pass 1 — the second, because a press is an edge and the first pass has no
  # pass before it for the button to have been up on. Change to the knife first if asked.
  def tapping(pass, knife: false)
    return [:select] if knife && pass == 1
    return [] if knife && pass < 4

    pass == (knife ? 4 : 1) ? [:b] : []
  end

  # A GUNSHOT IS HEARD WHETHER OR NOT IT HITS ANYTHING, so the questions about a gun need nothing
  # drawn. A KNIFE IS THE OTHER WAY ROUND: what makes its noise is the man crying out, so whether
  # it is heard turns on whether it LANDS — and a shot goes to a man the renderer put on the
  # screen, so a run with nothing drawn is one where a knife can never land at all.
  def play(firing:, knife: false, frames: REACTED, drawn: knife, **)
    Reference.new.input_each_frame { |f| firing ? tapping(f, knife: knife) : [] }
             .run(game(arena(**), drawing: drawn), frames: frames)
  end

  # ...and the two-room level is WATCHED rather than only played, because the far man has to be
  # drawn before he will think at all. See the test.
  def watch_two_rooms(firing:)
    Reference.new.input_each_frame { |f| firing ? tapping(f) : [] }
             .run(game(two_rooms, drawing: true), frames: REACTED)
  end

  def noise_after(passes)
    Reference.new.input_each_frame { |f| tapping(f) }
             .run(game(arena(guards: [[*LISTENER, :east]])), frames: passes + 1)[:noise]
  end

  # A WALLED FIELD, all one room, with the player facing east and whatever you name standing in
  # it. +ambush+ marks the cells that are ambush tiles, which is a thing about the FLOOR rather
  # than about the man on it.
  def arena(guards: [], ambush: [])
    cells = Array.new(SIDE * SIDE, FLOOR)
    things = Array.new(SIDE * SIDE, 0)
    SIDE.times do |y|
      SIDE.times do |x|
        cells[(y * SIDE) + x] = WALL if x.zero? || y.zero? || x == SIDE - 1 || y == SIDE - 1
      end
    end
    ambush.each { |x, y| cells[(y * SIDE) + x] = AMBUSH }
    things[(PLAYER[1] * SIDE) + PLAYER[0]] = Wolf3D::Level::FACINGS.key(:east)
    guards.each { |x, y, way| things[(y * SIDE) + x] = Guards::STANDING + Guards::FACINGS.index(way) }

    Wolf3D::Level.new(name: "Hearing", width: SIDE, height: SIDE, walls: cells, things: things)
  end

  # TWO ROOMS SIDE BY SIDE with a wall between them, which is how the game says two places are
  # different rooms: a floor cell's code is 107 plus the room it belongs to. A guard with his
  # back turned in each, and the player facing straight down the archway at the far one.
  #
  # THE DOOR IS UP IN A CORNER AND SHUT, so the rooms are never joined. THE ARCHWAY is a hole in
  # the wall on the eye line — you can see through it and walk through it, and it joins nothing,
  # because rooms are joined by doors and by nothing else. It belongs to the near room, so the
  # far one stays a room of its own.
  # It is a WIDE archway, and the far man stands off to one side of it, because a shot goes
  # straight down the middle of the view: a man in plain sight dead ahead is a man who gets shot,
  # and being shot rouses him whatever he can hear. Off to the side he is still drawn — the view
  # is sixty-odd degrees across — and no shot can be about him.
  ARCHWAY = (6..10).freeze
  SHUT_DOOR = [7, 3].freeze
  IN_YOUR_ROOM = [5, 5].freeze
  BEHIND_THE_WALL = [10, 11].freeze

  def two_rooms
    cells = Array.new(SIDE * SIDE, WALL)
    things = Array.new(SIDE * SIDE, 0)
    (1..SIDE - 2).each do |y|
      (1..6).each { |x| cells[(y * SIDE) + x] = FLOOR }
      (8..SIDE - 2).each { |x| cells[(y * SIDE) + x] = FLOOR + 1 }
    end
    cells[(SHUT_DOOR[1] * SIDE) + SHUT_DOOR[0]] = Wolf3D::Level::DOORS.first
    ARCHWAY.each { |y| cells[(y * SIDE) + 7] = FLOOR }

    things[(8 * SIDE) + 3] = Wolf3D::Level::FACINGS.key(:east)
    [IN_YOUR_ROOM, BEHIND_THE_WALL].each do |x, y|
      things[(y * SIDE) + x] = Guards::STANDING + Guards::FACINGS.index(:east)
    end
    Wolf3D::Level.new(name: "Two rooms", width: SIDE, height: SIDE, walls: cells, things: things)
  end

  # +drawing+ off is the whole picture skipped, and that is load-bearing rather than a saving: a
  # guard is woken by being ON THE SCREEN, so a game that draws nothing can wake nobody, and what
  # is left to rouse him is what these tests are about. The one test that builds a cartridge
  # turns it on, because a screen that is never drawn never names the colours it would have used.
  def game(level, drawing: false)
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Guards.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, palette, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, palette, guards.pictures)

    RubyGBA.game("NOISE", code: "ZNOI", maker: "01") do
      screen :bitmap, tear_free: true
      view = FP.new(build: self, level: level, atlas: atlas, doors: doors,
                    pushwalls: pushwalls, guards: guards, things: things)
      game_loop { drawing ? view.update : view.play }
    end.program
  end
end
