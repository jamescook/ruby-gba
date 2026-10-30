# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_tiled_collision"

# A sprite `blocked_by` a background on the Advance's cartridge, read in the emulator. What
# collision does on every run is in test/all/vblank/dsl/test_tiled_collision.rb.
class TestTiledCollisionCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include TiledCollisionGames

  private def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "COLLIDE", code: "BCOL", maker: "01")
  end

  def test_blocked_by_stops_the_sprite_on_the_console
    v = assert_emulator_loads_rom(rom_for(walk_into_wall), frames: 30, keys: KEY_RIGHT)
    assert v.red?(28, 20),  "the hero stops flush against the wall, got 0x#{format('%04X', v.pixel_gba(28, 20))}"
    assert v.blue?(36, 20), "the wall is at x32, got 0x#{format('%04X', v.pixel_gba(36, 20))}"
    refute v.red?(36, 20),  "the hero never crossed into the wall"
  end
end
