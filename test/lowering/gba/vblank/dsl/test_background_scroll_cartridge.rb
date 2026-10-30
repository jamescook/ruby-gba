# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_background_scroll"

# Scrolling a tiled background on the Advance's cartridge, read back in the emulator. What every
# run is held to is in test/all/vblank/dsl/test_background_scroll.rb.
class TestBackgroundScrollCartridge < Minitest::Test
  include BackgroundScrollGames

  private def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "SCROLL", code: "BSCR", maker: "01")
  end

  def test_scrolling_on_the_console
    still = assert_emulator_loads_rom(rom_for(world_scrolled_to(0, 0)), frames: 3)
    assert still.red?(84, 84), "at rest the landmark is at (80,80), got 0x#{format('%04X', still.pixel_gba(84, 84))}"

    moved = assert_emulator_loads_rom(rom_for(world_scrolled_to(40, 0)), frames: 3)
    assert moved.red?(44, 84), "scrolled right, the landmark slid left, got 0x#{format('%04X', moved.pixel_gba(44, 84))}"
  end

  def test_scrolling_with_a_sprite_on_the_console
    v = assert_emulator_loads_rom(rom_for(scroll_with_hero), frames: 25)
    assert v.green?(104, 64),
           "the hero renders over the scrolling world on hardware, got 0x#{format('%04X', v.pixel_gba(104, 64))}"
    assert v.red?(44, 84),
           "the world scrolled under it on hardware, got 0x#{format('%04X', v.pixel_gba(44, 84))}"
  end
end
