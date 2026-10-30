# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/builder/test_layer_two_amounts_on_the_advance"

# A see-through layer per screen on the Advance's cartridge, read back in the emulator as the
# game moves from one screen to the other. What the two amounts do on every run that plays the
# Advance's games is in test/console/gba/vblank/builder/test_layer_two_amounts_on_the_advance.rb.
class TestLayerTwoAmountsOnTheAdvanceCartridge < Minitest::Test
  include LayerTwoAmountsGames

  def test_the_console_gives_each_screen_its_own_mix
    keys = ->(frame) { frame.between?(3, 4) ? VBlank::Console::Hardware::KEY_A : 0 }
    v = assert_emulator_loads_rom(assemble_rom(two_screens_program, name: "SCREENS"), frames: 12, keys: keys)
    assert_equal rgb5(*BRIGHT_MIXED), v.pixel_gba(*DIM), "the file screen's window"

    v.step(2, keys: VBlank::Console::Hardware::KEY_B)
    v.step(4)
    assert_equal title_pixel, v.pixel_gba(*DIM), "back on the title, the rays' own mix"
  end
end
