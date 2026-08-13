# frozen_string_literal: true

require_relative "test_helper"

# Doors, which are the first thing in this game that is not scenery.
#
# A DOOR IS NOT A WALL IN ITS CELL. Its panel stands across the MIDDLE of the cell, so there is
# half a cell of open space in front of it, and a ray has to carry on past the cell's edge to
# find out whether anything is there. Everything here is about that and about what the panel
# does over time.
class TestDoors < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson

  def setup
    @fixture = Wolf3D::Fixture::Release.new
    @level = Wolf3D::Maps.new(maphead: @fixture.files["MAPHEAD"],
                              gamemaps: @fixture.files["GAMEMAPS"])[0]
    @vswap = Wolf3D::Vswap.new(@fixture.files["VSWAP"])
    @doors = Wolf3D::Doors.new(@level, @vswap)
    @pushwalls = Wolf3D::Pushwalls.new(@level)
  end

  # The room's own door, the one the player can reach. The other is in the outer border.
  def room_door = @doors.doors.index { |door| door.y == 36 }

  def program
    atlas = Wolf3D::WallAtlas.new(@vswap, Wolf3D::Palette.game, @level, doors: @doors)
    level = @level
    doors = @doors
    pushwalls = @pushwalls

    RubyGBA.game("DOORS", code: "ZDRS", maker: "01") do
      screen :bitmap, tear_free: true
      view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas, doors: doors, pushwalls: pushwalls)
      game_loop { view.update }
    end.program
  end

  # Half a turn, so the player faces the door in the room's south wall.
  def about_turn = ((FP::TURN / 2) / FP::TURN_SPEED.to_f).ceil

  # Turn around, walk at the door, and press the open button once on +press+ if given.
  def walk_at_the_door(frames, press: nil)
    turn = about_turn
    Reference.new.input_each_frame do |f|
      next [:left] if f <= turn
      next %i[up a] if press && f == press

      [:up]
    end.run(program, frames: frames)
  end

  ONE = 1 << RubyGBA::Fraction::DEFAULT_BITS

  # How far open a door is, as the 0-to-1 the game writes. The list holds numbers with a
  # fraction, so what is stored is multiplied up.
  def door_open(run, index) = run.instance_variable_get(:@lists)[:door_open].get(index) / ONE.to_f

  def where(run) = run[:py] / ONE.to_f

  # --- what the level says ---

  def test_a_doors_panel_runs_the_way_its_code_says
    door = @doors.doors.fetch(room_door)

    # Walls to its east and west, so its panel runs east-west and a ray crossing in y meets it.
    assert_equal Wolf3D::Doors::ACROSS_Y, door.across
    assert @level.solid?(door.x - 1, door.y), "a door sits in a gap, so its sides are wall"
    assert @level.solid?(door.x + 1, door.y)
  end

  def test_a_doors_picture_is_one_of_the_last_eight_walls
    door = @doors.doors.fetch(room_door)
    first = @vswap.wall_count - Wolf3D::Doors::DOOR_PICTURES

    assert_includes (first...@vswap.wall_count), @doors.picture_for(door)
  end

  # --- what a door does ---

  def test_a_shut_door_will_not_let_you_through
    run = walk_at_the_door(about_turn + 80)

    assert_equal 0, door_open(run, room_door), "nothing opened it, so it is still shut"
    assert_operator where(run), :<, @doors.doors.fetch(room_door).y,
                   "the player should be stopped short of the doorway"
  end

  def test_the_button_slides_it_open_and_you_walk_through
    press = about_turn + 60
    opening = walk_at_the_door(press + 8, press: press)
    open = walk_at_the_door(press + 30, press: press)

    assert_operator door_open(opening, room_door), :>, 0, "it should be moving"
    assert_operator door_open(opening, room_door), :<, FP::DOOR_WIDE, "...but not there yet"
    assert_in_delta FP::DOOR_WIDE, door_open(open, room_door), 0.001, "and then all the way open"
    assert_operator where(open), :>, @doors.doors.fetch(room_door).y,
                   "the player should be through the doorway"
  end

  # A door only opens for someone facing it. Pressing the button with your back to one does
  # nothing, which is what stops a game opening every door in the level at once.
  def test_it_does_not_open_from_the_wrong_side_of_the_room
    run = Reference.new.input_each_frame { |f| f > 2 ? [:a] : [] }.run(program, frames: 40)

    assert_equal 0, door_open(run, room_door)
  end

  # Standing in the doorway tops the count back up, so a door cannot shut on you. Walk in and
  # stop, and it is still open long after the three seconds it would otherwise have closed in.
  def test_standing_in_the_doorway_holds_it_open
    press = about_turn + 60
    frames = press + FP::DOOR_LINGER + 90
    doorway = @doors.doors.fetch(room_door).y
    turn = about_turn

    # Walk in, then let go — otherwise the player strolls straight out the other side and the
    # test is about something else entirely.
    stop = press + 26
    run = Reference.new.input_each_frame do |f|
      next [:left] if f <= turn
      next %i[up a] if f == press
      next [] if f > stop

      [:up]
    end.run(program, frames: frames)

    # Only meaningful if the player really did stop in the doorway rather than walking on.
    assert_equal doorway, where(run).floor, "the player should have come to rest in the doorway"
    assert_in_delta FP::DOOR_WIDE, door_open(run, room_door), 0.001,
                    "a door cannot shut on somebody standing in it"
  end

  # --- keys ---

  def test_a_locked_door_stays_shut_without_its_key
    locked = @doors.doors.index { |door| door.lock == :gold }

    refute_nil locked, "the fixture floor should have a gold-locked door"

    # Turn left a quarter to face the room's west wall, then walk into it and press.
    quarter = ((FP::TURN / 4) / FP::TURN_SPEED.to_f).ceil
    run = Reference.new.input_each_frame do |f|
      next [:left] if f <= quarter
      next %i[up a] if f > quarter + 40

      [:up]
    end.run(program, frames: quarter + 80)

    assert_equal 0, run[:keys], "nothing was picked up"
    assert_equal 0, door_open(run, locked), "and so the locked door did not move"
  end

  # The key lies one cell north of where the player starts, which is the way they already face.
  def test_walking_over_a_key_picks_it_up_and_then_the_locked_door_opens
    locked = @doors.doors.index { |door| door.lock == :gold }
    quarter = ((FP::TURN / 4) / FP::TURN_SPEED.to_f).ceil

    got = Reference.new.hold(:up).run(program, frames: 20)

    assert_equal Wolf3D::FirstPerson::KEY_BITS[:gold], got[:keys], "the key should be in hand"

    # ...now go and use it. The locked door is in the west wall on the row the player STARTS
    # on, so this walks north over the key, back south to that row, then turns west.
    north = 20
    back = north + 20
    turned = back + quarter
    run = Reference.new.input_each_frame do |f|
      next [:up] if f <= north
      next [:down] if f <= back
      next [:left] if f <= turned
      next %i[up a] if f > turned + 40

      [:up]
    end.run(program, frames: turned + 90)

    assert_equal Wolf3D::FirstPerson::KEY_BITS[:gold], run[:keys], "still carrying it"
    assert_operator door_open(run, locked), :>, 0, "with the key, the locked door opens"
  end

  # ON THE CONSOLE. Everything above reads the interpreter, which says what the program MEANS.
  # This says the cartridge does it too: the same walk, once leaning on the button and once
  # not. Shut, the door stops the player short of it; opened, they walk through.
  #
  # A FRAME IS NOT THE SAME THING TO THE TWO BACKENDS, which is why this counts its own rather
  # than matching the interpreter's. The interpreter runs the game loop once per frame it is
  # asked for; the console runs it once per frame it has TIME for, and this view takes about
  # two display frames a pass. So the console needs about twice as many frames to play the
  # same amount of game, and the exact ratio is a measurement rather than a rule.
  #
  # The button is leant on rather than tapped once for the same reason: pressing on one exact
  # frame would need to know when the player arrives, and tapping it over and over means
  # whichever tap lands at the door is the one that opens it.
  CONSOLE_TURN = 82   # display frames to bring the player round to face the door
  CONSOLE_WALK = 400  # ...and plenty to reach it and go through

  def test_the_console_opens_the_door_too
    keys = RubyGBA::Constants
    walking = ->(f) { f <= CONSOLE_TURN ? keys::KEY_LEFT : keys::KEY_UP }
    # Tapped every few frames, since only the moment of pressing counts, never holding.
    opening = ->(f) { walking.call(f) | (f > CONSOLE_TURN && (f / 6).even? ? keys::KEY_A : 0) }

    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "DOORS", code: "ZDRS", maker: "01")
    vars = backend.var_addresses
    frames = CONSOLE_TURN + CONSOLE_WALK
    stopped = RubyGBA::Verifier.new(rom, frames: frames, keys: walking, vars: vars)
    through = RubyGBA::Verifier.new(rom, frames: frames, keys: opening, vars: vars)

    doorway = @doors.doors.fetch(room_door).y
    refute stopped.frame_gba.all?(&:zero?), "the cartridge should be drawing something"
    assert_operator stopped.var(:py) / ONE.to_f, :<, doorway,
                    "with nothing pressed, the shut door stops the player short of it"
    assert_operator through.var(:py) / ONE.to_f, :>, doorway,
                    "with the button, the console opens it and the player walks through"
  end
end
