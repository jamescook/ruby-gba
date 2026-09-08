# frozen_string_literal: true

require_relative "test_helper"

# The view down the corridor. These tests are about the ray and the picture, not about whether
# the console finishes a frame — that is a separate question and a separate bead.
class TestFirstPerson < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson

  def setup
    @level = Wolf3D::Maps.new(maphead: fixture.files["MAPHEAD"],
                              gamemaps: fixture.files["GAMEMAPS"])[0]
  end

  def fixture = @fixture ||= Wolf3D::Fixture::Release.new

  # A view built from our own one-room level, so it needs nobody's copy of the game. On the
  # tear-free screen, which is the one the game itself draws on.
  def view_program
    @view_program ||= build_the_view
  end

  def build_the_view
    vswap = Wolf3D::Vswap.new(fixture.files["VSWAP"])
    doors = Wolf3D::Doors.new(@level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(@level)
    atlas = Wolf3D::WallAtlas.new(vswap, Wolf3D::Palette.game, @level, doors: doors)
    level = @level

    RubyGBA.game("VIEW", code: "AVUE", maker: "01") do
      screen :bitmap, tear_free: true
      view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas, doors: doors, pushwalls: pushwalls)
      game_loop { view.update }
    end.program
  end

  def test_the_atlas_holds_only_the_walls_the_level_builds_with
    atlas = Wolf3D::WallAtlas.new(Wolf3D::Vswap.new(fixture.files["VSWAP"]),
                                  Wolf3D::Palette.game, @level)

    assert_equal [Wolf3D::Fixture::Release::WALL], atlas.codes
    assert_equal 2 * 64, atlas.width, "two pictures per wall, lit and dark"
    assert_equal 64, atlas.height
  end

  # A wall picture's two forms sit next to each other in the file, lit first.
  def test_a_wall_code_finds_both_of_its_pictures
    atlas = Wolf3D::WallAtlas.new(Wolf3D::Vswap.new(fixture.files["VSWAP"]),
                                  Wolf3D::Palette.game, @level)
    code = Wolf3D::Fixture::Release::WALL

    assert_equal 0, atlas.slice_for(code, Wolf3D::WallAtlas::LIT)
    assert_equal 64, atlas.slice_for(code, Wolf3D::WallAtlas::DARK)
  end

  def test_it_draws_a_ceiling_a_floor_and_walls_between_them
    run = Reference.new.run(view_program, frames: 3)

    assert_equal FP::CEILING, run.screen.pixel(120, 2), "ceiling at the top"
    assert_equal FP::FLOOR_COLOR, run.screen.pixel(120, FP::VIEW_H - 2), "floor at the bottom"
    assert_equal Wolf3D::Palette.game[Wolf3D::StatusBar::GROUND], run.screen.pixel(2, 158),
                 "and the status bar under the view, not more floor"

    band = (40...110).count { |y| ![FP::CEILING, FP::FLOOR_COLOR].include?(run.screen.pixel(120, y)) }
    assert_operator band, :>, 4, "a wall should stand around the eye line"
  end

  # The player is put where the level says, so a room with walls all round shows one from
  # wherever it starts.
  def test_the_view_starts_where_the_level_puts_the_player
    run = Reference.new.run(view_program, frames: 3)
    lit = (0...240).count do |x|
      (40...110).any? { |y| ![FP::CEILING, FP::FLOOR_COLOR].include?(run.screen.pixel(x, y)) }
    end

    assert_operator lit, :>, 100, "most strips should meet a wall in a closed room"
  end

  # THE WHOLE SCREEN, both backends. This used to be able to check only the left of the view:
  # the console could not finish a frame of it, so the strips on the right were simply not
  # there to compare. Walking the ray to the grid line instead of in fixed steps took the
  # frame under budget, so the whole picture can now be held against the interpreter.
  def test_the_console_draws_what_the_interpreter_draws
    program = view_program

    interp = Reference.new.run(program, frames: 3)
    rom = ROM.assemble(GBA.new.lower(program), title: "VIEW", code: "AVUE", maker: "01")
    gba = RubyGBA::Verifier.new(rom, frames: 6)

    differ = (0...240).to_a.product((0...160).to_a).reject do |x, y|
      (interp.screen.pixel(x, y) || 0) == gba.pixel_gba(x, y)
    end

    assert_empty differ.first(8), "these pixels differ between the interpreter and the console"
  end

  # A flat wall square-on stands at ONE distance, so every strip across it must be the same
  # height and its top edge must be a straight line. That is what the walk to the grid line
  # buys: a fixed-step walk reports the distance in lumps, and dividing by it turns a lump
  # into a jump of several pixels, so the wall arrives as a staircase.
  def test_a_flat_wall_has_a_straight_top_edge
    run = Reference.new.run(view_program, frames: 3)

    tops = (60...180).map { |x| (0...FP::HORIZON).find { |y| run.screen.pixel(x, y) != FP::CEILING } }

    refute_includes tops, nil, "every strip across the middle should meet the wall ahead"
    assert_equal 1, tops.uniq.length,
                 "a flat wall square-on should stand at one height, got #{tops.uniq.sort.inspect}"
  end

  # A WALL YOU ARE PRESSED AGAINST STILL FILLS THE SCREEN, and this is the one that used to fail.
  #
  # A column's height is one number divided by the distance, and the numbers here run out at
  # about 32768. Nearer than about a fiftieth of a cell that division has nothing left to give,
  # and rounding the answer to the nearest pixel then adds a half to a number with no room for
  # one — which turns it NEGATIVE. A negative height draws nothing at all, so a player who
  # stepped one pace too close saw straight through the wall, and the same number is what the
  # room's standing things read to know what is in front of them: every guard on the floor showed
  # through it too.
  #
  # TURNED FIRST, AND THAT IS THE WHOLE OF WHY IT WAS HARD TO SEE. How far a step moves each axis
  # depends on the angle, and a player stops on the last step that keeps their feet out of the
  # wall — so where that leaves them is the remainder of the distance divided by the step, which
  # is a different sliver for every approach. Walking straight in leaves seven hundredths of a
  # cell and looks fine. Eleven turn-steps first leaves almost nothing, and the wall vanishes.
  #
  # Read along the eye line, which crosses whatever is ahead at every distance.
  SEE_THROUGH_TURNS = 11

  def pressed_against_a_wall(frames)
    ->(f) { f <= SEE_THROUGH_TURNS ? [:left] : [:up] }
  end

  def test_a_wall_you_are_pressed_against_still_fills_the_screen
    run = Reference.new.input_each_frame(&pressed_against_a_wall(0))
                   .run(view_program, frames: SEE_THROUGH_TURNS + 180)
    through = (0...FP::ACROSS).count do |x|
      [FP::CEILING, FP::FLOOR_COLOR].include?(run.screen.pixel(x, FP::HORIZON))
    end

    assert_equal 0, through, "#{through} strips of the eye line are showing through the wall"
  end

  # THE WALLS MUST NOT JUDDER AS YOU WALK, and this is the test that the two distances a ray
  # starts from are the right way round.
  #
  # A ray begins by asking how far it is to the first grid line it will cross, and the answer
  # comes from where the eye stands inside its own cell: for a ray leaning back it is the part of
  # the cell already behind you, for one leaning forward the part still ahead. Use the wrong one
  # of the pair and the wall comes out at the wrong distance — by nothing at all while the player
  # stands in the middle of a cell, by nearly a whole cell at its edge, and back to nothing at the
  # next cell. So the picture stays a perfectly good flat wall the whole time. What gives it away
  # is that the wall JUMPS every time the player crosses a grid line.
  #
  # WALKED AT AN ANGLE, not straight at a wall, and that is the point of this test existing beside
  # the ones above. A ray aimed square at a wall crosses grid lines one way only: the distance
  # along the other axis is never the nearer one, so it never decides anything and a wrong answer
  # there cannot show. Facing a corner, both axes are in play on every ray.
  # ALL FOUR CORNERS OF THE ROOM, one walk each, because a ray leaning back along an axis and one
  # leaning forward ask for different halves of the cell the eye stands in. A fan pointed into one
  # corner leans the same way on both axes for every ray in it, so one corner exercises one of the
  # four pairs and says nothing about the other three.
  CORNERS = [[:left, 11], [:right, 11], [:left, 33], [:right, 33]].freeze
  WALKING_FRAMES = 14 # steps after the turn: far enough to carry the eye over a grid line
  JUDDER = 3          # pixels a strip's top edge may move in one frame at this walking speed

  def test_the_walls_do_not_jump_as_you_walk_over_a_grid_line
    CORNERS.each do |turning, turns|
      seen = top_edges_walking_into(turning, turns)

      seen.each { |tops| refute_includes tops, nil, "every strip should meet a wall in a closed room" }
      moved = seen.each_cons(2).flat_map do |before, after|
        before.zip(after).map { |was, now| (now - was).abs }
      end

      assert_operator moved.max, :<=, JUDDER,
                      "turning #{turning} #{turns} times, a strip's top edge moved " \
                      "#{moved.max} pixels in a single step"
    end
  end

  # Turn into a corner, then walk at it, keeping the top edge of every fourth strip on each frame.
  def top_edges_walking_into(turning, turns)
    run = Reference.new
    seen = []
    run.input_each_frame { |frame| frame <= turns ? [turning] : [:up] }
       .each_vblank { |frame| seen << top_edges(run) if frame > turns }
       .run(view_program, frames: turns + WALKING_FRAMES)
    seen
  end

  def top_edges(run)
    (0...FP::ACROSS).step(4).map do |x|
      (0...FP::HORIZON).find { |y| run.screen.pixel(x, y) != FP::CEILING }
    end
  end

  # NO CONSOLE TEST OF THE SAME WALK, and that is a decision rather than an omission. The console
  # does not start counting frames where the interpreter does — it powers on and runs the
  # program's setup first — so the same script of buttons leaves the player on a different sliver
  # of floor, and which sliver is the whole trigger. A console version of the walk above passed
  # whether the fix was there or not, which is worse than no test.
  #
  # What makes the one above enough is that the arithmetic underneath it is the SAME arithmetic
  # on both, to the bit: the saturating divide and the rounding that overflows it are pinned
  # across the backends in the framework's own suite. So the oracle can be trusted to speak for
  # the cartridge here.
end
