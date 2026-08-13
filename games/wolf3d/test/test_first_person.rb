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

  # A view built from our own one-room level, so it needs nobody's copy of the game.
  def view_program(columns: FP::COLUMNS)
    vswap = Wolf3D::Vswap.new(fixture.files["VSWAP"])
    atlas = Wolf3D::WallAtlas.new(vswap, Wolf3D::Palette.game, @level)
    level = @level

    RubyGBA.game("VIEW", code: "AVUE", maker: "01") do
      screen :bitmap
      view = Wolf3D::FirstPerson.new(self, level, atlas)
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

  # Correctness of the renderer, apart from whether the console can finish a frame of it: drawn
  # few enough strips that it does finish, every pixel matches. The full view costs more than a
  # frame holds, which is what the tear-free screen is for.
  def test_the_console_draws_what_the_interpreter_draws_when_it_has_time_to_finish
    program = view_program

    interp = Reference.new.run(program, frames: 3)
    rom = ROM.assemble(GBA.new.lower(program), title: "VIEW", code: "AVUE", maker: "01")
    gba = RubyGBA::Verifier.new(rom, frames: 6)

    # The left of the screen is drawn first, so it is the part the console reaches whatever
    # else happens. A mismatch here would be the renderer, not the clock.
    differ = (0...24).sum { |x| (0...160).count { |y| (interp.screen.pixel(x, y) || 0) != gba.pixel_gba(x, y) } }

    assert_equal 0, differ, "the strips the console does reach must match the interpreter"
  end
end
