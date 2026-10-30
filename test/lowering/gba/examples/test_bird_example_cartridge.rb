# frozen_string_literal: true

require "test_helper"
require "console/gba/examples/test_bird_example"

# The Bird example (examples/bird.rb) on the Advance's cartridge, read back in the emulator.
# What the game does on every run is in test/console/gba/examples/test_bird_example.rb.
class TestBirdExampleCartridge < Minitest::Test
  include BirdExamplePictures

  def test_the_bird_renders_on_the_console
    # The bird's tiles are stored packed in the ROM and expanded into video memory by
    # the BIOS at boot. That one-time expansion costs the first frame, so the sprite
    # first appears a frame later than an uncompressed one would — give it headroom.
    v = assert_emulator_loads_rom(Bird.build_rom(out: StringIO.new, err: StringIO.new), frames: 6)
    assert bird_over_sky?(->(x, y) { v.pixel_gba(x, y) }), "the bird should composite over the sky on hardware"
  end
end
