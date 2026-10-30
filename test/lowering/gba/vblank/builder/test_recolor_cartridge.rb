# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_recolor"

# A RECOLORED SPRITE ON THE ADVANCE'S CARTRIDGE, read in the emulator. What `recolor` does on
# every run is in test/all/vblank/builder/test_recolor.rb.
class TestRecolorCartridge < Minitest::Test
  include RecolorGames

  # The console's own pixels, read off the cartridge rather than compared with the
  # interpreter's, so the two cannot agree on showing nothing.
  def test_the_console_shows_the_colors_the_list_holds_now
    recolored = program { |_ship| recolor :slot, :warm }
    v = assert_emulator_loads_rom(assemble_rom(recolored, name: "RECOLOR"), frames: 6)

    assert v.pixel_is?(41, 41, :yellow), "the left half is #{v.pixel_gba(41, 41)}"
    assert v.pixel_is?(45, 41, :orange), "the right half is #{v.pixel_gba(45, 41)}"
  end
end
