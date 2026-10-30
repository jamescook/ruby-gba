# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_scaled_and_scrolling_backgrounds"

# A background that turns or resizes, BESIDE ordinary scrolling ones, on the Advance's own
# cartridge: the three layers its console shows, and the arrangement its display register is put
# in, read in the emulator. What the build says about such backgrounds is in
# test/all/vblank/builder/test_scaled_and_scrolling_backgrounds.rb, which keeps the pieces both
# files draw with in ScaledAndScrollingBackgroundsGames.
class TestScaledAndScrollingBackgroundsCartridge < Minitest::Test
  include ScaledAndScrollingBackgroundsGames

  # THE ARRANGEMENT ITSELF: two ordinary scrolling layers and one that resizes, all on
  # one screen, all three showing. Built at the size it was drawn (1.0) so the picture
  # reads exactly as authored and each layer is judged by one pixel.
  private def three_layer_program(scale: 1.0)
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue, :blue)
    solid_tile(b, :i_red, :red)
    solid_tile(b, :i_green, :green)
    sky = marked_map(30, 20, {}).map { |row| row.tr(" ", "#") }
    rays = marked_map(30, 20, { [1, 1] => "$" })
    sword = marked_map(32, 32, { [2, 2] => "%" })
    b.instance_eval do
      tiles :t_sky,   "#" => :i_blue
      tiles :t_rays,  "$" => :i_red
      tiles :t_sword, "%" => :i_green
      background :sky,  tiles: :t_sky,  map: sky
      background :rays, tiles: :t_rays, map: rays
      background(:sword, tiles: :t_sword, map: sword).scale(scale)
      halt
    end
    b.finalize_program
    b.program
  end

  # --- Hardware: the console shows the same three layers ---

  def test_the_console_shows_all_three_layers
    v = assert_emulator_loads_rom(assemble_rom(three_layer_program, name: "MIXEDBG3"), frames: 4)
    assert v.blue?(100, 100),  "the backmost scrolling layer fills the screen"
    assert v.red?(12, 12),     "the middle scrolling layer draws over it"
    assert v.green?(20, 20),   "the resizing layer draws over both"
  end

  # ...and it is really the console's mixed arrangement doing it, read off the display
  # register on the running cartridge rather than inferred from the picture. Worth
  # asserting on its own: three layers could look right while one was being drawn some
  # other way, and the whole change is which arrangement the build picks.
  def test_the_console_is_put_in_the_arrangement_that_holds_a_turning_layer
    mixed = assert_emulator_loads_rom(assemble_rom(three_layer_program, name: "MIXEDBG4"), frames: 4)
    assert_equal 1, mixed.mem16(VBlank::Console::Hardware::REG_DISPCNT) & DISPLAY_MODE,
                 "two scrolling layers and one that turns is the console's second arrangement"

    plain = assert_emulator_loads_rom(assemble_rom(scrolling_only_program, name: "PLAINBG4"), frames: 4)
    assert_equal 0, plain.mem16(VBlank::Console::Hardware::REG_DISPCNT) & DISPLAY_MODE,
                 "a game that turns nothing keeps the arrangement with four scrolling layers"
  end

  # The low three bits of the display register say which arrangement the console is in.
  DISPLAY_MODE = 0x7

  # The same three layers with nothing resized — the control for the assertion above.
  private def scrolling_only_program
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue, :blue)
    full = marked_map(30, 20, {}).map { |row| row.tr(" ", "#") }
    b.instance_eval do
      tiles :t, "#" => :i_blue
      background :sky,  tiles: :t, map: full
      background :rays, tiles: :t, map: full
      halt
    end
    b.finalize_program
    b.program
  end
end
