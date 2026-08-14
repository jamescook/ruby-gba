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

  # THE GAME WITHOUT THE PICTURE. Everything below asks how far the wall has got and where the
  # player is; none of it reads a pixel. Drawing costs about a hundred times what the game does,
  # so leaving it in means casting eighty rays a frame for two hundred frames to read a counter.
  # What the wall LOOKS like is a question of its own, and it is asked once, further down.
  def program(drawing: false)
    atlas = Wolf3D::WallAtlas.new(@vswap, Wolf3D::Palette.game, @level, doors: @doors)
    level = @level
    doors = @doors
    pushwalls = @pushwalls

    RubyGBA.game("PUSH", code: "ZPSH", maker: "01") do
      screen :bitmap, tear_free: true
      view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas,
                                     doors: doors, pushwalls: pushwalls)
      game_loop { drawing ? view.update : view.play }
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

  # WHAT A RAY SEES, which is the other half of a secret wall and the half no counter can show.
  #
  # The map cannot say where a push wall IS, because the map is in the cartridge and the wall
  # moves. So the map marks every cell one could ever reach, and the ray works out where it is
  # now: its home, plus how far it has gone. Get that wrong in either direction and the wall is
  # either drawn where it no longer stands or invisible where it does.
  #
  # Standing right in front of it: shut in, the wall fills the view. Once it has slid two cells
  # away, the same look down the same corridor shows it much smaller, and the cells it passed
  # through are seen straight past.
  SIDE = 16
  WALL_AT = 12
  BESIDE_IT = 11

  # A corridor east with a secret wall across it and floor for it to slide into.
  def secret_corridor
    cells = Array.new(SIDE * SIDE, Wolf3D::Level::FLOOR)
    things = Array.new(SIDE * SIDE, 0)
    SIDE.times do |y|
      SIDE.times do |x|
        edge = x.zero? || y.zero? || x == SIDE - 1 || y == SIDE - 1
        cells[(y * SIDE) + x] = Wolf3D::Fixture::Release::WALL if edge || x == WALL_AT
      end
    end
    things[(8 * SIDE) + WALL_AT] = Wolf3D::Level::PUSHWALL
    things[(8 * SIDE) + BESIDE_IT] = Wolf3D::Level::FACINGS.key(:east)
    Wolf3D::Level.new(name: "Secret", width: SIDE, height: SIDE, walls: cells, things: things)
  end

  def secret_program(level)
    doors = Wolf3D::Doors.new(level, @vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    atlas = Wolf3D::WallAtlas.new(@vswap, Wolf3D::Palette.game, level, doors: doors)

    RubyGBA.game("PUSH", code: "ZPSH", maker: "01") do
      screen :bitmap, tear_free: true
      view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas,
                                     doors: doors, pushwalls: pushwalls)
      game_loop { view.update }
    end.program
  end

  # How far down the screen the wall ahead starts, at the middle of the view.
  def wall_top(run)
    (0...FP::HORIZON).find { |y| run.screen.pixel(120, y) != FP::CEILING } || FP::HORIZON
  end

  # ...and how TALL it therefore stands, which is what a distance actually shows as. The eye line
  # is the middle of a wall, so twice the drop from the top of the view down to its top edge is
  # the whole height — and unlike the top edge, that is a fact about the wall rather than about
  # where the eye line happens to sit.
  def wall_height(run) = (FP::HORIZON - wall_top(run)) * 2

  def test_a_ray_sees_the_wall_where_it_is_now_and_not_where_it_started
    program = secret_program(secret_corridor)
    gone = (Wolf3D::Pushwalls::FRAMES_PER_CELL * Wolf3D::Pushwalls::DISTANCE) + 4

    before = Reference.new.run(program, frames: 3)
    after = Reference.new.input_each_frame { |f| f == 2 ? [:a] : [] }.run(program, frames: gone)

    assert_equal FP::VIEW_H, wall_height(before), "up against it, the wall fills the view"
    assert_operator wall_height(after), :<, FP::VIEW_H * 3 / 4,
                    "two cells away it stands shorter, and the cells it left are seen past"
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
