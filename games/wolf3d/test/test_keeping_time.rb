# frozen_string_literal: true

require_relative "test_helper"

# WHAT THE WORLD'S MOVEMENT IS FIXED AGAINST — both settings of it.
#
# Everything that moves here moves a fixed amount: the player walks a fraction of a cell, a
# door swings a little wider, a guard's state machine advances. The question is what that fixed
# amount is fixed AGAINST.
#
# Against a PASS of the game loop, a game too heavy for one frame plays in slow motion —
# smoothly, uniformly, and at the wrong speed. Against a FRAME of the screen, it keeps real
# time and what a heavy frame costs is a jerkier picture. Wolfenstein does the second (it moves
# you `BASEMOVE * MOVESCALE * tics`, where tics is how long the last frame took), so a player
# crossing a corridor in the original crosses it in the same number of SECONDS whatever the
# game is doing.
#
# ON A GAME THAT KEEPS UP THE TWO ARE THE SAME THING, exactly, so all of this is about a game
# that does not. This one does not yet, and it ships paced by the pass — see
# FirstPerson::PACING for the measurement behind that. Both settings are tested here, because a
# setting nothing exercises is a setting that has quietly stopped working.
#
# THE INTERPRETER IS NEVER LATE BY CONSTRUCTION, so it is TOLD — `frames_each_pass` is how a
# test says a pass answered for more than one frame. That is what makes all of this checkable
# in-process, where before it would have needed a console burned past its frame.
class TestKeepingTime < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Guards = Wolf3D::Guards
  Release = Wolf3D::Fixture::Release

  SIDE = 16
  FLOOR = Wolf3D::Level::FLOOR
  WALL = Release::WALL
  ONE = (1 << RubyGBA::Fraction::DEFAULT_BITS).to_f

  # A walled field with the player in it, facing east — so walking forward raises px and the
  # wall down the east side is what eventually stops them.
  def arena(player: [8, 8], facing: :east, guards: [])
    cells = Array.new(SIDE * SIDE, FLOOR)
    standing = Array.new(SIDE * SIDE, 0)
    SIDE.times do |y|
      SIDE.times do |x|
        cells[(y * SIDE) + x] = WALL if x.zero? || y.zero? || x == SIDE - 1 || y == SIDE - 1
      end
    end
    standing[(player[1] * SIDE) + player[0]] = Wolf3D::Level::FACINGS.key(facing)
    guards.each do |x, y, way|
      standing[(y * SIDE) + x] = Guards::STANDING + Guards::FACINGS.index(way)
    end

    Wolf3D::Level.new(name: "Arena", width: SIDE, height: SIDE, walls: cells, things: standing)
  end

  def fixture = @fixture ||= Release.new
  def vswap = @vswap ||= Wolf3D::Vswap.new(fixture.files["VSWAP"])

  # Which way the world is paced is settled while the game is BUILT, so it has to be in force
  # while the program is made rather than while it runs.
  def paced(how)
    was = FP::PACING
    FP.send(:remove_const, :PACING)
    FP.const_set(:PACING, how)
    yield
  ensure
    FP.send(:remove_const, :PACING)
    FP.const_set(:PACING, was)
  end

  # The game with no picture at all, which is what every test here wants: they read where the
  # player got to, not what they saw on the way.
  def game(level, pacing: :by_the_frame)
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Guards.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, Wolf3D::Palette.game, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, Wolf3D::Palette.game, guards.pictures)

    paced(pacing) do
      RubyGBA.game("TIME", code: "ZTIM", maker: "01") do
        screen :bitmap, tear_free: true
        view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas, doors: doors,
                                       pushwalls: pushwalls, guards: guards, things: things)
        game_loop { view.play }
      end.program
    end
  end

  # Hold forward for +passes+ passes of the game loop, each of which answered for +late+ frames.
  def walk_forward(passes:, late: 1, pacing: :by_the_frame, **arena_args)
    Reference.new.hold(:up).frames_each_pass { late }
             .run(game(arena(**arena_args), pacing: pacing), frames: passes)
  end

  def where(run) = run[:px] / ONE

  # --- the setting the game ships with -------------------------------------------------

  # PACED BY THE PASS, a late pass moves the world exactly as far as a prompt one — the game
  # runs in slow motion rather than in bigger steps. That is what this game is set to, and it is
  # here first because it is the one a player is actually getting.
  def test_paced_by_the_pass_a_late_frame_moves_no_further_than_a_prompt_one
    prompt = walk_forward(passes: 8, pacing: :by_the_pass)
    late = walk_forward(passes: 8, late: 3, pacing: :by_the_pass)

    assert_in_delta where(prompt), where(late), 0.001,
                    "eight passes is eight steps however many frames each of them took"
    assert_operator where(prompt), :>, 8.5, "...and they really did move"
  end

  # ...and that is what the game is built as, so nothing has to be forced to get it.
  def test_the_game_ships_paced_by_the_pass
    assert_equal :by_the_pass, FP::PACING
  end

  # --- and the other setting: the same seconds, whatever the frame rate -----------------

  # THE ONE THE BEAD ASKS FOR. Twenty-four frames of the screen go by either way: as
  # twenty-four passes on a game that keeps up, or as eight passes on one that takes three
  # frames over each. The player is in the same place, because they walked for the same length
  # of TIME. Paced by the pass, the slow game would be a third of the way there.
  def test_walking_covers_the_same_ground_in_the_same_seconds_however_slow_the_game_is
    keeping_up = walk_forward(passes: 24)
    struggling = walk_forward(passes: 8, late: 3)

    assert_in_delta where(keeping_up), where(struggling), 0.001,
                    "twenty-four frames of walking, whether that took eight passes or twenty-four"
    assert_operator where(keeping_up), :>, 8.5, "...and they really did move"
  end

  # ...and the slow motion it replaces, said plainly: counted per PASS, eight passes is eight
  # steps, and the game is at a third speed. This is what the game did before, and what a game
  # gets by default — it is the safe answer, not a wrong one — so it is worth being able to see
  # the difference rather than trusting that there is one.
  def test_counted_per_pass_the_same_eight_passes_would_be_a_third_of_the_way
    eight_passes_of_walking = walk_forward(passes: 8)
    eight_late_passes = walk_forward(passes: 8, late: 3)

    assert_in_delta (where(eight_late_passes) - 8.5) / 3,
                    where(eight_passes_of_walking) - 8.5, 0.01,
                    "a third as far, which is exactly what pacing by the pass would have given"
  end

  # A hitch is one late pass and not the next, and the walk answers for the frames it really
  # got rather than for a rate fixed in advance.
  def test_one_slow_pass_is_made_up_and_the_rest_are_not
    steady = walk_forward(passes: 12)
    hitched = Reference.new.hold(:up).frames_each_pass { |pass| pass == 3 ? 5 : 1 }
                       .run(game(arena), frames: 8)

    assert_in_delta where(steady), where(hitched), 0.001,
                    "eight passes, one of them worth five frames, is twelve frames of walking"
  end

  # --- and what a late pass still cannot do --------------------------------------------

  # A LONG FRAME CANNOT PUT YOU THROUGH A WALL, and here that is true by construction. The
  # original multiplies its step by how late it is, so a big step could straddle a wall between
  # one collision test and the next and it caps the lateness to stop that (MAXTICS). This runs
  # the ordinary step again instead, each one with its own test, so there is no big step to
  # guard — and the cap is still there underneath, held by the framework.
  #
  # Walking east from the middle of the field at the most lateness there is, this asks for
  # about fifty cells of movement into a wall seven cells away.
  def test_the_latest_pass_there_can_be_still_stops_at_the_wall
    ran = walk_forward(passes: 70, late: 100) # held at the cap, whatever a test asks for

    assert_operator where(ran), :<, SIDE - 1,
                    "the wall is the last cell, and no amount of catching up may cross it"
    assert_operator where(ran), :>, SIDE - 2, "...but they should be right up against it"
  end

  # --- a press is a press, however late the pass ---------------------------------------

  # THE HALF THAT DOES NOT GO ON THE CLOCK, and it is why the two halves are split rather than
  # the whole frame being replayed. A button read on its edge has to be read once per PRESS. Run
  # the trigger on the clock and one pull of it would fire a bullet for every frame the pass
  # answered for — five bullets for one press, and only on the frames the game was struggling.
  #
  # LONG ENOUGH FOR THE ROUND TO LEAVE, which is not the same as long enough for the press: a
  # shot is four stages of six passes and the round goes on the second of them, so the pass that
  # spends the bullet is a dozen after the pass that asked for it. See Weapons.
  def test_one_pull_of_the_trigger_is_one_bullet_however_late_the_pass
    ran = Reference.new.input_each_frame { |pass| pass == 3 ? [:b] : [] }
                   .frames_each_pass { 5 }
                   .run(game(arena(guards: [[12, 8, :west]])), frames: Wolf3D::Weapons::CYCLE)

    assert_equal FP::START_AMMO - 1, ran[:ammo], "one press, one bullet"
  end
end
