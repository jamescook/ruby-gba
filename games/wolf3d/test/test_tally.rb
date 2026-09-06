# frozen_string_literal: true

require_relative "test_helper"

# HOW MUCH OF A FLOOR HAS BEEN FOUND: its guards killed, its secret walls shoved, its treasures
# taken. Three counts the game keeps and three totals settled while building, which together are
# the percentages the original shows between floors.
#
# THEY BELONG TO THE FLOOR, not to the game, and that is the whole point of them being apart from
# the score: the score is kept across floors, these go back to nothing when a floor starts.
#
# Every rule asserted here was read out of Wolf4SDL rather than remembered, and one of them is a
# genuine surprise — see the one-up.
class TestTally < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Scenery = Wolf3D::Scenery
  Pickups = Wolf3D::Pickups
  Guards = Wolf3D::Guards
  Release = Wolf3D::Fixture::Release

  FLOOR = Wolf3D::Level::FLOOR
  WALL = Release::WALL
  SIDE = 16
  ROW = SIDE / 2
  START = 4

  # Where each piece sits in the original's own list of them.
  CLIP = Scenery::CLIP
  CROSS = 29
  CHALICE = 30
  ONE_UP = 33

  def cells(n) = ((n / FP::WALK).ceil + 4)

  def vswap = @vswap ||= Wolf3D::Vswap.new(Wolf3D::Fixture::Release.new.files["VSWAP"])
  def palette = Wolf3D::Palette.game
  def code(index) = Scenery::FIRST_CODE + index

  # A walled field with the player on the left of the middle row facing east, whatever you name
  # laid out in front of them, and optionally a secret wall to lean on.
  def arena(ahead: [], guards: [], secret: nil)
    cells = Array.new(SIDE * SIDE, FLOOR)
    standing = Array.new(SIDE * SIDE, 0)
    SIDE.times do |y|
      SIDE.times do |x|
        cells[(y * SIDE) + x] = WALL if x.zero? || y.zero? || x == SIDE - 1 || y == SIDE - 1
      end
    end
    standing[(ROW * SIDE) + START] = Wolf3D::Level::FACINGS.key(:east)
    ahead.each_with_index { |piece, n| standing[(ROW * SIDE) + START + 1 + n] = code(piece) }
    guards.each { |x, y, way| standing[(y * SIDE) + x] = Guards::STANDING + Guards::FACINGS.index(way) }
    if secret
      cells[(ROW * SIDE) + secret] = WALL
      standing[(ROW * SIDE) + secret] = Wolf3D::Level::PUSHWALL
    end
    Wolf3D::Level.new(name: "Tally", width: SIDE, height: SIDE, walls: cells, things: standing)
  end

  # Handed back so a test can ask the build-time totals as well as run the game.
  def view_of(level)
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Guards.new(level)
    scenery = Scenery.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, palette, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, palette,
                                    (guards.pictures + scenery.pictures +
                                     Pickups.pictures(guards)).uniq.sort)
    seen = nil
    program = RubyGBA.game("TALLY", code: "ZTAL", maker: "01") do
      screen :bitmap, tear_free: true
      seen = FP.new(build: self, level: level, atlas: atlas, doors: doors, pushwalls: pushwalls,
                    guards: guards, things: things, scenery: scenery)
      game_loop { seen.play }
    end.program
    [program, seen]
  end

  def walk_east(level, cells:)
    program, view = view_of(level)
    [Reference.new.input_each_frame { [:up] }.run(program, frames: cells(cells), max_steps: 8_000_000), view]
  end

  # --- what there was to find ---

  def test_the_totals_are_what_the_floor_holds
    _, view = view_of(arena(ahead: [CROSS, CHALICE, CLIP], guards: [[9, ROW, :west]], secret: 11))

    assert_equal 1, view.kill_total, "one guard on this floor"
    assert_equal 1, view.secret_total, "one wall that moves"
    assert_equal 2, view.treasure_total, "the cross and the chalice; a clip is not treasure"
  end

  # THE ONE-UP COUNTS AS A TREASURE, which looks wrong and is the original's own accounting: it
  # sits in the same arm of GetBonus as the cross, the chalice, the bible and the crown. Miss it
  # and a player who collected everything is told they found half of it.
  def test_a_one_up_counts_as_treasure
    _, view = view_of(arena(ahead: [CROSS, ONE_UP]))

    assert_equal 2, view.treasure_total
  end

  def test_a_floor_with_nothing_on_it_has_nothing_to_find
    _, view = view_of(arena)

    assert_equal 0, view.kill_total
    assert_equal 0, view.secret_total
    assert_equal 0, view.treasure_total
  end

  # --- what has been found ---

  def test_nothing_is_found_before_anything_happens
    run, = walk_east(arena(ahead: [CROSS], guards: [[9, ROW, :west]], secret: 11), cells: 0)

    assert_equal 0, run[:kills]
    assert_equal 0, run[:secrets]
    assert_equal 0, run[:treasures]
  end

  def test_walking_over_treasure_counts_it
    run, = walk_east(arena(ahead: [CROSS, CHALICE]), cells: 3)

    assert_equal 2, run[:treasures], "both of them"
    assert_operator run[:score], :>, 0, "and the score went up too, which is a separate thing"
  end

  # A clip changes the ammunition and nothing else. If treasure were counted by "anything taken"
  # this is the test that would fail.
  def test_walking_over_a_clip_is_not_treasure
    run, = walk_east(arena(ahead: [CLIP]), cells: 2)

    assert_equal 0, run[:treasures]
  end

  def test_taking_a_one_up_counts_as_treasure
    run, = walk_east(arena(ahead: [ONE_UP]), cells: 2)

    assert_equal 1, run[:treasures], "the original counts it with the cross and the crown"
  end

  # Lean on the secret wall ahead. The count goes up when the wall STARTS moving, once, however
  # long the button is held.
  # A run of its own each time: an interpreter carries the state of the run it just did, so two
  # runs off one would not be two readings of the same start.
  def shove(program, frames)
    Reference.new.input_each_frame { |f| f > 2 ? %i[up a] : [:up] }
             .run(program, frames: frames, max_steps: 8_000_000)
  end

  def test_shoving_a_secret_wall_counts_once
    program, = view_of(arena(secret: START + 1))

    early = shove(program, 20)
    later = shove(program, Wolf3D::Pushwalls::FRAMES_PER_CELL * 3)

    assert_equal 1, early[:secrets], "found the moment it moves"
    assert_equal 1, later[:secrets], "and leaning on it for longer does not find it twice"
  end

  def test_killing_a_guard_counts_it
    level = arena(guards: [[9, ROW, :west]])
    program, = view_of(level)
    run = Reference.new.input_each_frame { |f| (f / 2).even? ? [:b] : [] }
                   .run(program, frames: 120, max_steps: 12_000_000)

    assert_equal 1, run[:kills], "one guard down"
    assert_equal Guards::POINTS, run[:score], "and he was worth a hundred, which is separate"
  end
end
