# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_sprite_animation"

# A FLIPBOOK ON THE ADVANCE'S CARTRIDGE, read in the emulator a few frames apart. The flipbook as
# every run plays it is in test/all/vblank/builder/test_sprite_animation.rb.
class TestSpriteAnimationCartridge < Minitest::Test
  include SpriteAnimationGames

  private def rom_for(program)
    ROM.assemble(GBA.new.lower(program), title: "ANIM", code: "BANM", maker: "01")
  end

  def test_a_flipbook_declared_inside_a_scene_cycles_on_the_console
    %i[tiled bitmap].each do |mode|
      red = assert_emulator_loads_rom(rom_for(blinker(mode: mode, run: 4, in_scene: true)), frames: 6)
      assert red.red?(44, 44), "#{mode}: the first frame renders red, got 0x#{format('%04X', red.pixel_gba(44, 44))}"
      blue = assert_emulator_loads_rom(rom_for(blinker(mode: mode, run: 6, in_scene: true)), frames: 8)
      assert blue.blue?(44, 44), "#{mode}: it has flipped to blue, got 0x#{format('%04X', blue.pixel_gba(44, 44))}"
    end
  end

  def test_a_hardware_flipbook_cycles_on_the_console
    red  = assert_emulator_loads_rom(rom_for(blinker(mode: :tiled, run: 4)), frames: 6)
    assert red.red?(44, 44), "the first frame renders red, got 0x#{format('%04X', red.pixel_gba(44, 44))}"
    blue = assert_emulator_loads_rom(rom_for(blinker(mode: :tiled, run: 6)), frames: 8)
    assert blue.blue?(44, 44), "it has flipped to blue, got 0x#{format('%04X', blue.pixel_gba(44, 44))}"
  end

  def test_a_software_flipbook_cycles_on_the_console
    red  = assert_emulator_loads_rom(rom_for(blinker(mode: :bitmap, run: 4)), frames: 6)
    assert red.red?(44, 44), "the first frame renders red, got 0x#{format('%04X', red.pixel_gba(44, 44))}"
    blue = assert_emulator_loads_rom(rom_for(blinker(mode: :bitmap, run: 6)), frames: 8)
    assert blue.blue?(44, 44), "it has flipped to blue, got 0x#{format('%04X', blue.pixel_gba(44, 44))}"
  end
end
