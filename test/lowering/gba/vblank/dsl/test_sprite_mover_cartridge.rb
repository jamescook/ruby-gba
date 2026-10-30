# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_sprite_mover"

# The sprite-mover example in miniature on the Advance's cartridge: the heart games of
# test/all/vblank/dsl/test_sprite_mover.rb, read in the emulator.
class TestSpriteMoverCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include SpriteMoverGames

  def test_runs_on_hardware
    machine_code = VBlank::IR::Backends::GBA.new.lower(sprite_program(frames: 4))
    rom = VBlank::Cartridge::ROM.assemble(machine_code, title: "SPRITEMV", code: "BSPM", maker: "01")

    v = assert_emulator_loads_rom(rom, frames: 6, keys: KEY_RIGHT)
    assert v.red?(109, 60),   "the heart is drawn after moving right"
    assert v.white?(108, 60), "its transparent corner shows the white field"
  end

  def test_hardware_clips_the_heart_at_the_left_edge
    rom = VBlank::Cartridge::ROM.assemble(
      VBlank::IR::Backends::GBA.new.lower(heart_at_left_edge(frames: 3)),
      title: "SPRITEMV", code: "BSPM", maker: "01",
    )
    v = assert_emulator_loads_rom(rom, frames: 5, keys: KEY_LEFT)
    EDGE_PIXELS.each do |x, y, color|
      x = edge_column(x, VBlank::Console::ADVANCE.screen_width)
      assert v.pixel_is?(x, y, color || :white),
             "console: (#{x}, #{y}) should be #{color || 'background'}, got 0x#{format('%04X', v.pixel_gba(x, y))}"
    end
  end
end
