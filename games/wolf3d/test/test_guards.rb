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

  # ---------------------------------------------------------------- what he does

  # These read where a guard is and what he is doing, never a pixel, so they run the game
  # without drawing it — a hundred times cheaper, and the same answers.

  STAND = Guards.state_number(:stand)
  CHASING = (1...Guards::STATES.length).select { |n| Guards::STATES[n].name.start_with?("chase") }
  FIRING = (1...Guards::STATES.length).select { |n| Guards::STATES[n].name.start_with?("shoot") }

  # A GUARD WHO CAN SEE YOU COMES AFTER YOU. He is facing your way with nothing in between, so
  # he notices, waits out his moment of reaction, and then closes.
  def test_a_guard_who_can_see_you_comes_after_you
    run = watch(guards: [[12, 8, :west]], frames: 200)

    assert_includes CHASING + FIRING, state_of(run), "he should have set off"
    assert_operator guard_at(run, :x), :<, 12.5, "and closed some of the distance"
  end

  # ...but not through a wall. This is the line of sight doing its job, and it is the only
  # thing different between this and the test above.
  def test_a_guard_cannot_see_you_through_a_wall
    run = watch(guards: [[12, 8, :west]], walls: [[10, 8]], frames: 200)

    assert_equal STAND, state_of(run), "a wall between them is a wall between them"
    assert_in_delta 12.5, guard_at(run, :x), 0.001, "so he has not moved"
  end

  # ...and not behind him either. A guard facing away sees nothing that way, which is what
  # makes sneaking up on one possible.
  def test_a_guard_does_not_see_you_behind_him
    run = watch(guards: [[12, 8, :east]], frames: 200)

    assert_equal STAND, state_of(run)
  end

  # HE DOES NOT SET OFF THE MOMENT HE SEES YOU. Noticing and reacting are two things: he sees
  # you on one pass and starts his count, and only when that runs down does he come. That beat
  # is why the game feels fair, and one pass is enough to show the two are separate.
  def test_seeing_you_and_coming_after_you_are_not_the_same_pass
    assert_equal STAND, state_of(watch(guards: [[12, 8, :west]], frames: 1)),
                 "on the pass he sees you he is still standing"
  end

  # A guard put down to walk a beat walks it. The player is kept BEHIND him and off his row,
  # which is what keeps this about the beat rather than about noticing anybody — a patrolling
  # guard looks as he goes, and one who sees you stops patrolling and comes.
  #
  # Off his ROW as well as behind him because of where a guard's sight ends. "In front" is one
  # comparison per facing in the original, so a guard facing north sees everything at his own
  # y or above it — and a player exactly level with him is on that line, and seen the moment he
  # turns to face along it.
  HIDING = [2, 12].freeze

  def test_a_patrolling_guard_walks_his_beat
    beat = Guards::PATROLLING + Guards::FACINGS.index(:east)
    run = watch(things: { [10, 8] => beat }, player: HIDING, frames: 120)

    assert_operator guard_at(run, :x), :>, 10.5, "he should have walked east"
    assert_in_delta 8.5, guard_at(run, :y), 0.001, "and only east"
  end

  # A TURNING POINT TURNS HIM. Plane 1 holds an arrow in a cell, and a patrolling guard who
  # reaches it goes the way it points instead of straight on.
  def test_a_turning_point_sends_a_patrolling_guard_a_new_way
    beat = Guards::PATROLLING + Guards::FACINGS.index(:east)
    north = Guards::FIRST_ARROW + 2
    run = watch(things: { [10, 8] => beat, [11, 8] => north }, player: HIDING, frames: 260)

    assert_in_delta 11.5, guard_at(run, :x), 0.001, "he should have stopped going east at it"
    assert_operator guard_at(run, :y), :<, 8.4, "and turned north"
  end

  # A guard with a clear line at you stops to take a shot, which is a chance against distance
  # taken every pass — so it is a matter of when rather than whether. This looks for the moment.
  def test_a_guard_that_reaches_you_goes_for_his_gun
    fired = (40..200).step(20).any? do |frames|
      FIRING.include?(state_of(watch(guards: [[10, 8, :west]], frames: frames)))
    end

    assert fired, "somewhere in there he should have been firing"
  end

  # ---------------------------------------------------------------- shooting, and being shot

  DEAD = Guards.state_number(:dead)
  FALLING = (0...Guards::STATES.length).select { |n| Guards::STATES[n].name.start_with?("fall") }
  HURT = (0...Guards::STATES.length).select { |n| Guards::STATES[n].name.start_with?("hurt") }

  # A GUARD STANDING IN FRONT OF YOU CAN BE SHOT. He is close, so the pistol cannot miss and
  # takes a good bite out of him; a few taps and he falls over and stays down.
  def test_enough_shots_kill_a_guard
    run = shoot_at([[10, 8, :west]], shots: 8, frames: 300)

    assert_includes FALLING + [DEAD], state_of(run), "he should be going down or down"
    assert_operator guard_hp(run), :<=, 0, "with nothing left"
  end

  def test_a_guard_left_alone_keeps_his_hit_points
    run = watch(guards: [[10, 8, :west]], frames: 60)

    assert_equal Guards::HIT_POINTS, guard_hp(run)
  end

  # ...and a body stays a body. Once he is down nothing brings him back, and he stops thinking
  # about anything at all.
  def test_a_dead_guard_stays_dead
    early = shoot_at([[10, 8, :west]], shots: 8, frames: 300)
    later = shoot_at([[10, 8, :west]], shots: 8, frames: 800)

    assert_operator guard_hp(early), :<=, 0
    assert_equal DEAD, state_of(later), "he ends as a body on the floor and stays one"
  end

  # ONE PRESS IS ONE BULLET, and eight is all you start with.
  def test_the_pistol_spends_a_bullet_a_shot
    assert_equal FP::START_AMMO - 3, shoot_at([[10, 8, :west]], shots: 3, frames: 90)[:ammo]
    assert_equal 0, shoot_at([[10, 8, :west]], shots: 20, frames: 400)[:ammo],
                 "and once they are gone the trigger does nothing"
  end

  # A SHOT GOES TO THE NEAREST ONE IN THE SIGHTS, not through him to the one behind. One bullet,
  # two guards in a line: the near one takes it and the far one is untouched.
  #
  # ONE bullet on purpose. A guard who has not noticed you takes double, and a pistol at this
  # range takes more off him than he has — so a second shot would find the near one already
  # down and go to the far one, which is correct and would hide what this is asking.
  def test_a_shot_stops_at_the_first_guard_in_the_way
    near, far = guards_by_distance(shoot_at([[10, 8, :west], [13, 8, :west]], shots: 1, frames: 30), 2)

    assert_operator near[:hp], :<, Guards::HIT_POINTS, "the near one is hit"
    assert_equal Guards::HIT_POINTS, far[:hp], "and the far one is not"
  end

  # ...and one off to the side is not in the sights at all. The window is a tenth of the screen
  # either side of the middle, so a guard a few cells across the room is missed entirely.
  def test_a_guard_out_of_the_sights_is_not_hit
    run = shoot_at([[10, 3, :west]], shots: 6, frames: 200)

    assert_equal Guards::HIT_POINTS, guard_hp(run), "he is not down the line you are looking"
  end

  # BEING SHOT ROUSES HIM. A guard facing away has no idea you are there until the first
  # bullet, and after it he is never back to minding his own business — he is flinching,
  # coming, firing, or on the floor.
  UNAWARE = (0...Guards::STATES.length).reject { |n| Guards.roused?(Guards::STATES[n]) }

  def test_shooting_a_guard_who_had_not_noticed_you_brings_him_round
    run = shoot_at([[10, 8, :east]], shots: 1, frames: 40)

    refute_includes UNAWARE, state_of(run), "the shot should have brought him round"
    assert_operator guard_hp(run), :<, Guards::HIT_POINTS, "and taken something off him"
  end

  # AND THEY SHOOT BACK. Stand in front of one and do nothing, and he closes, fires, and takes
  # you down to nothing — which is the whole of dying until there is a screen to say so.
  def test_a_guard_shoots_back_and_can_kill_you
    hurt = watch(guards: [[11, 8, :west]], frames: 400)

    assert_operator hurt[:health], :<, FP::START_HEALTH, "he should have hit you"
    assert_equal 0, watch(guards: [[11, 8, :west]], frames: 2000)[:health],
                 "and gone on until there was nothing left"
  end

  # A DEAD PLAYER STOPS. Held against himself later rather than against a place on the map,
  # because nothing here blocks a body — a guard is something to look at and shoot, not
  # something to bump into, so the player walks straight through one and where he ends up says
  # nothing about when he died.
  def test_a_dead_player_stops_where_he_fell
    walking = view_of(arena(guards: [[11, 8, :west]]), drawing: false)
    died = Reference.new.hold(:up).run(walking, frames: 1200)
    later = Reference.new.hold(:up).run(walking, frames: 2400)

    assert_equal 0, died[:health], "he should be dead by then"
    assert_in_delta died[:px] / ONE, later[:px] / ONE, 0.001,
                    "and not have moved since, however long the button is held"
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

  def view_of(level, drawing: true)
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Guards.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, palette, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, palette, guards.pictures)

    RubyGBA.game("GUARDS", code: "AGRD", maker: "01") do
      screen :bitmap, tear_free: true
      view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas, doors: doors,
                                     pushwalls: pushwalls, guards: guards, things: things)
      game_loop { drawing ? view.update : view.play }
    end.program
  end

  # Run the game without drawing it, for the tests that watch what a guard does rather than
  # what he looks like.
  def watch(frames:, **)
    Reference.new.run(view_of(arena(**), drawing: false), frames: frames)
  end

  ONE = (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

  def pool_field(run, field, slot = 0) = run.instance_variable_get(:@lists)[:"__pool_guard_#{field}"].get(slot)
  def state_of(run, slot = 0) = pool_field(run, :state, slot)
  def guard_hp(run, slot = 0) = pool_field(run, :hp, slot)
  def guard_at(run, axis) = pool_field(run, axis) / ONE

  # The guards as the player meets them, nearest first. A pool hands out its slots from the
  # back, so the order a level put its guards down is NOT the order they are stored in — which
  # is exactly the kind of thing a test should not quietly depend on.
  def guards_by_distance(run, count)
    (0...count).map { |slot| { x: pool_field(run, :x, slot) / ONE, hp: guard_hp(run, slot) } }
               .sort_by { |guard| guard[:x] }
  end

  # Stand still and tap the trigger. The button is read on the press, so it has to go up
  # between shots or only the first one counts.
  def shoot_at(guards, shots:, frames:, **)
    firing = ->(f) { f < shots * 4 && (f / 2).even? ? [:b] : [] }
    Reference.new.input_each_frame { |f| firing.call(f) }
             .run(view_of(arena(guards: guards, **), drawing: false), frames: frames)
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
