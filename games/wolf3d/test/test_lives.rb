# frozen_string_literal: true

require_relative "test_helper"

# HOW MANY GOES YOU GET, and what a go costs: the floor goes back to the way it was built.
#
# Two halves, tested apart because they cost so differently. COUNTING the goes needs nothing but
# a death, so it is driven the way test_dying drives one — struck, turn, fizzle — over a bare
# screen, and three whole deaths run in a moment. PUTTING THE FLOOR BACK needs a real floor with
# a door and a key and a guard on it, and the fixture release has exactly that; those tests ask
# for the floor to be started again by name and then look at what changed.
class TestLives < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Dying = Wolf3D::Dying
  Lives = Wolf3D::Lives

  # HOW LONG TO LEAVE BETWEEN ONE DEATH AND THE NEXT: comfortably longer than a whole one takes
  # (the turn toward the killer, the settle, and the fizzle), so a test that asks for two deaths
  # gets exactly two. What is actually driven is a BUTTON — see #counting_program — so the number
  # only has to be generous, and nothing here depends on how many passes a death really takes.
  BETWEEN_DEATHS = Dying::MOST_TURNS + Dying::SETTLE + Dying::FRAMES + 20

  WHITE = Wolf3D::Palette.game[Lives::INK]
  RED = Wolf3D::Palette.game[Dying::INK]

  # ---------------------------------------------------------------- counting the goes

  # A death and nothing else, over and over. The floor being started again is stood in for by a
  # counter, because what it really does belongs to the view and is tested against the real
  # thing further down — all this one needs of it is that it is asked for.
  def counting_program
    RubyGBA.game("LIVES", code: "ZLIV", maker: "01") do
      screen :bitmap, tear_free: true
      sin = table :sin, (0...FP::TURN).map { |a| Math.sin(a * 2 * Math::PI / FP::TURN) }
      px = var :px, 8.5
      py = var :py, 8.5
      angle = var :view, 0
      killer = Struct.new(:x, :y).new(var(:kx, 8.5), var(:ky, 4.5))
      score = var :score, 500
      restarts = var :restarts, 0

      dying = Dying.new(build: self, eye: { x: px, y: py, angle: angle, sin: sin })
      lives = Lives.new(build: self, score: score, dying: dying)
      func(:start_the_floor) do
        restarts.add 1
        dying.start_again
      end

      game_loop do
        dying.turn
        # STRUCK ON A BUTTON rather than whenever there is a go going spare, so the test says how
        # many deaths it wants instead of working out how many frames one takes.
        pressed(:b).then { dying.struck_by(killer) }
        dying.draw
        lives.update
      end
    end.program
  end

  # +times+ deaths, one every BETWEEN_DEATHS passes, with the reading taken at the end of the
  # last of them. Anything else pressed comes from +pressing+.
  def dying_over(times, pressing: nil)
    struck = ->(f) { (f % BETWEEN_DEATHS) == 5 ? [:b] : [] }
    Reference.new
             .input_each_frame { |f| struck.call(f) + (pressing&.call(f) || []) }
             .run(counting_program, frames: BETWEEN_DEATHS * times)
  end

  def test_dying_spends_one_go_and_starts_the_floor_again
    ran = dying_over(1)

    assert_equal Lives::START - 1, ran[:lives], "one go should have gone"
    assert_equal 1, ran[:restarts], "and the floor should have been asked to start again"
    assert_equal Dying::ALIVE, ran[:dying], "with the death put back to the beginning"
  end

  def test_each_death_spends_one_more
    twice = dying_over(2)

    assert_equal Lives::START - 2, twice[:lives]
    assert_equal 2, twice[:restarts]
  end

  # THE LAST GO IS DIFFERENT: there is nothing to put back, so the floor is not started again and
  # the game says it is over. Without that the same finished death would take a go off on every
  # pass after it and the count would run away below nothing.
  def test_the_last_death_ends_the_game_rather_than_starting_the_floor
    ran = dying_over(4) # ...one more death than there are goes, so a fourth cannot be spent

    assert_equal 0, ran[:lives], "every go spent, and none past that"
    assert_equal 1, ran[:game_over], "and the game over"
    assert_equal Lives::START - 1, ran[:restarts],
                 "the last death starts nothing, so there is one restart fewer than deaths"
  end

  def test_the_words_only_show_once_the_game_is_over
    playing = dying_over(2)
    over = dying_over(4)

    assert_equal 0, white_pixels(playing), "nothing is written over a game still being played"
    assert_operator white_pixels(over), :>, 20, "and GAME OVER is written over one that is not"
  end

  # A NEW GAME IS THE SAME MACHINERY AS A NEW LIFE plus the two things a life does not touch: the
  # goes go back to three and the score back to nothing.
  def test_pressing_start_on_a_finished_game_begins_another
    over = dying_over(4)
    again = dying_over(4, pressing: ->(f) { f > (BETWEEN_DEATHS * 3) + 100 ? [:start] : [] })

    assert_equal 500, over[:score], "the score is left alone by dying..."
    assert_equal 0, again[:score], "...and cleared by a new game"
    assert_equal 0, again[:game_over], "which is no longer over"
    assert_operator again[:lives], :>, 0, "and has goes left in it"
  end

  # ---------------------------------------------------------------- putting the floor back

  # THE FIXTURE RELEASE IS THE RIGHT FLOOR FOR THIS, because it holds one of everything that
  # changes: a door, a locked door with its key lying beside the player, a wall that slides, and
  # a guard. Nothing is drawn — every question below is about what the floor holds, and drawing
  # it costs about a hundred times what playing it does.
  #
  # THE ONE THAT HAS TO DRAW is the one that SHOOTS: a shot goes to a man the renderer put on the
  # screen, so with nothing drawn nobody is ever on it and nothing can be shot.
  def floor_program(restart_at:, drawn: false)
    level = fixture_level
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Wolf3D::Guards.new(level)
    scenery = Wolf3D::Scenery.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, palette, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, palette, (guards.pictures + scenery.pictures).uniq.sort)

    RubyGBA.game("FLOOR", code: "ZFLR", maker: "01") do
      screen :bitmap, tear_free: true
      view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas, doors: doors,
                                     pushwalls: pushwalls, guards: guards, things: things,
                                     scenery: scenery)
      passes = var :passes, 0
      game_loop do
        drawn ? view.update : view.play
        passes.add 1
        # The floor is asked for by name, which is the same thing a spent life asks for. Driving
        # it this way rather than by standing in front of a guard until he finishes you off is
        # what keeps these quick: a real death is several hundred frames away.
        (passes == restart_at).then { call :start_the_floor }
      end
    end.program
  end

  # Play +script+ and take two readings: the pass before the floor is started again, and the pass
  # it happens on. Nothing runs after that one, because whatever the script is holding down would
  # start changing the fresh floor immediately — walk over the key again, open the door again.
  def either_side_of_a_restart(at:, drawn: false, &script)
    [at - 1, at].map do |until_frame|
      runner = Reference.new
      runner = runner.input_each_frame(&script) if script
      runner.run(floor_program(restart_at: at, drawn: drawn), frames: until_frame)
    end
  end

  # The key lies one cell north of the player, who starts facing north.
  def test_a_key_you_picked_up_is_lying_on_the_floor_again
    took, back = either_side_of_a_restart(at: 30) { [:up] }

    assert_operator took[:keys], :>, 0, "walking over the key should have picked it up"
    assert_equal 1, list(took, :thing_gone, key_piece), "and taken it off the floor"
    assert_equal 0, back[:keys], "and starting the floor again should hand it back"
    assert_equal 0, list(back, :thing_gone, key_piece), "and put it where it was lying"
  end

  # Turn about, walk at the door in the room's south wall, and open it.
  def test_a_door_you_opened_is_shut_again
    opened, back = either_side_of_a_restart(at: 120) do |f|
      next [:left] if f <= about_turn
      next %i[up a] if f == about_turn + 40

      [:up]
    end

    assert_operator open_of(opened, room_door), :>, 0.5, "the door should be well open by then"
    assert_in_delta 0.0, open_of(back, room_door), 0.0001, "and shut again on a fresh floor"
  end

  # The wall that slides is in the room's east wall, so it takes a quarter turn to the right and
  # a walk up to it to lean on.
  def test_a_secret_wall_you_shoved_is_where_it_was_built
    shoved, back = either_side_of_a_restart(at: 130) do |f|
      next [:right] if f <= quarter_turn
      next %i[up a] if f == quarter_turn + 42

      [:up]
    end

    assert_operator list(shoved, :push_gone, 0) + list(shoved, :push_wait, 0), :>, 0,
                    "leaning on it should have set it going"
    assert_equal 0, list(back, :push_gone, 0), "and it should be back where it was built"
    assert_equal 0, list(back, :push_step, 0)
    assert_equal 0, list(back, :push_wait, 0)
  end

  # The guard stands two cells east of the player, who starts facing north — so this turns to
  # face him and empties the pistol into him. The one test on this floor that draws, because
  # shooting a man needs him to have been on the screen.
  def test_a_guard_you_killed_is_standing_again
    killed, back = either_side_of_a_restart(at: 250, drawn: true) do |f|
      next [:right] if f <= quarter_turn
      next [:b] if f > quarter_turn && f.even?

      []
    end

    assert_operator pool(killed, :hp), :<=, 0, "eight bullets at two cells should finish him"
    assert_equal Wolf3D::Guards::HIT_POINTS, pool(back, :hp), "and a fresh floor stands him up"
    assert_equal Wolf3D::Behaviour.for([:guard]).starting_state(guard_zero), pool(back, :state),
                 "in the state the level put him in"
    assert_in_delta guard_zero.x + 0.5, pool(back, :x) / ONE, 0.0001, "where the level put him"
  end

  # WALKED DIAGONALLY, and that is the whole reason the script turns first. The player starts
  # facing north, so walking straight ahead moves them along ONE axis — and a test of putting
  # them back that only ever moved one of the two says nothing about the other. Half a quarter
  # turn to the right puts them on a corner of the compass, so both axes move.
  def test_the_player_is_put_back_where_the_level_starts_them
    walked, back = either_side_of_a_restart(at: 40) do |f|
      f <= quarter_turn / 2 ? [:right] : [:up]
    end
    start = fixture_level.start

    refute_in_delta start.x + 0.5, walked[:px] / ONE, 0.2, "the walk should have moved them across"
    refute_in_delta start.y + 0.5, walked[:py] / ONE, 0.2, "...and up the map"
    assert_in_delta start.x + 0.5, back[:px] / ONE, 0.0001
    assert_in_delta start.y + 0.5, back[:py] / ONE, 0.0001
    assert_equal FP::START_HEALTH, back[:health], "with a hundred of health"
    assert_equal FP::START_AMMO, back[:ammo], "and a full pistol"
  end

  # ...and WHICH WAY THEY FACE, which is not the same question: a player who died looking at the
  # guard who shot them starts the floor again looking the way the level points them. Held against
  # the angle the game boots with rather than against a number, so the test does not restate the
  # table that turns a facing into an angle.
  def test_the_player_is_put_back_facing_the_way_the_level_points_them
    turned, back = either_side_of_a_restart(at: 40) { [:right] }
    booted = Reference.new.run(floor_program(restart_at: 0), frames: 1)

    refute_equal booted[:view], turned[:view], "the turn should have moved where they look"
    assert_equal booted[:view], back[:view]
  end

  # ---------------------------------------------------------------- and the two together

  # THE WHOLE THING END TO END, which is the only test here that proves the two halves are wired
  # to each other: stand in a ring of guards and let them finish you, and the floor comes back
  # with a hundred of health and one go fewer. It is the dear one — every frame of it draws the
  # whole view — so there is one of it and it is sized to the moment just after the first death.
  def test_being_killed_really_does_start_the_floor_again
    ran = Reference.new.run(ringed_program, frames: 200)

    assert_equal Lives::START - 1, ran[:lives], "one go spent"
    assert_equal FP::START_HEALTH, ran[:health], "and a fresh hundred of health"
    assert_equal Dying::ALIVE, ran[:dying], "playing again rather than still dying"
    assert_equal 0, ran[:game_over], "and nowhere near the end of the game"
  end

  private

  ONE = (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

  def fixture = @fixture ||= Wolf3D::Fixture::Release.new
  def vswap = @vswap ||= Wolf3D::Vswap.new(fixture.files["VSWAP"])
  def palette = Wolf3D::Palette.game

  def fixture_level
    @fixture_level ||= Wolf3D::Maps.new(maphead: fixture.files["MAPHEAD"],
                                        gamemaps: fixture.files["GAMEMAPS"])[0]
  end

  def guard_zero = Wolf3D::Guards.new(fixture_level).guards.first

  # The room's own door, the one the player can reach; the other is in the outer border.
  def room_door
    @room_door ||= Wolf3D::Doors.new(fixture_level, vswap)
                                .doors.index { |door| door.y > fixture_level.start.y }
  end

  # Which piece of scenery the key is, so that its being drawn again can be checked as well as
  # its being back on the floor.
  def key_piece = Wolf3D::Scenery.new(fixture_level).index_at(*key_cell)

  def key_cell
    at = Wolf3D::Fixture::Release.new.key_cell
    [at % Wolf3D::Fixture::Release::GRID, at / Wolf3D::Fixture::Release::GRID]
  end

  def quarter_turn = ((FP::TURN / 4) / FP::TURN_SPEED.to_f).ceil
  def about_turn = ((FP::TURN / 2) / FP::TURN_SPEED.to_f).ceil

  def list(run, name, index) = run.instance_variable_get(:@lists)[name].get(index)
  def pool(run, field, slot = 0) = list(run, :"__pool_guard_#{field}", slot)
  def open_of(run, index) = list(run, :door_open, index) / ONE

  def white_pixels(run)
    (0...FP::ACROSS).to_a.product((0...FP::VIEW_H).to_a)
                    .count { |x, y| run.screen.pixel(x, y) == WHITE }
  end

  # A ring of guards close enough to finish the player quickly, which is what makes the end-to-end
  # test above affordable: one guard takes several hundred frames to do it, and six take a fifth
  # of that.
  RING = [[9, 8, :west], [7, 8, :east], [8, 9, :north], [8, 7, :south],
          [9, 9, :west], [7, 7, :east]].freeze
  SIDE = 16

  def ringed_program
    level = ringed_level
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Wolf3D::Guards.new(level)
    scenery = Wolf3D::Scenery.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, palette, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, palette, (guards.pictures + scenery.pictures).uniq.sort)

    RubyGBA.game("RING", code: "ZRNG", maker: "01") do
      screen :bitmap, tear_free: true
      view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas, doors: doors,
                                     pushwalls: pushwalls, guards: guards, things: things,
                                     scenery: scenery)
      game_loop { view.update }
    end.program
  end

  def ringed_level
    wall = Wolf3D::Fixture::Release::WALL
    cells = Array.new(SIDE * SIDE, Wolf3D::Level::FLOOR)
    standing = Array.new(SIDE * SIDE, 0)
    SIDE.times do |y|
      SIDE.times do |x|
        cells[(y * SIDE) + x] = wall if x.zero? || y.zero? || x == SIDE - 1 || y == SIDE - 1
      end
    end
    standing[(8 * SIDE) + 8] = Wolf3D::Level::FACINGS.key(:east)
    RING.each do |x, y, way|
      standing[(y * SIDE) + x] = Wolf3D::Guards::STANDING + Wolf3D::Guards::FACINGS.index(way)
    end
    Wolf3D::Level.new(name: "Ring", width: SIDE, height: SIDE, walls: cells, things: standing)
  end
end
