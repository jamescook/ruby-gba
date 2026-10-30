# frozen_string_literal: true

require "test_helper"

require "stringio"
require "console/gba/examples/test_scroll_example"

# The Scroll example's cartridge (examples/scroll.rb): it builds, and the world renders on the
# console, read in the emulator. What the game shows is in
# test/console/gba/examples/test_scroll_example.rb.
class TestScrollExampleCartridge < Minitest::Test
  include ScrollExampleLake

  def test_it_builds_a_rom
    assert_operator Scroll.build_rom(err: StringIO.new).size, :>, 0, "the built ROM should be non-empty"
  end

  def test_the_world_renders_on_the_console
    v = assert_emulator_loads_rom(ROM.assemble(GBA.new.lower(Scroll.program), title: "SCROLL", code: "BSCR", maker: "01"),
                                  frames: 3)
    assert blue_in_lake?(->(x, y) { v.blue?(x, y) }), "the lake renders on hardware"
  end
end
