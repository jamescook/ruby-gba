# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_sprite"

# A sprite on the Advance's cartridge, read back in the emulator: it restores the scenery it
# passes and moves when the test holds a button. What every run is held to is in
# test/all/vblank/builder/test_sprite.rb.
class TestSpriteCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include SpriteGames

  def test_it_restores_patterned_scenery_on_the_console
    rom = ROM.assemble(GBA.new.lower(scenery_program(frames: 25)), title: "SPRSCEN", code: "BSPS", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 26)
    assert v.pixel_is?(31, 45, :blue), "blue detail not restored on hardware — got #{v.pixel_gba(31, 45).to_s(16)}"
    assert v.red?(15, 46), "red band not restored on hardware"
  end

  def test_the_sprite_renders_and_moves_on_the_console
    prog = sprite_program(frames: 30) { |hero| held(:right).then { hero.x.add! 2 } }
    rom = ROM.assemble(GBA.new.lower(prog), title: "SPRITETS", code: "BSPT", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 12, keys: KEY_RIGHT)
    # it moved off its start (that cell is field again) and shows red further right
    assert v.blue?(START[0] + 1, START[1] + 1), "start cell not restored on hardware"
    moved = (START[0] + BLOCK..200).any? { |x| v.pixel_is?(x, START[1] + 1, :red) }
    assert moved, "sprite not found to the right on hardware"
  end
end
