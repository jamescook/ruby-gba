# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/floating_digits").to_s

# The floating-digits example on the Advance's cartridge, read back in the emulator. What the
# digits do on every run that plays the Advance's games is in
# test/console/gba/examples/test_floating_digits_example.rb.
class TestFloatingDigitsExampleCartridge < Minitest::Test
  # It renders on the console: digit 0 (the only red one) shows up along its early
  # top-left path.
  def test_it_renders_on_hardware
    rom = ROM.assemble(GBA.new.lower(FloatingDigits.program), title: "FLOATNUM", code: "BFLN", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 6)
    red = (4..30).any? { |y| (8..60).any? { |x| v.pixel_is?(x, y, Color.rgb(31, 0, 0)) } }
    assert red, "expected the red digit 0 somewhere along its early top-left path"
  end
end
