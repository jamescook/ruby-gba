# frozen_string_literal: true

require "test_helper"
require "stringio"
require "console/gba/examples/test_clock_example"

# The clock example (examples/clock.rb) on the Advance's cartridge: the emulator's clock chip set
# to a moment, and the face the cartridge paints from it. What the face shows on every run that
# plays the Advance is in test/console/gba/examples/test_clock_example.rb.
class TestClockExampleCartridge < Minitest::Test
  include ClockExampleReading

  def test_the_console_shows_the_time_its_clock_chip_reads
    require_emulator!
    rom = ClockFace.build_rom(out: StringIO.new, err: StringIO.new)
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 10, clock: THURSDAY)

    assert pixels_say?("21:07:05", ClockFace::TIME_ROW, ClockFace::BIG) { |x, y| v.pixel_gba(x, y) },
           "the cartridge read its chip and painted the time"
  end
end
