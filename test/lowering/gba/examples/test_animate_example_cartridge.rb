# frozen_string_literal: true

require "test_helper"

require "stringio"
require VBlank.root.join("examples/animate").to_s

# The Animate example's cartridge (examples/animate.rb): it builds, and the coin renders on the
# console, read in the emulator. What the game shows is in
# test/console/gba/examples/test_animate_example.rb.
class TestAnimateExampleCartridge < Minitest::Test
  # The coin's centre column is gold on every frame of the spin (only its width
  # changes), so it's a stable point to find it.
  CENTRE = [119, 79].freeze

  def test_it_builds_a_rom
    assert_operator Animate.build_rom(err: StringIO.new).size, :>, 0, "the built ROM should be non-empty"
  end

  def test_the_coin_renders_on_the_console
    rom = ROM.assemble(GBA.new.lower(Animate.program), title: "ANIMATE", code: "BANM", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3)
    assert v.pixel_is?(*CENTRE, :yellow), "the coin renders on hardware, got 0x#{format('%04X', v.pixel_gba(*CENTRE))}"
  end
end
