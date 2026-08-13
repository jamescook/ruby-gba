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
  end

  # The room's own door, the one the player can reach. The other is in the outer border.
  def room_door = @doors.doors.index { |door| door.y == 36 }

  def program
    atlas = Wolf3D::WallAtlas.new(@vswap, Wolf3D::Palette.game, @level, doors: @doors)
    level = @level
    doors = @doors

    RubyGBA.game("DOORS", code: "ZDRS", maker: "01") do
      screen :bitmap, tear_free: true
      view = Wolf3D::FirstPerson.new(self, level, atlas, doors)
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

  def door_open(run, index) = run.instance_variable_get(:@lists)[:door_open].get(index)

  def where(run) = run[:py] / (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

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
    assert_equal FP::DOOR_WIDE, door_open(open, room_door), "and then all the way open"
    assert_operator where(open), :>, @doors.doors.fetch(room_door).y,
                   "the player should be through the doorway"
  end

  # A door only opens for someone facing it. Pressing the button with your back to one does
  # nothing, which is what stops a game opening every door in the level at once.
  def test_it_does_not_open_from_the_wrong_side_of_the_room
    run = Reference.new.input_each_frame { |f| f > 2 ? [:a] : [] }.run(program, frames: 40)

    assert_equal 0, door_open(run, room_door)
  end
end
