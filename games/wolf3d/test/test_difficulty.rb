# frozen_string_literal: true

require_relative "test_helper"

# HOW TOUGH YOU SAID YOU WERE, and what a game does with the answer.
#
# The setting decides exactly two things and this holds it to both. It decides WHICH GUARDS ARE
# THERE — the same floor stands up ten men or thirty-two — and it decides WHAT A SHOT TAKES OFF
# YOU, on the easiest setting alone. Everything else about a guard is the same on all four.
#
# EVERY QUESTION HERE IS ASKED OF A GAME BEING PLAYED rather than of the reader, because the
# whole point of the change is that the answer is no longer settled while the cartridge is
# built: the cartridge carries every setting's guards and picks between them when a floor
# starts. Guards' own reading of the level is held to its own tests in test_guards.rb.
class TestDifficulty < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Guards = Wolf3D::Guards
  Release = Wolf3D::Fixture::Release

  SIDE = 16
  FLOOR = Wolf3D::Level::FLOOR
  WALL = Release::WALL

  # THREE GUARDS, ONE FROM EACH BLOCK, standing in a row so which of them stood up is a list of
  # places rather than a count. The one at 10 is on every game, the one at 12 from the middle
  # setting up, the one at 14 only on the hardest.
  EVERY_GAME = 10
  FROM_MEDIUM = 12
  HARDEST_ONLY = 14

  def one_of_each_block
    arena(things: { [EVERY_GAME, 4] => Guards::STANDING,
                    [FROM_MEDIUM, 4] => Guards::STANDING + Guards::HARDER,
                    [HARDEST_ONLY, 4] => Guards::STANDING + (Guards::HARDER * 2) })
  end

  # WHO REALLY STOOD UP, read off the game rather than off the level: every live slot of the
  # pool, by the cell he is standing in. A pool hands out its slots from the back, so this is
  # sorted — the order they are stored in is not something to depend on.
  def standing_up(run)
    pool = run.instance_variable_get(:@lists)
    active = pool[:__pool_guard_active]
    xs = pool[:__pool_guard_x]
    (0...active.length).select { |slot| active.get(slot) == 1 }
                       .map { |slot| (xs.get(slot) / ONE).floor }
                       .sort
  end

  # ---------------------------------------------------------------- which guards are there

  # THE CARTRIDGE CARRIES ALL OF THEM AND THE GAME PICKS. One build, played four ways: the same
  # floor, set four ways, stands up four different sets of men.
  def test_a_floor_stands_up_the_guards_its_setting_names
    expected = { baby: [EVERY_GAME],
                 easy: [EVERY_GAME],
                 medium: [EVERY_GAME, FROM_MEDIUM],
                 hard: [EVERY_GAME, FROM_MEDIUM, HARDEST_ONLY] }

    Guards::SETTINGS.each do |how|
      assert_equal expected.fetch(how), standing_up(started_at(how)),
                   "a #{how} game should stand up #{expected.fetch(how).length} of the three"
    end
  end

  # ...AND THE SETTING IS READ WHEN THE FLOOR STARTS, not when the cartridge was built. One
  # program, one run: the floor is started at the easiest setting, then at the hardest, and the
  # men on it change without anything being rebuilt.
  def test_changing_the_setting_changes_who_is_there_on_the_next_floor
    program = a_floor_started_at_each_setting(one_of_each_block)
    baby = Reference.new.run(program, frames: settled(:baby))
    hard = Reference.new.run(program, frames: settled(:hard))

    assert_equal [EVERY_GAME], standing_up(baby)
    assert_equal [EVERY_GAME, FROM_MEDIUM, HARDEST_ONLY], standing_up(hard)
  end

  # A guard the setting leaves out is not a hidden one — he is never spawned at all, so he costs
  # a frame nothing. The pool's own count is what the game's per-frame walk is charged for.
  def test_a_guard_his_setting_leaves_out_takes_up_no_slot
    assert_equal 1, started_at(:baby)[:__pool_guard_count]
    assert_equal 3, started_at(:hard)[:__pool_guard_count]
  end

  # THE TWO EASIEST SETTINGS AGREE ABOUT THE GUARDS, which is the half of the original's rule
  # that is easy to get wrong: the second setting brings in nothing at all, and only the two
  # above it add anybody.
  def test_the_two_easiest_settings_hold_the_same_guards
    assert_equal standing_up(started_at(:baby)), standing_up(started_at(:easy))
  end

  # ---------------------------------------------------------------- what a shot takes off you

  # THE EASIEST SETTING TAKES A QUARTER OF WHAT A SHOT WOULD TAKE. Stand in front of a guard and
  # do nothing while he fires; the same program, set two ways, loses very different amounts.
  #
  # The two runs draw the same random numbers in the same order — nothing about the setting
  # changes what is asked of the stream — so the wounds are the same wounds and the only
  # difference is the quarter. What the quarter is taken of is each wound on its own, so the
  # total comes out a little under a quarter rather than exactly one: a fraction is dropped
  # every time, and that is what the second bound below allows for.
  def test_the_easiest_setting_takes_a_quarter_of_what_a_shot_takes
    gentle = health_lost_at(:baby)
    ordinary = health_lost_at(:easy)

    assert_operator gentle, :>, 0, "he should still be hurting you on the easiest setting"
    assert_operator gentle, :<=, ordinary / 4,
                    "the easiest setting takes at most a quarter"
    assert_operator gentle, :>, ordinary / 8,
                    "...and not less than that, give or take the fractions dropped"
  end

  # ...AND IT IS THE EASIEST SETTING ALONE. "Don't hurt me" hurts you exactly as much as "I am
  # Death incarnate" does, which is the part of the original's rule nobody would guess: the two
  # easiest settings agree about every OTHER thing the setting decides.
  def test_every_other_setting_takes_the_whole_of_it
    ordinary = health_lost_at(:easy)

    assert_operator ordinary, :>, 0, "the guard has to land something for this to mean anything"
    assert_equal ordinary, health_lost_at(:medium), "the middle setting hurts as much as easy"
    assert_equal ordinary, health_lost_at(:hard), "and so does the hardest"
  end

  private

  def fixture = @fixture ||= Release.new
  def vswap = @vswap ||= Wolf3D::Vswap.new(fixture.files["VSWAP"])
  def palette = Wolf3D::Palette.game

  ONE = (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

  # HOW LONG TO PLAY BEFORE READING, for the program that walks the four settings in turn: far
  # enough in for the setting to have been written and the floor started again on it.
  APART = 4

  def settled(how) = ((Guards.number_of(how) + 1) * APART) + 1

  # The floor as a game set +how+ really finds it.
  def started_at(how)
    Reference.new.run(a_floor_started_at_each_setting(one_of_each_block), frames: settled(how))
  end

  # ONE PROGRAM THAT PLAYS EVERY SETTING IN TURN. It writes a setting, starts the floor on it,
  # and does it again a few passes later for the next one — so reading the four is four runs of
  # one build rather than four builds, and the setting is plainly being read at run time.
  def a_floor_started_at_each_setting(level)
    view_of(level) do |b, view|
      passes = b.var :passes, 0
      b.game_loop do
        view.play
        passes.add 1
        Guards::SETTINGS.each_with_index do |_, n|
          (passes == (n + 1) * APART).then do
            view.difficulty.set n
            b.call :start_the_floor
          end
        end
      end
    end
  end

  # Stand in front of a guard, do nothing, and see what he takes off you. He is put close and
  # facing away, which is the shape the other tests use to get shot at quickly.
  def health_lost_at(how)
    program = view_of(arena(guards: [[11, 8, :west]])) do |b, view|
      view.difficulty.set Guards.number_of(how)
      b.game_loop { view.play }
    end
    FP::START_HEALTH - Reference.new.run(program, frames: 400)[:health]
  end

  # A GAME OF ONE FLOOR, with the loop left to the caller so a test can set the difficulty and
  # start the floor over. Nothing is drawn: every question here is about who is standing on the
  # floor and what they have done to you, and drawing costs about a hundred times playing.
  def view_of(level, &loop_body)
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Guards.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, palette, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, palette, guards.pictures)

    RubyGBA.game("HOWTOUGH", code: "ZDIF", maker: "01") do
      screen :bitmap, tear_free: true
      view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas, doors: doors,
                                     pushwalls: pushwalls, guards: guards, things: things,
                                     startable: true)
      loop_body.call(self, view)
    end.program
  end

  def arena(player: [8, 8], facing: :east, guards: [], things: {})
    cells = Array.new(SIDE * SIDE, FLOOR)
    standing = Array.new(SIDE * SIDE, 0)
    SIDE.times do |y|
      SIDE.times do |x|
        cells[(y * SIDE) + x] = WALL if x.zero? || y.zero? || x == SIDE - 1 || y == SIDE - 1
      end
    end
    standing[(player[1] * SIDE) + player[0]] = Wolf3D::Level::FACINGS.key(facing)
    guards.each { |x, y, way| standing[(y * SIDE) + x] = Guards::STANDING + Guards::FACINGS.index(way) }
    things.each { |(x, y), code| standing[(y * SIDE) + x] = code }

    Wolf3D::Level.new(name: "Arena", width: SIDE, height: SIDE, walls: cells, things: standing)
  end
end
