# frozen_string_literal: true

require "test_helper"
require "console/gba/examples/test_lake_example"

# The lake example on the Advance's cartridge, read back in the emulator: the console draws the
# same lake. What the example draws on every run that plays the Advance's games is in
# test/console/gba/examples/test_lake_example.rb.
class TestLakeExampleCartridge < Minitest::Test
  include LakeColors

  # Asked as "which colours are on the lake" rather than "what is at this pixel", because
  # the jellyfish drift a pixel or two every frame and the two backends do not start
  # counting frames at the same moment. The claim does not need a coordinate: a bell that
  # was not blending would put its own flat colour on screen and no blend anywhere.
  def test_the_console_blends_the_jellyfish_into_the_lake
    require_emulator!
    seen = VBlank::Diagnostics::Verifier.new(assemble_rom(Lake.program, name: "LAKE"), frames: 9).frame_gba.uniq

    refute_empty seen & BELL_OVER_ANY_WATER, "the console draws a bell with the water mixed in"
    refute_includes seen, BELL, "and no pixel of a bell is its own colour"
  end
end
