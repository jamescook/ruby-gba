# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_tiled_text"

# Tiled-mode text on the Advance's cartridge, read in the emulator. What the text shows, asked
# of every run, is in test/all/vblank/builder/test_tiled_text.rb.
class TestTiledTextCartridge < Minitest::Test
  include TiledTextGames

  # ...and the console does the same thing with it. The emulator runs one boot frame
  # before the loop a tiled program's first present happens in, so the console is a
  # frame ahead of the interpreter's count (see Differential::BOOT_FRAMES).
  def test_a_blinking_prompt_blinks_on_the_console
    prog = blinking_prompt_program
    rom = ROM.assemble(GBA.new.lower(prog), title: "BLINK", code: "BBLI", maker: "01")
    on = assert_emulator_loads_rom(rom, frames: 2)
    off = assert_emulator_loads_rom(rom, frames: 3)

    assert lit_pixels(on, "A", 100, 20).all? { |x, y| on.white?(x, y) }, "the plain label shows"
    assert lit_pixels(on, "B", 140, 20).all? { |x, y| on.white?(x, y) }, "the prompt shows while blink is 1"
    assert lit_pixels(off, "A", 100, 20).all? { |x, y| off.white?(x, y) }, "the plain label still shows"
    refute lit_pixels(off, "B", 140, 20).any? { |x, y| off.white?(x, y) }, "the prompt is gone while blink is 0"
  end

  # The screen coordinates of every lit pixel of +char+'s glyph drawn at (gx, gy).
  private def lit_pixels(_verifier, char, gx, gy)
    pixels = []
    Fonts.get(:default).each_pixel(char) { |dx, dy| pixels << [gx + dx, gy + dy] }
    pixels
  end

  # --- hardware: the same HUD renders on the console ---

  def test_the_hud_renders_on_the_console
    prog = hud_program do
      var :score, 42
      draw_number :score, 100, 20, :white, digits: 2
    end
    rom = ROM.assemble(GBA.new.lower(prog), title: "HUD", code: "BHUD", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3)
    cell = Fonts.get(:default).cell_w
    # A lit pixel of "4" and of "2" should be white on the real framebuffer.
    Fonts.get(:default).each_pixel("4") do |dx, dy|
      assert v.white?(100 + dx, 20 + dy), "‘4’ pixel (#{dx},#{dy}) on hardware"
      break
    end
    Fonts.get(:default).each_pixel("2") do |dx, dy|
      assert v.white?(100 + cell + dx, 20 + dy), "‘2’ pixel (#{dx},#{dy}) on hardware"
      break
    end
  end
end
