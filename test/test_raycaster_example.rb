# frozen_string_literal: true

require "test_helper"

require "stringio"
require_relative "../examples/raycaster"

# The Raycaster example (examples/raycaster.rb): a first-person view of a maze, built on
# the `table` verb — sine, wall-height, and the maze itself are build-time ROM tables the
# rays look up. The player stands inside a walled room, so every screen column hits a wall
# and draws a white strip through the eye line. Asserted on the interpreter oracle and the
# console.
class TestRaycasterExample < Minitest::Test

  WHITE = RubyGBA::Color.resolve(:white)

  # How many screen columns show a wall pixel at the horizon (y = 80).
  def wall_columns(sample)
    (0...240).step(8).count { |x| sample.call(x + 3, 80) == WHITE }
  end

  def test_it_builds_a_rom
    assert_operator Raycaster.build_rom(out: StringIO.new, err: StringIO.new).size, :>, 0
  end

  def test_walls_render_on_the_interpreter
    interp = Reference.new.run(Raycaster.program, frames: 2)
    assert_operator wall_columns(->(x, y) { interp.screen.pixel(x, y) }), :>=, 20,
                    "the surrounding walls should draw a strip in most columns"
  end

  def test_walls_render_on_the_console
    # One game frame does a lot (a ray per column, a row per wall pixel), so it spans
    # several emulated frames before the first double-buffer flip — give it headroom.
    v = assert_gemba_loads_rom(Raycaster.build_rom(out: StringIO.new, err: StringIO.new), frames: 24)
    assert_operator wall_columns(->(x, y) { v.pixel_is?(x, y, :white) ? WHITE : nil }), :>=, 20,
                    "the surrounding walls should draw a strip in most columns on hardware"
  end
end
