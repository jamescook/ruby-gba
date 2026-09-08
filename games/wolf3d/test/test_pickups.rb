# frozen_string_literal: true

require_relative "test_helper"

# THINGS ON THE FLOOR YOU PICK UP BY WALKING OVER THEM.
#
# Nearly all of it is played without drawing, because every question here is about what the player
# is carrying rather than what the screen shows, and drawing the view costs about a hundred times
# what playing it does. The two that ARE about the picture — the clip a dead guard leaves, and the
# cartridge agreeing with the oracle — say so.
class TestPickups < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Scenery = Wolf3D::Scenery
  Pickups = Wolf3D::Pickups
  Guards = Wolf3D::Guards
  Release = Wolf3D::Fixture::Release

  # WHERE EACH PIECE SITS in the original's own list of them. What each GIVES is Scenery::BONUSES,
  # which is what these tests are about; these are only which piece is which.
  GOOD_FOOD = 24
  FIRST_AID = 25
  CLIP = Scenery::CLIP
  CROSS = 29
  CHALICE = 30
  BIBLE = 31
  CROWN = 32
  ONE_UP = 33
  SCRAPS = 34

  FLOOR = Wolf3D::Level::FLOOR
  WALL = Release::WALL

  # How many frames a whole cell of walking takes, and a little over so a walk of N cells really
  # arrives. A step is FP::WALK of a cell.
  def cells(n) = ((n / FP::WALK).ceil + 4)

  # ---------------------------------------------------------------- ammunition

  def test_walking_over_a_clip_adds_ammunition_and_takes_it_off_the_floor
    run = walk_east_over([CLIP], cells: 2)

    assert_equal FP::START_AMMO + 8, run[:ammo], "a clip is eight rounds, which is the original's"
    assert_equal 1, gone(run, 0), "and the clip is off the floor"
  end

  # A LINE OF CLIPS WALKED END TO END, which is the only way to reach the cap without being shot
  # at: it takes twelve to fill ninety-nine rounds from the eight you start with. The thirteenth
  # is the one this is really about — a player who cannot hold it leaves it where it is.
  ENOUGH_CLIPS = 13

  def test_ammunition_stops_at_the_cap_and_the_clip_that_would_not_fit_is_left_alone
    run = walk_east_over(Array.new(ENOUGH_CLIPS) { CLIP }, cells: ENOUGH_CLIPS + 1, side: 24)

    assert_equal Pickups::MOST_AMMO, run[:ammo], "ninety-nine rounds and no more"
    assert_equal 1, gone(run, ENOUGH_CLIPS - 2), "the one before last still fitted"
    assert_equal 0, gone(run, ENOUGH_CLIPS - 1),
                  "and the last is still lying there, waiting until it is wanted"
  end

  # ---------------------------------------------------------------- treasure

  # ALL FOUR IN ONE WALK, which pins every one of the original's numbers at once: a cross is a
  # hundred, a chalice five, a bible ten and a crown fifty.
  def test_the_four_treasures_are_worth_what_the_original_says
    run = walk_east_over([CROSS, CHALICE, BIBLE, CROWN], cells: 5)

    assert_equal 100 + 500 + 1000 + 5000, run[:score]
    assert_equal [1, 1, 1, 1], (0..3).map { |piece| gone(run, piece) }
  end

  # ---------------------------------------------------------------- health

  # A FULL PLAYER LEAVES IT WHERE IT IS. This is the one that is easy to get wrong and very
  # noticeable: take the box at a hundred of health and it is gone when you come back needing it.
  def test_a_first_aid_box_is_left_alone_by_a_player_who_does_not_need_it
    run = walk_east_over([FIRST_AID], cells: 2)

    assert_equal FP::START_HEALTH, run[:health], "there was nothing to heal"
    assert_equal 0, gone(run, 0), "so the box is still on the floor"
  end

  # ...AND IS TAKEN THE MOMENT THERE IS. The only thing in this game that takes health off you is
  # being shot, so this one needs a guard: stand on the box and let him hit you.
  #
  # HELD AGAINST THE SAME GAME WITH NOTHING ON THAT CELL rather than against a number, because how
  # much a guard takes off you is a roll of the dice. Both runs roll the same dice in the same
  # order — nothing about picking a thing up asks for a random number — so what is left between
  # them is exactly what the box gave.
  def test_a_first_aid_box_is_taken_as_soon_as_a_shot_has_landed
    under_fire = 260
    healed = shot_at_standing_on(FIRST_AID, frames: under_fire)
    bare = shot_at_standing_on(nil, frames: under_fire)

    assert_operator bare[:health], :<, FP::START_HEALTH, "the guard should have hit you by then"
    assert_equal bare[:health] + 25, healed[:health], "a first aid box is twenty-five"
    assert_equal 1, gone(healed, 0), "and it is off the floor once it has been used"
  end

  # WHAT IS LEFT OF SOMEBODY heals one, and only when you are NEARLY DEAD — anything over ten of
  # health and you cannot bring yourself to take it.
  #
  # SHOT AT FIRST, and it has to be: a player at a hundred is refused by the ordinary "you are
  # already full" rule that every kind of health follows, so a healthy player says nothing about
  # whether this one has a rule of its own. Half dead is where the two answers differ — food is
  # taken there and this is not.
  def test_what_is_left_of_somebody_is_stepped_over_by_a_player_who_is_only_half_dead
    hurt = shot_at_standing_on(SCRAPS, frames: 260)

    assert_operator hurt[:health], :>, Pickups::NEARLY_DEAD, "hurt, but not nearly dead"
    assert_operator hurt[:health], :<, FP::START_HEALTH, "and hurt enough for food to be welcome"
    assert_equal 0, gone(hurt, 0), "still on the floor, for a player who is worse off than this"
  end

  # THE ONE-UP, which is the only thing on a floor that hands you another go. It is never refused:
  # it fills the health of a player who was already full, and there is always room for a go.
  def test_a_one_up_fills_you_up_and_hands_you_another_go
    run = walk_east_over([ONE_UP], cells: 2)

    assert_equal Wolf3D::Lives::START + 1, run[:lives]
    assert_equal FP::START_HEALTH, run[:health]
    assert_equal 1, gone(run, 0)
  end

  def test_good_food_is_worth_what_the_original_says
    under_fire = 260
    fed = shot_at_standing_on(GOOD_FOOD, frames: under_fire)
    bare = shot_at_standing_on(nil, frames: under_fire)

    assert_equal bare[:health] + 10, fed[:health], "good food is ten"
  end

  # ---------------------------------------------------------------- what a guard leaves

  # THE LOOP THE WHOLE GAME RUNS ON: shoot a guard, take what he was carrying, shoot the next one.
  # Without it the game hands you eight rounds and nothing else ever.
  #
  # Read as two moments of the same walk — the guard down and not yet walked over, then walked
  # over — so what changed between them is only the clip.
  def test_a_guard_who_falls_leaves_a_clip_where_he_fell
    down = shoot_then_walk(frames: 60)
    took = shoot_then_walk(frames: 120)

    assert_equal 0, pool(down, :hp), "he should be down by then" if pool(down, :hp).positive?
    assert_equal 1, pool(down, :dropped), "and lying beside what he was carrying"
    assert_equal 0, pool(took, :dropped), "which is gone once you have walked over it"
    assert_equal down[:ammo] + Pickups::DROPPED_ROUNDS, took[:ammo],
                 "half a clip, which is the original's own number"
  end

  # ...AND IT IS THERE TO SEE. The fixture paints every picture one flat colour of its own, so a
  # pixel of the clip's colour on the screen says that picture and no other was drawn.
  #
  # HELD AGAINST THE SAME WALK WITH THE TRIGGER NEVER PULLED rather than against an earlier frame
  # of the same one. At this range one round puts a guard down, so "before he falls" is a window
  # too narrow to aim a test at; a guard who is never shot at never falls.
  #
  # AND IT STOPS BEFORE THE PLAYER REACHES THE BODY, which is the whole of why the count is 60
  # and not the 70 the walking test uses: walk onto the clip and it is picked up, and then there
  # is nothing on the floor to see.
  def test_the_clip_a_guard_left_is_drawn_on_the_floor
    standing = Reference.new.input_each_frame { [:up] }
                        .run(shooting_program(drawing: true), frames: 60, max_steps: 8_000_000)
    down = Reference.new.input_each_frame { |f| shoot_at_him(f) }
                    .run(shooting_program(drawing: true), frames: 60, max_steps: 8_000_000)

    refute_includes colours_on_screen(standing), clip_colour, "nobody has dropped anything"
    assert_includes colours_on_screen(down), clip_colour, "and there it is on the floor"
  end

  # ---------------------------------------------------------------- and on the console

  # THE CARTRIDGE PICKS THINGS UP THE WAY THE ORACLE DOES. Everything above is arithmetic on a
  # handful of variables, so this holds those variables against each other rather than pixels: a
  # walk over a clip and two treasures, and the two backends must agree about what is carried.
  def test_the_console_carries_what_the_interpreter_carries
    program = view_of(arena(ahead: [CLIP, CROSS, CROWN]), drawing: true)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "PICKUP", code: "ZPCK", maker: "01")

    # THE CONSOLE IS GIVEN MORE FRAMES, and that is not slack: this game's world moves once per
    # PASS of the game loop, and the cartridge takes two or three frames over a pass where the
    # oracle takes one. Both are walked until the player has crossed everything and come up
    # against the wall at the end, which is a settled state rather than a moment.
    walking = ->(_f) { RubyGBA::Constants::KEY_UP }
    console = RubyGBA::Verifier.new(rom, frames: cells(4) * 4, keys: walking,
                                         vars: backend.var_addresses)
    oracle = Reference.new.input_each_frame { [:up] }
                     .run(program, frames: cells(4), max_steps: 4_000_000)

    assert_equal FP::START_AMMO + 8, oracle[:ammo],
                 "the oracle took the clip, so there is something to compare"
    assert_equal oracle[:ammo], console.var(:ammo)
    assert_equal oracle[:score], console.var(:score)
  end

  private

  ONE = (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

  def fixture = @fixture ||= Release.new
  def vswap = @vswap ||= Wolf3D::Vswap.new(fixture.files["VSWAP"])
  def palette = Wolf3D::Palette.game

  def code(index) = Scenery::FIRST_CODE + index
  def gone(run, piece) = run.instance_variable_get(:@lists)[:thing_gone].get(piece)
  def pool(run, field, slot = 0) = run.instance_variable_get(:@lists)[:"__pool_guard_#{field}"].get(slot)

  # The flat colour the fixture gave the clip's own picture.
  def clip_colour = palette[Release::SPRITE_INK + Scenery.clip_picture]

  def colours_on_screen(run)
    (0...FP::ACROSS).step(2).flat_map { |x| (0...FP::VIEW_H).step(2).map { |y| run.screen.pixel(x, y) } }
                    .uniq
  end

  # A WALLED FIELD with the player on the left of the middle row facing east, and whatever you
  # name laid out on the cells in front of them.
  def arena(ahead: [], side: 16, guards: [], on_the_spot: nil)
    cells = Array.new(side * side, FLOOR)
    standing = Array.new(side * side, 0)
    side.times do |y|
      side.times do |x|
        cells[(y * side) + x] = WALL if x.zero? || y.zero? || x == side - 1 || y == side - 1
      end
    end
    row = side / 2
    start = 4
    standing[(row * side) + start] = Wolf3D::Level::FACINGS.key(:east)
    ahead.each_with_index { |piece, n| standing[(row * side) + start + 1 + n] = code(piece) }
    standing[(row * side) + start + 1] = code(on_the_spot) if on_the_spot
    guards.each { |x, y, way| standing[(y * side) + x] = Guards::STANDING + Guards::FACINGS.index(way) }

    Wolf3D::Level.new(name: "Pickups", width: side, height: side, walls: cells, things: standing)
  end

  def view_of(level, drawing: false)
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Guards.new(level)
    scenery = Scenery.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, palette, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, palette,
                                    (guards.pictures + scenery.pictures +
                                     Pickups.pictures(guards)).uniq.sort)

    RubyGBA.game("PICKUP", code: "ZPCK", maker: "01") do
      screen :bitmap, tear_free: true
      view = FP.new(build: self, level: level, atlas: atlas, doors: doors, pushwalls: pushwalls,
                    guards: guards, things: things, scenery: scenery)
      game_loop { drawing ? view.update : view.play }
    end.program
  end

  def walking_program(ahead, side: 16) = view_of(arena(ahead: ahead, side: side))

  # Walk east over whatever is laid out ahead, far enough to cross +cells+ of them.
  def walk_east_over(ahead, cells:, side: 16)
    Reference.new.input_each_frame { [:up] }
             .run(walking_program(ahead, side: side), frames: cells(cells), max_steps: 4_000_000)
  end

  # STAND ON ONE THING AND BE SHOT AT. The player walks one cell forward onto whatever is there
  # and stays; the guard three cells further on comes and fires. +piece+ may be nil, which is the
  # same walk onto bare floor and is what the readings are held against.
  def shot_at_standing_on(piece, frames:)
    level = arena(on_the_spot: piece, guards: [[8, 8, :west]])
    Reference.new.input_each_frame { |f| f <= cells(1) ? [:up] : [] }
             .run(view_of(level), frames: frames, max_steps: 8_000_000)
  end

  # Empty the pistol into the guard ahead, then walk over what is left of him. The button is read
  # on the press, so it has to go up between shots — and a gun in the middle of a shot does not
  # read it at all, so tapping every other pass is tapping far oftener than the gun will take.
  # That costs nothing and means every pass the gun is ready on is one the button is going down.
  #
  # THE FIRING STOPS WELL BEFORE THE WALK DOES, which the test above depends on: what it measures
  # is the four rounds off the body, so nothing may spend a round after he has fallen.
  def shoot_at_him(frame) = frame < 40 && frame.even? ? [:b] : [:up]

  def shooting_program(drawing: false)
    @shooting_program ||= {}
    @shooting_program[drawing] ||= view_of(arena(guards: [[9, 8, :west]]), drawing: drawing)
  end

  # IT DRAWS, because the guard has to actually fall: a shot goes to a man the renderer put on
  # the screen, so with nothing drawn nobody is ever on it and nothing is ever dropped.
  def shoot_then_walk(frames:)
    Reference.new.input_each_frame { |f| shoot_at_him(f) }
             .run(shooting_program(drawing: true), frames: frames, max_steps: frames * 50_000)
  end
end
