# frozen_string_literal: true

require_relative "test_helper"

# THE LIFT AT THE END OF A FLOOR: the little room you step into and the lever you pull.
#
# Everything asserted here was read out of the original rather than remembered — the wall codes
# out of a real GAMEMAPS, the rules out of Wolf4SDL's Cmd_Use — because every one of them is the
# kind of number that is easy to half-remember and expensive to get wrong.
class TestElevator < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  EL = Wolf3D::Elevator

  SIDE = 16
  # The car, and the lever on the wall to its east — which is the only side of a car you can
  # actually use a lever on. See the facing test below.
  CAR_X = 8
  CAR_Y = 8
  LEVER_X = CAR_X + 1

  # Enough wall pictures that the lever (code 21) and the pulled lever (code 22) both have their
  # pair. A default fixture stops well short of that, because no other feature needs a code so
  # high.
  WALLS = (EL::PULLED * 2) + 2

  def setup
    @fixture = Wolf3D::Fixture::Release.new(walls: WALLS)
    @vswap = Wolf3D::Vswap.new(@fixture.files["VSWAP"])
  end

  # A room with a lift car in it, a lever on the car's east wall, and the player standing in the
  # car looking east at the lever. +secret+ puts the car on the code the original reserves for
  # the lift that goes somewhere other than the next floor.
  def room_with_a_lift(secret: false, facing: :east)
    cells = Array.new(SIDE * SIDE, Wolf3D::Level::FLOOR + 1)
    things = Array.new(SIDE * SIDE, 0)
    SIDE.times do |y|
      SIDE.times do |x|
        edge = x.zero? || y.zero? || x == SIDE - 1 || y == SIDE - 1
        cells[(y * SIDE) + x] = Wolf3D::Fixture::Release::WALL if edge
      end
    end
    cells[(CAR_Y * SIDE) + LEVER_X] = EL::SWITCH
    cells[(CAR_Y * SIDE) + CAR_X] = secret ? EL::SECRET_CAR : Wolf3D::Level::FLOOR + 1
    things[(CAR_Y * SIDE) + CAR_X] = Wolf3D::Level::FACINGS.key(facing)
    Wolf3D::Level.new(name: "Lift", width: SIDE, height: SIDE, walls: cells, things: things)
  end

  def program(level, drawing: true)
    doors = Wolf3D::Doors.new(level, @vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    lifts = Wolf3D::Elevator.new(level)
    atlas = Wolf3D::WallAtlas.new(@vswap, Wolf3D::Palette.game, level, doors: doors, lifts: lifts)

    RubyGBA.game("LIFT", code: "ZLFT", maker: "01") do
      screen :bitmap, tear_free: true
      view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas, doors: doors,
                                     pushwalls: pushwalls, lifts: lifts)
      game_loop { drawing ? view.update : view.play }
    end.program
  end

  # Press the use button on frame +press+ and run on for +frames+.
  def pull(level, frames:, press: 2, drawing: false)
    Reference.new.input_each_frame { |f| f == press ? [:a] : [] }
             .run(program(level, drawing: drawing), frames: frames)
  end

  # --- what the map says ---

  def test_a_lever_is_the_whole_of_what_a_lift_is
    lifts = Wolf3D::Elevator.new(room_with_a_lift)

    assert_equal 1, lifts.count, "one lever in this room"
    assert_equal 1, lifts.number_at(LEVER_X, CAR_Y), "and it is the first one"
    assert_nil lifts.number_at(CAR_X, CAR_Y), "the cell you stand on is not part of it"
  end

  # WHERE THE LIFT GOES is said by the cell you are STANDING on, not by the lever — the
  # original's own test, and the reason nothing here models a car. An ordinary one stands on an
  # area code like any other room; the secret one stands on the lowest floor code there is,
  # which across all ten floors of the first episode appears exactly once.
  def test_the_cell_you_stand_on_says_whether_the_lift_is_the_secret_one
    here = (CAR_Y * SIDE) + CAR_X

    assert_empty Wolf3D::Elevator.new(room_with_a_lift).secret_cars
    assert_equal [here], Wolf3D::Elevator.new(room_with_a_lift(secret: true)).secret_cars
  end

  def test_pulling_a_lever_off_the_secret_cell_says_so
    plain = pull(room_with_a_lift, frames: 4)
    secret = pull(room_with_a_lift(secret: true), frames: 4)

    assert_equal 0, plain[:lift_secret], "an ordinary lift goes to the next floor"
    assert_equal 1, secret[:lift_secret], "and this one does not"
  end

  # A floor can have no lift at all. The boss floor of every episode is exactly that: you finish
  # it by killing the boss.
  def test_a_floor_with_no_lever_has_no_lift
    plain = Wolf3D::Level.new(name: "None", width: SIDE, height: SIDE,
                              walls: Array.new(SIDE * SIDE, Wolf3D::Level::FLOOR + 1),
                              things: Array.new(SIDE * SIDE, 0))

    assert_predicate Wolf3D::Elevator.new(plain), :empty?
  end

  # --- what it does ---

  def test_pulling_the_lever_starts_the_lift
    run = pull(room_with_a_lift, frames: 4)

    assert_equal (CAR_Y * SIDE) + LEVER_X, run[:lift_pulled],
                 "the cell of the lever that was pulled, so only that one changes its picture"
    assert_operator run[:lift_wait], :>, 0, "and the lift is on its way"
  end

  # A lever you are facing NORTH or SOUTH at does nothing, which is the original's own rule
  # (Cmd_Use allows the lift on east and west only). It reads as a quirk and it is load-bearing:
  # it is why id could ship a blank picture for the lever's other face.
  def test_a_lever_does_nothing_unless_you_face_east_or_west
    facing_it = pull(room_with_a_lift(facing: :east), frames: 4)
    facing_away = pull(room_with_a_lift(facing: :north), frames: 4)

    assert_operator facing_it[:lift_wait], :>, 0, "east at the lever pulls it"
    assert_equal(-1, facing_away[:lift_pulled], "north at nothing does not")
    assert_equal 0, facing_away[:lift_wait]
  end

  # A lever already pulled ignores you. Both runs start the lift on the same frame; one then lets
  # go and the other leans on the button for the rest of the run, and they have to agree — a lift
  # that took the button again would keep topping its own count back up and never arrive.
  def test_leaning_on_the_button_does_not_restart_the_lift
    once = Reference.new.input_each_frame { |f| f == 1 ? [:a] : [] }
                    .run(program(room_with_a_lift), frames: 12)
    held = Reference.new.input_each_frame { |_f| [:a] }
                   .run(program(room_with_a_lift), frames: 12)

    assert_operator once[:lift_wait], :>, 0, "the run is short enough that it has not arrived"
    assert_equal once[:lift_wait], held[:lift_wait],
                 "a lift already on its way counts down whatever the button is doing"
  end

  # The wait is the length of the lift's own recording, because the original plays that sound and
  # then waits for it to finish before the floor ends. The fixture holds no such recording, so
  # this build falls back to the stated number — which is what that recording comes to anyway.
  def test_the_lift_takes_as_long_as_it_says_and_then_the_floor_starts_again
    during = pull(room_with_a_lift, frames: FP::LIFT_WAIT)
    after = pull(room_with_a_lift, frames: FP::LIFT_WAIT + 6)

    assert_operator during[:lift_wait], :>, 0, "still on its way"
    assert_equal(-1, after[:lift_pulled], "and then the floor has started again")
    assert_equal 0, after[:lift_wait]
  end

  # THE PICTURE CHANGES, which is the half no counter can show. The lever and the pulled lever
  # are different pictures in the game's own art, so the wall the player is looking at is not the
  # same wall it was a moment ago.
  def test_the_lever_wears_a_different_picture_once_it_is_pulled
    level = room_with_a_lift
    before = Reference.new.run(program(level, drawing: true), frames: 3)
    after = pull(level, frames: 8, drawing: true)

    middle = (0...FP::VIEW_H).map { |y| [before.screen.pixel(120, y), after.screen.pixel(120, y)] }
    changed = middle.count { |was, now| was != now }

    assert_operator changed, :>, 0,
                    "the wall down the middle of the view should not be the picture it was"
  end
end
