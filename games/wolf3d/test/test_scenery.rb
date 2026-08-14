# frozen_string_literal: true

require_relative "test_helper"

# THE THINGS STANDING IN THE ROOMS: lamps, tables, bones, barrels — what the level says is
# there, what the screen shows of it, and which of them you cannot walk through.
#
# THE FIXTURE PAINTS EACH SPRITE ONE FLAT COLOUR OF ITS OWN, so the colour of a pixel says which
# picture drew it. That is what lets a test tell a barrel from the puddle beside it.
class TestScenery < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Scenery = Wolf3D::Scenery
  Guards = Wolf3D::Guards
  Release = Wolf3D::Fixture::Release

  SIDE = 16
  FLOOR = Wolf3D::Level::FLOOR
  WALL = Release::WALL

  # The pieces this file uses, by the name the original gives them. The codes run in one order
  # from 23, so a piece is its place in that order.
  PUDDLE = Scenery::FIRST_CODE
  BARREL = Scenery::FIRST_CODE + 1
  TABLE = Scenery::FIRST_CODE + 2
  CHANDELIER = Scenery::FIRST_CODE + 4
  CEILING_LIGHT = Scenery::CEILING_LIGHT
  GOLD_KEY = Wolf3D::Level::KEYS.key(:gold)

  # A standing thing is drawn in a square centred on the eye line, and the fixture fills the
  # middle band of that square — so the one row inside it at every distance is the eye line.
  EYE_LINE = FP::HORIZON

  # ---------------------------------------------------------------- what the level says

  def test_it_reads_a_piece_of_scenery_out_of_the_level
    scenery = Scenery.new(arena(things: { [12, 8] => BARREL }))

    assert_equal 1, scenery.count
    assert_equal [12, 8, picture_of(BARREL), true], scenery.pieces.first.deconstruct
  end

  # HALF OF THEM STOP YOU AND HALF DO NOT, and which is which is the original's own table. The
  # chandelier is the one people expect to be wrong: it hangs, so you walk under it.
  def test_which_pieces_stop_you_is_the_originals_own_answer
    blocking = [BARREL, TABLE].map { |code| blocks?(code) }
    walk_through = [PUDDLE, CHANDELIER, GOLD_KEY].map { |code| blocks?(code) }

    assert_equal [true, true], blocking
    assert_equal [false, false, false], walk_through
  end

  # Plane 1 says a great deal besides scenery — where the player starts, where the guards are,
  # which cells turn a patrol round. None of those is a thing standing in a room.
  def test_the_other_things_plane_one_says_are_not_scenery
    others = { [10, 8] => Wolf3D::Level::FACINGS.key(:north),
               [11, 8] => Guards::STANDING,
               [12, 8] => Guards::FIRST_ARROW,
               [13, 8] => Wolf3D::Level::PUSHWALL }

    assert_predicate Scenery.new(arena(things: others)), :empty?
  end

  # The last code is a second kind of ammunition clip, and it wears the ordinary clip's picture
  # rather than one of its own — which is why the list of pictures is not simply nought upward.
  def test_the_last_code_wears_the_clips_picture
    clip = Scenery::FIRST_CODE + 26
    second = Scenery::FIRST_CODE + 48

    assert_equal picture_of(clip), picture_of(second)
  end

  def test_a_floor_asks_for_each_of_its_pictures_once
    scenery = Scenery.new(arena(things: { [10, 8] => BARREL, [11, 8] => BARREL,
                                          [12, 8] => PUDDLE }))

    assert_equal [picture_of(PUDDLE), picture_of(BARREL)].sort, scenery.pictures
  end

  # ---------------------------------------------------------------- what the screen shows

  def test_a_piece_of_scenery_in_an_open_room_is_drawn
    shown = columns_of(look_at(things: { [12, 8] => BARREL }), BARREL)

    refute_empty shown, "the barrel should cover some strips"
    assert_in_delta 120, shown.sum / shown.length.to_f, 12,
                    "and stand about in the middle, since the player is looking straight at it"
  end

  def test_a_piece_of_scenery_behind_a_wall_is_not_drawn_at_all
    open_room = look_at(things: { [12, 8] => BARREL })
    walled = look_at(things: { [12, 8] => BARREL }, walls: [[10, 7], [10, 8], [10, 9]])

    refute_empty columns_of(open_room, BARREL), "it is there when nothing is in the way"
    assert_empty columns_of(walled, BARREL), "and gone behind a wall, not drawn through it"
  end

  # The near one wins, and it must not matter which of them the level put down first — so this
  # is run both ways round. The level is read in order, so looking east meets the near piece
  # first and looking west meets the far one first.
  def test_the_nearer_of_two_pieces_is_the_one_you_see
    { east: [[11, 8], [14, 8]], west: [[5, 8], [2, 8]] }.each do |facing, (near, far)|
      run = look_at(facing: facing, things: { near => BARREL, far => TABLE })

      refute_empty columns_of(run, BARREL), "looking #{facing}: the near piece should show"
      assert_empty columns_of(run, TABLE), "looking #{facing}: and the one behind it should not"
    end
  end

  # A CEILING LIGHT HAS A HOLE THROUGH THE MIDDLE OF IT: the lamp hangs high in its square and
  # the light it throws falls low in it, and the eye line runs through the nothing between. So a
  # guard on the far side of one is looked at THROUGH it and must be drawn — which he is not if
  # the lamp is allowed to claim the whole of every strip it covers.
  #
  def test_a_guard_is_seen_through_the_gap_in_a_hanging_lamp
    behind = look_at(things: { [10, 8] => CEILING_LIGHT }, guards: [[13, 8, :west]])

    assert_empty columns_of(behind, CEILING_LIGHT), "the lamp is see-through along the eye line"
    refute_empty guard_columns(behind), "so the guard behind it shows through the gap"
    refute_empty rows_of(behind, CEILING_LIGHT), "and the lamp itself is drawn, where its art is"
  end

  # ...and the same lamp is still covered by what stands in FRONT of it, which is the other half
  # of the answer: turned round, the guard is the near one and nothing of the lamp is left.
  def test_a_hanging_lamp_is_covered_by_a_guard_in_front_of_it
    in_front = look_at(things: { [13, 8] => CEILING_LIGHT }, guards: [[10, 8, :west]])

    refute_empty guard_columns(in_front), "the guard is the near one now"
    assert_empty rows_of(in_front, CEILING_LIGHT), "and no part of the lamp shows through him"
  end

  # WHAT A WALL SAVES. Everything standing in front of the eye and across the screen has to be
  # put in order before any of it is drawn, and there is only so much room to put it in — so the
  # walls are asked first. A floor is mostly walls, and the room next door can hold a great many
  # things that no strip of the screen could ever show.
  #
  # It is measured as the length of the queue rather than by reading pixels, because what is
  # being asked is what the frame CARRIED, and both answers draw the same picture.
  def test_things_behind_a_wall_take_no_place_in_the_queue
    crowd = (11..14).to_a.product((7..9).to_a).to_h { |cell| [cell, BARREL] }
    open_room = look_at(things: crowd)
    walled = look_at(things: crowd, walls: (5..11).map { |y| [10, y] })

    assert_equal crowd.length, queued(open_room), "with nothing in the way, every one is drawn"
    assert_equal 0, queued(walled), "and behind a wall not one of them takes a place"
  end

  # A guard stands among the scenery, not in a world of his own: one hides the other by
  # whichever is nearer, because the far ones are drawn first and the near ones paint over them.
  def test_scenery_and_a_guard_hide_each_other_by_which_is_nearer
    near = look_at(things: { [11, 8] => BARREL }, guards: [[14, 8, :west]])
    far = look_at(things: { [14, 8] => BARREL }, guards: [[11, 8, :west]])

    refute_empty columns_of(near, BARREL), "the barrel in front covers the guard"
    assert_empty guard_columns(near)
    assert_empty columns_of(far, BARREL), "and the guard in front covers the barrel"
    refute_empty guard_columns(far)
  end

  # A BARREL STOPS YOUR FEET AND NOT YOUR EYES, which is the first thing in this game with that
  # shape. A ray that stopped at one would draw the barrel's cell as a wall — so the wall behind
  # would jump forward to where the barrel is, and the room behind it would be gone.
  #
  # Read as where the ceiling stops, which is the top edge of the wall ahead: a near wall is
  # tall and starts high up the screen, a far one is short and starts near the eye line.
  def test_a_ray_sees_past_a_barrel_and_carries_on_to_the_wall
    corridor = { walls: (0...SIDE).flat_map { |x| [[x, 7], [x, 9]] } + [[12, 8]] }
    open_way = ceiling_ends(look_at(**corridor))
    past_a_barrel = ceiling_ends(look_at(**corridor, things: { [10, 8] => BARREL }))
    stopped = ceiling_ends(look_at(**corridor, walls: corridor[:walls] + [[10, 8]]))

    assert_equal open_way, past_a_barrel, "the wall ahead is where it was, not where the barrel is"
    assert_operator stopped, :<, past_a_barrel, "and a real wall there would be nearer and taller"
  end

  # ---------------------------------------------------------------- what stops you

  # Walking east from the middle for long enough to cross two whole cells. A barrel two cells
  # along should leave the player short of it; a puddle should not.
  WALKING = 40

  def test_a_barrel_stops_you_walking_into_it
    stopped = walk_east(things: { [10, 8] => BARREL })

    assert_operator stopped, :<, 10.0, "a barrel is not a wall, and it stops you like one"
  end

  def test_a_puddle_lets_you_walk_over_it
    crossed = walk_east(things: { [10, 8] => PUDDLE })

    assert_operator crossed, :>, 10.0, "and the ones that do not block are walked through"
  end

  def test_you_walk_under_a_chandelier
    crossed = walk_east(things: { [10, 8] => CHANDELIER })

    assert_operator crossed, :>, 10.0, "a hanging lamp is above your head"
  end

  # A guard is stopped by a barrel exactly as you are, which is what keeps him out of the
  # furniture. He is put down walking a beat, so he sets off on his own.
  #
  # The player is walled into a corner of the field for this one, because a guard who can walk
  # nowhere is left facing NO WAY — and a guard facing no way can see all of them. That is the
  # original's own quirk, and it would turn a test about walking into a test about being seen.
  def test_a_barrel_stops_a_guard_too
    walking = Guards::PATROLLING + Guards::FACINGS.index(:east)
    hemmed = watch(frames: WALKING, player: HIDING, walls: CLOSET,
                   things: { [8, 8] => walking, [9, 8] => BARREL })
    free = watch(frames: WALKING, player: HIDING, walls: CLOSET,
                 things: { [8, 8] => walking })

    assert_in_delta 8.5, guard_x(hemmed), 0.01, "he cannot set off into the barrel"
    assert_operator guard_x(free), :>, 9.0, "and with nothing there he walks away"
  end

  # ---------------------------------------------------------------- picking one up

  # A key is a piece of scenery like a lamp is, so taking it has to take it off the floor.
  #
  # Walk over it, turn round and look back at where it was: standing ON a thing is too close to
  # draw it, so the only way to ask whether it is still there is from a step or two away.
  WALK_OVER = 25
  ABOUT_TURN = ((FP::TURN / 2) / FP::TURN_SPEED.to_f).ceil + 2

  def test_a_key_you_have_picked_up_stops_being_drawn
    lying_there = look_at(things: { [9, 8] => GOLD_KEY })
    taken = Reference.new.input_each_frame { |f| f < WALK_OVER ? [:up] : [:left] }
                     .run(view_of(arena(things: { [9, 8] => GOLD_KEY })),
                          frames: WALK_OVER + ABOUT_TURN)

    refute_empty columns_of(lying_there, GOLD_KEY), "it is on the floor to start with"
    assert_equal 1, taken[:keys], "and walking over it puts it in your pocket"
    assert_empty columns_of(taken, GOLD_KEY), "so it is not lying there any more"
  end

  # ---------------------------------------------------------------- and on the console

  # THE CARTRIDGE DRAWS IT TOO, and the whole picture is held against the interpreter's rather
  # than the lamp alone. Two things standing in one room is what makes this worth its own check:
  # the queue that puts them in order is code the interpreter and the console each run their own
  # way, and one strip drawn in the wrong order would show here as a pixel that differs.
  #
  # The guard faces away so that he neither notices the player nor moves, which is what lets the
  # two backends be read at different frames and still be looking at the same room.
  def test_the_console_draws_a_guard_behind_a_lamp_the_way_the_interpreter_does
    program = view_of(arena(things: { [10, 8] => CEILING_LIGHT }, guards: [[13, 8, :east]]))
    interp = Reference.new.run(program, frames: 3)
    rom = ROM.assemble(GBA.new.lower(program), title: "LAMP", code: "ZLMP", maker: "01")
    gba = RubyGBA::Verifier.new(rom, frames: 12)

    refute_empty guard_columns(interp), "the interpreter draws him through the gap, so there is a match to make"
    differ = (0...240).to_a.product((0...160).to_a).reject do |x, y|
      (interp.screen.pixel(x, y) || 0) == gba.pixel_gba(x, y)
    end

    assert_empty differ.first(8), "these pixels differ between the interpreter and the console"
  end

  private

  # Where the player is far enough off to be seen by nobody: across the room, off the guard's
  # row, and with a wall across the line between them.
  HIDING = [2, 12].freeze
  CLOSET = [[3, 11], [3, 12], [3, 13]].freeze

  def picture_of(code) = Scenery::FIRST_PICTURE + Scenery::PICTURES.fetch(code - Scenery::FIRST_CODE)
  def blocks?(code) = Scenery.new(arena(things: { [12, 8] => code })).blocks?(12, 8)

  def fixture = @fixture ||= Release.new
  def vswap = @vswap ||= Wolf3D::Vswap.new(fixture.files["VSWAP"])
  def palette = Wolf3D::Palette.game

  # A walled field with a floor inside it, the player where you put them, and whatever else you
  # name. The same arena the guards are tested in.
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
    scenery = Scenery.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, palette, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, palette, (guards.pictures + scenery.pictures).uniq.sort)

    RubyGBA.game("SCENERY", code: "ASCN", maker: "01") do
      screen :bitmap, tear_free: true
      view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas, doors: doors,
                                     pushwalls: pushwalls, guards: guards, things: things,
                                     scenery: scenery)
      game_loop { drawing ? view.update : view.play }
    end.program
  end

  # Stand where the level says and look. Nothing moves, so two frames settle it.
  def look_at(**) = Reference.new.run(view_of(arena(**)), frames: 2)

  # Run the game without drawing it, for the tests that watch what moved rather than what it
  # looked like.
  def watch(frames:, **)
    Reference.new.run(view_of(arena(**), drawing: false), frames: frames)
  end

  ONE = (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

  # Hold the forward button and see how far east the player gets.
  def walk_east(**)
    run = Reference.new.input_each_frame { [:up] }
                  .run(view_of(arena(**), drawing: false), frames: WALKING)
    run[:px] / ONE
  end

  def guard_x(run) = run.instance_variable_get(:@lists)[:__pool_guard_x].get(0) / ONE

  # How many standing things the frame that just finished queued up to draw.
  def queued(run) = run[:_seen]

  # The flat colour the fixture gave the picture a code wears, and which strips of the screen
  # are showing it.
  def colour_of(code) = palette[Release::SPRITE_INK + picture_of(code)]

  def columns_of(run, code, row: EYE_LINE)
    ink = colour_of(code)
    (0...240).select { |x| run.screen.pixel(x, row) == ink }
  end

  # Which rows of the whole screen show a picture anywhere along them. For a thing whose art is
  # not on the eye line — a lamp hanging above it — that is the only way to ask whether it was
  # drawn at all, without naming a row and hoping.
  def rows_of(run, code)
    ink = colour_of(code)
    (0...160).select { |y| (0...240).any? { |x| run.screen.pixel(x, y) == ink } }
  end

  def guard_colours
    @guard_colours ||= (0...Guards::POSES).map do |n|
      palette[Release::SPRITE_INK + Guards::FIRST_STANDING_PICTURE + n]
    end
  end

  def guard_columns(run, row: EYE_LINE)
    (0...240).select { |x| guard_colours.include?(run.screen.pixel(x, row)) }
  end

  # How far down the middle of the screen the ceiling reaches, which is the top edge of the wall
  # the ray met — near walls are tall and start high, far walls short and start low.
  def ceiling_ends(run, x: 120)
    (0...FP::HORIZON).find { |y| run.screen.pixel(x, y) != FP::CEILING } || FP::HORIZON
  end
end
