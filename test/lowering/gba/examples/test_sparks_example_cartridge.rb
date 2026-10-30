# frozen_string_literal: true

require "test_helper"
require "stringio"

require VBlank.root.join("examples/sparks").to_s

# The sparks example (examples/sparks.rb) on the Advance's own cartridge: a spark is on its
# screen, read in the emulator. What the shower does on every run that plays the Advance is in
# test/console/gba/examples/test_sparks_example.rb.
class TestSparksExampleCartridge < Minitest::Test
  YELLOW = Color.resolve(:yellow)

  def test_the_console_draws_the_shower_too
    rom = Sparks.build_rom(out: StringIO.new, err: StringIO.new)
    v = assert_emulator_loads_rom(rom, frames: 30)

    assert v.frame_gba.include?(YELLOW), "a spark is on the console's screen"
  end
end
