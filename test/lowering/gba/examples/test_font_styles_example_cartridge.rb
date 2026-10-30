# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/font_styles").to_s

# The font-styles example's cartridge: the three fonts render on the console, read in the
# emulator. What the game shows is in test/console/gba/examples/test_font_styles_example.rb.
class TestFontStylesExampleCartridge < Minitest::Test
  def test_it_renders_on_hardware
    rom = ROM.assemble(GBA.new.lower(FontStyles.program), title: "FONTSTY", code: "BFSY", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3)
    assert (8..60).any? { |x| (12..18).any? { |y| v.white?(x, y) } }, "default HELLO missing on hardware"
    assert (8..60).any? { |x| (40..44).any? { |y| v.green?(x, y) } }, "lowercase hello missing on hardware"
    assert (8..60).any? { |x| (64..68).any? { |y| v.pixel_is?(x, y, :cyan) } }, "script hello missing on hardware"
  end
end
