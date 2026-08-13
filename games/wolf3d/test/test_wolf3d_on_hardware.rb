# frozen_string_literal: true

require_relative "test_helper"

# The real cartridge, in the emulator. Reached through RubyGBA::Verifier rather than the
# framework's own test support, because a game outside the framework cannot reach into its test
# directory — and this one is here to feel that constraint.
class TestWolf3DOnHardware < Minitest::Test
  include Wolf3DTest

  # Read after the tear-free screen has a picture to show. This screen draws out of sight
  # and shows the page whole, so nothing at all is on screen until the first pass finishes
  # — and a pass of this view takes more than one frame. Before that the player sees the
  # page nobody has drawn on, which is black. Measured: black through frame 4, the picture
  # from frame 5 on, and steady from there.
  FIRST_DRAWN_FRAME = 6

  def test_the_cartridge_boots_and_draws_something
    rom = Wolf3D.build_rom(out: StringIO.new, err: StringIO.new)
    gba = RubyGBA::Verifier.new(rom, frames: FIRST_DRAWN_FRAME)

    refute gba.all_black?, "the cartridge booted to a black screen"
  end

  # The holding screen, on the console, in a cartridge of its own — so it is tested whether or
  # not a copy of the game is here for the real one to draw instead.
  def test_the_holding_screen_blinks_on_the_console
    rom = RubyGBA.build("TITLE", code: "ATTL", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      screen_title = Wolf3D::Title.new(self)
      game_loop { screen_title.update }
    end

    showing = lit_pixels(RubyGBA::Verifier.new(rom, frames: 4), 100, 112)
    gone = lit_pixels(RubyGBA::Verifier.new(rom, frames: 70), 100, 112)

    assert_operator showing, :>, 0, "expected the prompt early in the cycle"
    assert_equal 0, gone, "expected the prompt to be dark later in the cycle"
  end

  private

  def lit_pixels(gba, top, bottom)
    backdrop = gba.pixel_gba(0, 0)
    (0...240).sum { |x| (top...bottom).count { |y| gba.pixel_gba(x, y) != backdrop } }
  end
end

# The map seen from above and the game's colours, in a cartridge of their own. They used to be
# tested through the whole game, which stopped drawing them the moment it had a first-person
# view to draw instead — the same trap the holding screen fell into.
class TestMapViewOnHardware < Minitest::Test
  include Wolf3DTest

  # A cartridge that draws only what these tests are about.
  def views_rom(level)
    palette = Wolf3D.palette
    RubyGBA.build("VIEWS", code: "AVWS", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      map = Wolf3D::MapView.new(self, level).declare
      colours = Wolf3D::PaletteView.new(self, palette).declare
      map.draw
      colours.draw
      game_loop { halt }
    end
  end

  def test_the_first_level_draws_where_the_grid_says
    game_data_or_skip
    level = Wolf3D.maps[0]
    view = Wolf3D::MapView
    gba = RubyGBA::Verifier.new(views_rom(level), frames: 4)

    start = level.start
    assert_equal view::START, gba.pixel_gba(view::ORIGIN_X + (start.x * view::SCALE),
                                            view::ORIGIN_Y + (start.y * view::SCALE))

    # A cell the level calls solid must not be drawn in a floor or door colour.
    refute_includes [view::FLOOR, view::DOOR],
                    gba.pixel_gba(view::ORIGIN_X, view::ORIGIN_Y)

    # And the screen either side of the map is left alone.
    refute_equal view::FLOOR, gba.pixel_gba(4, 100)
  end

  # The game's own colours, on the console, read back one by one.
  def test_the_games_own_colours_reach_the_screen
    game_data_or_skip
    palette = Wolf3D.palette
    view = Wolf3D::PaletteView
    gba = RubyGBA::Verifier.new(views_rom(Wolf3D.maps[0]), frames: 4)

    [0, 1, 16, 255].each do |index|
      x = view::ORIGIN_X + ((index % view::ACROSS) * view::CELL)
      y = view::ORIGIN_Y + ((index / view::ACROSS) * view::CELL)

      assert_equal palette[index], gba.pixel_gba(x, y), "colour #{index} on screen"
    end
  end
end
