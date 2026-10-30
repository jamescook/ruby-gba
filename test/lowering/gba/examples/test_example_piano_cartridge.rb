# frozen_string_literal: true

require "test_helper"

require "stringio"
require VBlank.root.join("examples/piano").to_s

# examples/piano.rb on the Advance's cartridge: both hands render with the right colours and it
# is audible in the emulator. What the piano does on every run that plays the Advance's games is
# in test/console/gba/examples/test_example_piano.rb.
class TestExamplePianoCartridge < Minitest::Test
  WHITE = Color.resolve(:white)
  SKIN  = Color.rgb(31, 23, 17)

  # --- hardware: both hands render with the right colors and it's audible on the emulator ---

  def test_it_renders_and_sounds_on_the_console
    rom = Piano.build_rom(out: StringIO.new, err: StringIO.new)
    v = assert_emulator_loads_rom(rom, frames: 8)

    # The see-through slot of the sprite palette must be exactly 0 — a byte-shifted
    # palette (the odd-length-sample DMA bug) would make this non-zero and tint
    # every sprite. The regression guard for that fix, read off hardware.
    assert_equal 0x0000, v.mem16(0x0500_0200), "sprite palette slot 0 must be see-through (palette not byte-shifted)"

    assert v.pixel_is?(48, 95, SKIN),   "the left (chord) hand should be skin-colored"
    assert v.pixel_is?(160, 95, SKIN),  "the right (melody) hand should be skin-colored"
    assert v.pixel_is?(100, 150, WHITE), "the keyboard's white keys should be white"
    assert v.sound?, "the piano should be audible (energy #{v.audio_energy})"
  end
end
