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
    assert_equal FP::FLOOR_COLOR, run.screen.pixel(120, 158), "floor at the bottom"

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
end
