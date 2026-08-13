# frozen_string_literal: true

require_relative "test_helper"

# The secret walls: a cell built as wall, marked in the things plane, that slides two cells
# away when you lean on it.
#
# THE MAP IS IN THE CARTRIDGE AND CANNOT BE WRITTEN TO, which is what makes this awkward. A
# door never leaves its cell; a push wall does, and ends up somewhere the map still calls
# floor. So the map marks everywhere one could ever GET to, and where it actually is comes
# from a handful of arithmetic on those few cells.
class TestPushwalls < Minitest::Test
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

  def program
    atlas = Wolf3D::WallAtlas.new(@vswap, Wolf3D::Palette.game, @level, doors: @doors)
    level = @level
    doors = @doors
    pushwalls = @pushwalls

    RubyGBA.game("PUSH", code: "ZPSH", maker: "01") do
      screen :bitmap, tear_free: true
      view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas,
                                     doors: doors, pushwalls: pushwalls)
      game_loop { view.update }
    end.program
  end

  def slot(run, list, index) = run.instance_variable_get(:@lists)[list].get(index)

  def gone(run) = slot(run, :push_gone, 0)

  # A quarter turn, so the player faces the room's east wall where the push wall is.
  def quarter_turn = ((FP::TURN / 4) / FP::TURN_SPEED.to_f).ceil

  # Turn right to face east, walk into the wall, and lean on it from +press+.
  def shove(frames, press: nil)
    turn = quarter_turn
    Reference.new.input_each_frame do |f|
      next [:right] if f <= turn
      next %i[up a] if press && f == press

      [:up]
    end.run(program, frames: frames)
  end

  # --- what the level says ---

  def test_the_level_has_a_push_wall_and_it_is_built_as_wall
    assert_equal 1, @pushwalls.count
    wall = @pushwalls.walls.first

    assert @level.pushwall?(wall.x, wall.y), "marked in the things plane"
    assert @level.solid?(wall.x, wall.y), "and built as wall in the other one"
  end

  # It marks where it could GET to, not where it is — its own cell plus the floor within two
  # steps. The cells behind it are open field, so it can reach them; the wall it sits in
  # cannot be walked into, so those directions stop at once.
  def test_it_marks_every_cell_it_could_ever_reach
    wall = @pushwalls.walls.first

    assert_equal 1, @pushwalls.number_at(wall.x, wall.y), "its own cell, first"
    assert_equal 1, @pushwalls.number_at(wall.x + 1, wall.y), "one step east, into the field"
    assert_equal 1, @pushwalls.number_at(wall.x + 2, wall.y), "and two"
    assert_nil @pushwalls.number_at(wall.x + 3, wall.y), "but no further than it can go"
    assert_nil @pushwalls.number_at(wall.x, wall.y + 1), "and not along its own wall"
  end

  # --- what it does ---

  def test_it_does_not_budge_until_you_lean_on_it
    run = shove(quarter_turn + 90)

    assert_equal 0, gone(run), "walking into it is not pushing it"
  end

  def test_leaning_on_it_moves_it_two_cells_and_then_it_stops
    press = quarter_turn + 60
    per_cell = Wolf3D::Pushwalls::FRAMES_PER_CELL

    one = shove(press + per_cell + 2, press: press)
    two = shove(press + (per_cell * 2) + 4, press: press)
    later = shove(press + (per_cell * 5), press: press)

    assert_equal 1, gone(one), "one cell along after the first stretch"
    assert_equal Wolf3D::Pushwalls::DISTANCE, gone(two), "and two after the second"
    assert_equal Wolf3D::Pushwalls::DISTANCE, gone(later), "and then it stops for good"
  end

  # The point of the whole thing: where it stood is now a way through.
  def test_the_way_it_came_from_is_open_once_it_has_gone
    press = quarter_turn + 60
    per_cell = Wolf3D::Pushwalls::FRAMES_PER_CELL
    wall = @pushwalls.walls.first

    run = shove(press + (per_cell * 3), press: press)
    px = run[:px] / (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

    assert_equal Wolf3D::Pushwalls::DISTANCE, gone(run), "it should have finished moving"
    assert_operator px, :>, wall.x, "and the player should have walked through where it stood"
  end
end
