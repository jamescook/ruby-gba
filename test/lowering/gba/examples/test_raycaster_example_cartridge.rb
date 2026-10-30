# frozen_string_literal: true

require "test_helper"

require "stringio"
require "console/gba/examples/test_raycaster_example"

# The Raycaster example (examples/raycaster.rb) on the Advance's own cartridge: the walls it
# draws, read off the screen in the emulator. What the example does on every run that plays the
# Advance is in test/console/gba/examples/test_raycaster_example.rb, which keeps the count both
# files make in RaycasterWalls.
class TestRaycasterExampleCartridge < Minitest::Test
  include RaycasterWalls

  def test_walls_render_on_the_console
    # One game frame does a lot (a ray per column, a row per wall pixel), so it spans
    # several emulated frames before the first double-buffer flip — give it headroom.
    v = assert_emulator_loads_rom(Raycaster.build_rom(out: StringIO.new, err: StringIO.new), frames: 24)
    assert_operator wall_columns(->(x, y) { v.pixel_gba(x, y) }), :>=, 20,
                    "the surrounding walls should draw a strip in most columns on hardware"
  end
end
