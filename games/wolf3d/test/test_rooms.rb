# frozen_string_literal: true

require_relative "test_helper"

# WHICH ROOMS ARE OPEN TO THE PLAYER'S, and what a guard outside them does about it.
#
# A guard's think is nearly all the line of sight he walks toward you, and it used to be walked
# from wherever he stood. The original refuses to think for a guard whose room is shut off from
# yours, and thinks for one who has been SEEN wherever he stands. These are the tests of both
# halves, and they are about a guard MOVING or not moving rather than about the machinery: a
# guard who does not think does not patrol, and a patrolling guard who does not move has not
# thought.
class TestRooms < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Guards = Wolf3D::Guards
  Rooms = Wolf3D::Rooms
  Release = Wolf3D::Fixture::Release

  SIDE = 16
  FLOOR = Wolf3D::Level::FLOOR
  WALL = Release::WALL
  ONE = (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

  # Long enough for a patrolling guard to have gone somewhere.
  FRAMES = 90

  # WHERE THE HOLE IN THE WALL IS, and it is on the eye line at y=8 while the door is up at y=3 —
  # so a guard seen through it is seen through no door at all, and his room stays shut off.
  ARCHWAY = [7, 8].freeze
  FAR_DOOR = [7, 3].freeze

  # TWO ROOMS SIDE BY SIDE with a wall between them, and the wall has a door in it. The rooms
  # carry different floor codes, which is how the game says they are different rooms: a floor
  # cell's code is 107 plus the room it belongs to.
  #
  # +archway+ knocks a hole in the wall that is NOT a door. You can walk through it and see
  # through it, and the two rooms are still not joined — rooms are joined by doors and by nothing
  # else. That is the case the "he has been seen" half exists for.
  def two_rooms(player: [3, 8], guards: [], archway: nil, door: [7, 8], scenery: {})
    cells = Array.new(SIDE * SIDE, WALL)
    things = Array.new(SIDE * SIDE, 0)
    (1..SIDE - 2).each do |y|
      (1..6).each { |x| cells[(y * SIDE) + x] = FLOOR }
      (8..SIDE - 2).each { |x| cells[(y * SIDE) + x] = FLOOR + 1 }
    end
    cells[(door[1] * SIDE) + door[0]] = Wolf3D::Level::DOORS.first if door
    # An archway belongs to the room the player is in, so the far room stays a room of its own.
    cells[(archway[1] * SIDE) + archway[0]] = FLOOR if archway

    things[(player[1] * SIDE) + player[0]] = Wolf3D::Level::FACINGS.key(:east)
    guards.each do |x, y, way|
      things[(y * SIDE) + x] = Guards::PATROLLING + Guards::FACINGS.index(way)
    end
    scenery.each { |(x, y), code| things[(y * SIDE) + x] = code }

    Wolf3D::Level.new(name: "Two rooms", width: SIDE, height: SIDE, walls: cells, things: things)
  end

  def fixture = @fixture ||= Release.new
  def vswap = @vswap ||= Wolf3D::Vswap.new(fixture.files["VSWAP"])

  # +drawing+ decides whether the picture is made at all, and it is the whole of what separates
  # the two halves: a guard is only ever woken by being drawn, so a game that draws nothing can
  # wake nobody and shows the room rule on its own.
  def game(level, drawing: false)
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Guards.new(level)
    scenery = Wolf3D::Scenery.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, Wolf3D::Palette.game, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, Wolf3D::Palette.game,
                                    (guards.pictures + scenery.pictures).uniq.sort)

    RubyGBA.game("ROOMS", code: "ZROO", maker: "01") do
      screen :bitmap, tear_free: true
      view = FP.new(build: self, level: level, atlas: atlas, doors: doors, scenery: scenery,
                    pushwalls: pushwalls, guards: guards, things: things)
      game_loop { drawing ? view.update : view.play }
    end.program
  end

  # Which strips across the eye line are showing a piece of scenery's own flat colour. The
  # fixture paints each picture one flat colour of its own, so this is "is it on the screen".
  def columns_of(run, code)
    picture = Wolf3D::Scenery::FIRST_PICTURE +
              Wolf3D::Scenery::PICTURES.fetch(code - Wolf3D::Scenery::FIRST_CODE)
    ink = Wolf3D::Palette.game[Release::SPRITE_INK + picture]
    (0...240).select { |x| run.screen.pixel(x, FP::HORIZON) == ink }
  end

  def watch(level, drawing: false, frames: FRAMES, keys: [])
    Reference.new.input_each_frame { keys }.run(game(level, drawing: drawing), frames: frames)
  end

  def pool(run, field, slot = 0) = run.instance_variable_get(:@lists)[:"__pool_guard_#{field}"].get(slot)
  def guard_at(run, slot = 0) = [pool(run, :x, slot) / ONE, pool(run, :y, slot) / ONE]
  def room_open(run, room) = run.instance_variable_get(:@lists)[:room_open].get(room)

  # --- is it built at all ---

  def test_a_level_of_one_room_needs_none_of_it
    one_room = Wolf3D::Level.new(name: "One", width: SIDE, height: SIDE,
                                 walls: Array.new(SIDE * SIDE, FLOOR),
                                 things: Array.new(SIDE * SIDE, 0))

    refute Rooms.needed?(Wolf3D::Floors.of(level: one_room,
                                           doors: Wolf3D::Doors.new(one_room, vswap),
                                           pushwalls: Wolf3D::Pushwalls.new(one_room)))
  end

  # Two rooms and no door between them can never be joined, so there is nothing to work out.
  def test_two_rooms_with_no_door_anywhere_need_none_of_it
    level = two_rooms(door: nil, archway: ARCHWAY)

    refute Rooms.needed?(Wolf3D::Floors.of(level: level,
                                           doors: Wolf3D::Doors.new(level, vswap),
                                           pushwalls: Wolf3D::Pushwalls.new(level)))
  end

  def test_two_rooms_with_a_door_between_them_need_it
    level = two_rooms

    assert Rooms.needed?(Wolf3D::Floors.of(level: level,
                                           doors: Wolf3D::Doors.new(level, vswap),
                                           pushwalls: Wolf3D::Pushwalls.new(level)))
  end

  # --- which rooms are open ---

  def test_the_room_you_stand_in_is_open_and_the_one_behind_a_shut_door_is_not
    run = watch(two_rooms(guards: [[10, 8, :east]]))

    assert_equal 1, room_open(run, 1), "the room the player is in — stored one higher, so room 0 is 1"
    assert_equal 0, room_open(run, 2), "and the one behind the shut door is not"
  end

  # Nowhere in particular — a wall, a doorway, one of the ambush cells — is always open, so
  # anything standing on such a cell is never frozen by this.
  def test_nowhere_in_particular_is_always_open
    assert_equal 1, room_open(watch(two_rooms(guards: [[10, 8, :east]])), Rooms::NOWHERE)
  end

  # --- what a guard does about it ---

  def test_a_patrolling_guard_in_your_own_room_walks
    run = watch(two_rooms(player: [2, 8], guards: [[5, 8, :east]]))

    refute_in_delta 5.5, guard_at(run).first, 0.05, "he should have walked"
  end

  # THE POINT OF THE WHOLE THING: the same guard, the same patrol, one room further over with a
  # shut door in between — and he does not move at all, because he never thinks.
  def test_a_patrolling_guard_behind_a_shut_door_does_not_move
    run = watch(two_rooms(guards: [[10, 8, :east]]))

    assert_equal [10.5, 8.5], guard_at(run), "he has not thought, so he has not walked"
  end

  # ...and he is not frozen for ever: open the door and the two rooms are one as far as this is
  # concerned. The player stands at the door and presses to open it.
  def test_opening_the_door_sets_the_far_room_thinking
    level = two_rooms(player: [6, 8], guards: [[10, 12, :east]])
    shut = watch(level, frames: 6)
    opened = Reference.new.input_each_frame { |f| f == 2 ? [:a] : [] }
                      .run(game(level), frames: FRAMES)

    assert_equal 0, room_open(shut, 2), "shut to begin with"
    assert_equal 1, room_open(opened, 2), "and open once the door is"
    refute_equal [10.5, 12.5], guard_at(opened), "so he thinks, and walks"
  end

  # --- and the half that is not about rooms at all ---

  # A guard across an archway is in a room of his own that no door joins, so the rule above would
  # freeze him — while the player stands looking straight at him. Being drawn is what saves him,
  # and it is the original's own rule.
  def test_a_guard_you_can_see_walks_even_though_his_room_is_shut_off
    level = two_rooms(player: [3, 8], guards: [[10, 8, :east]], archway: ARCHWAY, door: FAR_DOOR)
    seen = watch(level, drawing: true)
    unseen = watch(level, drawing: false)

    assert_equal 0, room_open(seen, 2), "his room is joined by no door, so it is never open"
    assert_equal 1, pool(seen, :awake), "but he has been on the screen"
    refute_equal [10.5, 8.5], guard_at(seen), "so he thinks, and walks"
    assert_equal [10.5, 8.5], guard_at(unseen), "and with nothing drawn, nobody sees him and he waits"
  end

  # --- and the same question asked by everything standing in the rooms ---

  # A piece of scenery does not move, so which room it is in was settled while the cartridge was
  # built and the whole of its per-frame question is a table read. Walking every piece on the
  # floor and working out where each lands on the screen is what made the later floors slow.
  BARREL = Wolf3D::Scenery::FIRST_CODE + 1

  def test_a_barrel_in_your_own_room_is_drawn
    run = watch(two_rooms(player: [2, 8], scenery: { [5, 8] => BARREL }), drawing: true, frames: 2)

    refute_empty columns_of(run, BARREL), "it is in the room with you"
  end

  # THE SAVING: it is in another room, behind a shut door, so it is never even looked at.
  def test_a_barrel_behind_a_shut_door_is_not_looked_at
    run = watch(two_rooms(player: [3, 8], scenery: { [10, 8] => BARREL }), drawing: true, frames: 2)

    assert_empty columns_of(run, BARREL)
    assert_equal 0, run[:_seen], "nothing was even queued to draw"
  end

  # AND THE PROMISE THAT MAKES THE SAVING SAFE: open the door and it is there. A gate that hid
  # something you can see would be a bug you could look straight at.
  def test_a_barrel_through_an_OPEN_door_is_drawn
    level = two_rooms(player: [6, 8], scenery: { [10, 8] => BARREL })
    opened = Reference.new.input_each_frame { |f| f == 2 ? [:a] : [] }
                      .run(game(level, drawing: true), frames: 40)

    assert_equal 1, room_open(opened, 2), "the door joined the rooms"
    refute_empty columns_of(opened, BARREL), "so the barrel down the corridor shows"
  end

  # WALKING INTO A ROOM OPENS IT, WITH NO DOOR INVOLVED AT ALL. The sweep is only run on a frame
  # where the answer can have moved, and one of the two things that moves it is the player
  # changing room. A door moving is the other and is the obvious one; this is the case that has
  # no door in it, so nothing else can stand in for the test.
  #
  # An ARCHWAY is how a room is entered without a door: it is a hole in the wall, you can walk
  # through it, and the fill spreads through doors and through nothing else — so the far room is
  # shut off right up until the player is standing IN it. A version that only noticed doors would
  # leave it shut off after that too, and the barrel two steps in front of you would not be drawn.
  def test_walking_through_an_archway_opens_the_room_you_walk_into
    # The door is put out of the way at the far end and never touched, so it is there to make the
    # room machinery exist and takes no part in what is being asked.
    level = two_rooms(player: [6, 8], archway: ARCHWAY, door: FAR_DOOR,
                      scenery: { [10, 8] => BARREL })
    walked = Reference.new.input_each_frame { [:up] }.run(game(level, drawing: true), frames: 90)

    assert_operator walked[:px] / ONE, :>, 8.0, "the player walked through the archway"
    assert_equal 1, room_open(walked, 2), "so the room they walked into is open"
    refute_empty columns_of(walked, BARREL), "and the barrel standing in it is drawn"
  end

  # STANDING IN THE DOORWAY ITSELF is the case that catches a careless version of this: a doorway
  # belongs to no room, so reading the player's room fresh each frame says "nowhere" and every
  # piece of scenery in the level blinks out for the two steps it takes to walk through.
  def test_walking_through_the_doorway_does_not_blank_the_room_behind_you
    level = two_rooms(player: [6, 8], scenery: { [3, 8] => BARREL })
    walked = Reference.new.input_each_frame { |f| f < 3 ? [:a] : [:up] }
                      .run(game(level, drawing: true), frames: 90)

    assert_operator walked[:px] / ONE, :>, 7.0, "the player is past the doorway"
    assert_equal 1, room_open(walked, 1), "and the room they came out of is still open"
  end

  # Once awake he stays awake, which is what stops a guard flickering in and out of thinking as
  # he walks behind a pillar. Turn right round and he is still going.
  def test_a_guard_once_seen_stays_awake_after_you_look_away
    level = two_rooms(player: [3, 8], guards: [[10, 8, :east]], archway: ARCHWAY, door: FAR_DOOR)
    away = Reference.new.input_each_frame { |f| f < 40 ? [] : [:left] }
                    .run(game(level, drawing: true), frames: 160)

    assert_equal 1, pool(away, :awake), "still awake with his room behind you"
  end
end
