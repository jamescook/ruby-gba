# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_directional_animation"

# A sprite's per-direction animation on the Advance's cartridge, read back in the emulator. What
# every run is held to is in test/all/vblank/dsl/test_directional_animation.rb.
class TestDirectionalAnimationCartridge < Minitest::Test
  include DirectionalAnimationGames

  # --- real hardware: the composed pose renders on the console ---

  def test_on_console_the_faced_direction_composites
    rom = ROM.assemble(GBA.new.lower(walker(mode: :tiled, face: :down, run: 3)),
                       title: "DIRANIM", code: "BDIR", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3)
    assert v.blue?(44, 44), "facing down, the console should composite a down-facing frame (blue), got #{v.pixel_gba(44, 44).to_s(16)}"
  end
end
