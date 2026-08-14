# frozen_string_literal: true

require_relative "test_helper"

# GUARDS YOU CAN SEE: where the level puts them, and what the screen shows.
#
# Everything here is measured as pixels rather than asserted about state, because the whole
# question this answers is what the picture looks like — a guard is in front of one wall and
# behind another, and only the picture can say whether that came out right.
#
# THE FIXTURE PAINTS EACH SPRITE ONE FLAT COLOUR OF ITS OWN, so the colour of a pixel says
# which of the eight pictures drew it. That is what makes "which way is he facing" a thing the
# screen can answer.
class TestGuards < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Guards = Wolf3D::Guards
  Release = Wolf3D::Fixture::Release

  # A small field, so a ray meets its edge quickly and the tests stay quick with it.
  SIDE = 16
  FLOOR = Wolf3D::Level::FLOOR
  WALL = Release::WALL

  # WHERE TO LOOK FOR A GUARD, and there is only one row that always works. A guard is drawn in
  # a square the size of a wall at his distance, and the fixture fills the middle band of that
  # square — so the band moves up the screen and shrinks as he gets further away. The one row
  # inside it at every distance is the eye line itself, because the square is centred there.
  EYE_LINE = FP::HORIZON

  # ---------------------------------------------------------------- reading the level

  def test_it_reads_a_guard_out_of_the_level_with_the_way_it_faces
    guards = Guards.new(arena(guards: [[12, 8, :west]]))

    assert_equal 1, guards.count
    assert_equal [12, 8, :west, false], guards.guards.first.deconstruct
  end

  def test_a_guard_put_down_to_walk_a_beat_is_read_as_one
    code = Guards::PATROLLING + Guards::FACINGS.index(:north)
    guards = Guards.new(arena(things: { [12, 8] => code }))

    assert_equal :north, guards.guards.first.facing
    assert_predicate guards.guards.first, :patrolling
  end

  # The four codes run east, north, west, south — which is NOT the order the player's own
  # start codes run in, and the only way to know that is to look at the original.
  def test_the_four_facing_codes_run_the_way_the_original_writes_them
    facings = (0...4).map do |n|
      Guards.new(arena(things: { [12, 8] => Guards::STANDING + n })).guards.first.facing
    end

    assert_equal %i[east north west south], facings
  end

  # A harder game puts more guards on the same floor, and says so by repeating the same codes
  # further up. An easy game must not see them.
  def test_a_guard_only_a_harder_game_holds_is_left_out_of_an_easy_one
    level = arena(things: { [12, 8] => Guards::STANDING + Guards::HARDER })

    assert_equal 0, Guards.new(level, difficulty: :easy).count
    assert_equal 1, Guards.new(level, difficulty: :medium).count
    assert_equal 1, Guards.new(level, difficulty: :hard).count
  end

  def test_an_unknown_difficulty_says_which_ones_there_are
    error = assert_raises(ArgumentError) { Guards.new(arena, difficulty: :nightmare) }

    assert_match(/nightmare/, error.message)
    assert_match(/baby, easy, medium, hard/, error.message)
  end

  # ---------------------------------------------------------------- what the screen shows

  def test_a_guard_in_an_open_room_is_drawn
    run = look_at(guards: [[14, 8, :east]])

    assert_operator guard_columns(run).length, :>, 4, "the guard should cover some strips"
    assert_in_delta 120, guard_columns(run).sum / guard_columns(run).length.to_f, 12,
                    "and stand about in the middle, since the player is looking straight at him"
  end

  def test_a_guard_behind_a_wall_is_not_drawn_at_all
    open_room = look_at(guards: [[14, 8, :east]])
    walled = look_at(guards: [[14, 8, :east]], walls: [[11, 7], [11, 8], [11, 9]])

    refute_empty guard_columns(open_room), "he is there when nothing is in the way"
    assert_empty guard_columns(walled), "and gone behind a wall, not drawn through it"
  end

  # HALF BEHIND A WALL, and the arrangement is measured rather than reasoned about. A guard
  # this size covers about two degrees of the view, so the edge of a wall's shadow has to land
  # almost exactly on him to cut him in half — one cell nearer or further and he is either
  # wholly there or wholly gone. This is the block that does it: three cells ahead and one to
  # the side of a guard six cells ahead and one to the side.
  #
  # Held against the same guard in the open rather than against a column number, so it says
  # what it means: he is cut down, not moved, and what went is all on one side of what stayed.
  def test_a_guard_half_behind_a_wall_draws_his_visible_half_only
    whole = guard_columns(look_at(guards: [[14, 7, :east]]))
    part = guard_columns(look_at(guards: [[14, 7, :east]], walls: [[11, 7]]))

    refute_empty part, "part of him is still in the open"
    assert_operator part.length, :<, whole.length, "and part of him is behind the wall"
    assert_empty part - whole, "what shows is what showed before, not something moved"
    assert_operator (whole - part).max, :<, part.min,
                    "and everything the wall took is on one side of everything left"
  end

  # A guard STANDS IN FRONT OF a wall that is further away, which is the other half of the same
  # question and the one a depth test gets wrong by being backwards.
  def test_a_guard_stands_in_front_of_the_wall_behind_him
    run = look_at(guards: [[10, 8, :east]])

    assert_operator guard_columns(run).length, :>, 8,
                    "a guard close up covers a good part of the wall behind him"
  end

  # ---------------------------------------------------------------- one in front of another

  # TWO GUARDS, ONE DIRECTLY BEHIND THE OTHER. The near one wins, and it must not matter which
  # of them the level happened to put down first — so this is run both ways round. The level is
  # read in order, so looking east meets the near guard first and looking west meets the far
  # one first.
  #
  # The two are told apart by which way they face rather than by where they are: the near one
  # turns his back on the player (his fifth picture) and the far one faces them (his first), so
  # a single pixel says which of the two drew it.
  BACK = 4
  FACE = 0

  def test_the_nearer_of_two_guards_is_the_one_you_see
    { east: [[12, 8], [15, 8]], west: [[4, 8], [1, 8]] }.each do |facing, (near, far)|
      run = look_at(player: [8, 8], facing: facing,
                    guards: [near + [facing], far + [opposite(facing)]])
      shown = poses_on_screen(run)

      assert_includes shown, BACK, "looking #{facing}: the near guard should show"
      refute_includes shown, FACE, "looking #{facing}: and the one behind him should not"
    end
  end

  def test_two_guards_side_by_side_are_both_drawn
    run = look_at(guards: [[13, 6, :east], [13, 10, :west]], player: [8, 8], facing: :east)

    assert_equal 2, poses_on_screen(run).length, "neither is in the other's way"
  end

  # ---------------------------------------------------------------- which way he is facing

  # WHICH OF THE EIGHT PICTURES SHOWS is the angle between the way the guard faces and where
  # the player is standing. Walk round a guard who never turns and the picture must turn.
  #
  # He faces east. From the east you meet his face; from the west you see his back; and the two
  # sides are the two quarters between.
  def test_the_picture_follows_where_you_stand_around_him
    at = { east: [[14, 8], :west], south: [[8, 14], :north],
           west: [[2, 8], :east], north: [[8, 2], :south] }
    seen = at.transform_values do |(player, facing)|
      poses_on_screen(look_at(guards: [[8, 8, :east]], player: player, facing: facing)).first
    end

    assert_equal({ east: 0, south: 6, west: 4, north: 2 }, seen)
  end

  # ---------------------------------------------------------------- and on the console

  # THE CARTRIDGE DRAWS HIM TOO, and the whole picture is held against the interpreter's rather
  # than only the guard. That is the stronger check: it says the two agree about the walls he
  # stands among, and about which of the two is in front, and not merely that both drew a man
  # somewhere.
  def test_the_console_draws_the_guard_the_interpreter_draws
    program = view_of(arena(guards: [[13, 8, :east]]))
    interp = Reference.new.run(program, frames: 3)
    rom = ROM.assemble(GBA.new.lower(program), title: "GUARDS", code: "ZGRD", maker: "01")
    gba = RubyGBA::Verifier.new(rom, frames: 8)

    refute_empty guard_columns(interp), "the interpreter draws him, so there is something to match"
    differ = (0...240).to_a.product((0...160).to_a).reject do |x, y|
      (interp.screen.pixel(x, y) || 0) == gba.pixel_gba(x, y)
    end

    assert_empty differ.first(8), "these pixels differ between the interpreter and the console"
  end

  private

  def fixture = @fixture ||= Release.new
  def opposite(facing) = { east: :west, west: :east, north: :south, south: :north }.fetch(facing)
  def vswap = @vswap ||= Wolf3D::Vswap.new(fixture.files["VSWAP"])
  def palette = Wolf3D::Palette.game

  # A LEVEL MADE FOR ONE QUESTION: a walled field with a floor inside it, the player where you
  # put them, and whatever else you name. Built straight rather than written out as a release
  # and read back, because what each of these tests needs is one exact arrangement.
  def arena(player: [8, 8], facing: :east, guards: [], walls: [], things: {})
    cells = Array.new(SIDE * SIDE, FLOOR)
    standing = Array.new(SIDE * SIDE, 0)
    SIDE.times do |y|
      SIDE.times do |x|
        cells[(y * SIDE) + x] = WALL if x.zero? || y.zero? || x == SIDE - 1 || y == SIDE - 1
      end
    end
    walls.each { |x, y| cells[(y * SIDE) + x] = WALL }
    standing[(player[1] * SIDE) + player[0]] = Wolf3D::Level::FACINGS.key(facing)
    guards.each do |x, y, way|
      standing[(y * SIDE) + x] = Guards::STANDING + Guards::FACINGS.index(way)
    end
    things.each { |(x, y), code| standing[(y * SIDE) + x] = code }

    Wolf3D::Level.new(name: "Arena", width: SIDE, height: SIDE, walls: cells, things: standing)
  end

  def view_of(level)
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Guards.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, palette, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, palette, guards.pictures)

    RubyGBA.game("GUARDS", code: "AGRD", maker: "01") do
      screen :bitmap, tear_free: true
      view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas, doors: doors,
                                     pushwalls: pushwalls, guards: guards, things: things)
      game_loop { view.update }
    end.program
  end

  # Stand where the level says and look. Nothing moves, so two frames settle it.
  def look_at(**) = Reference.new.run(view_of(arena(**)), frames: 2)

  # The flat colour the fixture gave each of the eight pictures.
  def pose_colour(pose) = palette[Release::SPRITE_INK + Guards::FIRST_STANDING_PICTURE + pose]
  def pose_colours = @pose_colours ||= (0...Guards::POSES).map { |n| pose_colour(n) }

  # Which strips of the screen a guard is showing in, read across his middle.
  def guard_columns(run, row: EYE_LINE)
    (0...240).select { |x| pose_colours.include?(run.screen.pixel(x, row)) }
  end

  # ...and which of the eight pictures those strips are showing.
  def poses_on_screen(run, row: EYE_LINE)
    guard_columns(run, row: row).map { |x| pose_colours.index(run.screen.pixel(x, row)) }.uniq
  end
end
