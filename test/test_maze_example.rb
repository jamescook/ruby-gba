# frozen_string_literal: true

require "test_helper"

require "stringio"
require_relative "../examples/maze"

# The Maze example (examples/maze.rb): a hero walks a tiled room and is stopped by the
# wall tiles (a tileset with `solid:` bricks + a sprite `blocked_by` the room). Proves
# the room renders, the hero starts on the floor, and holding into a wall stops it flush
# instead of passing through — on the interpreter oracle and on real hardware.
class TestMazeExample < Minitest::Test
  include RubyGBA::Constants

  HERO = Color.rgb(31, 20, 0)  # the hero disc's body
  BRICK = Color.rgb(20, 10, 8) # a wall brick

  def test_the_example_builds_clean
    rom = Maze.build_rom(err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # At rest the room is drawn (border bricks) and the hero sits on the floor near the
  # left wall.
  def test_the_room_and_hero_render
    s = Reference.new.run(Maze.program, max_steps: 300).screen
    assert_equal HERO,  s.pixel(12, 20), "the hero starts on the floor by the left wall"
    assert_equal BRICK, s.pixel(100, 4), "the room's wall border is drawn along the top"
  end

  # Hold right: the hero walks up to the first pillar (px 32) and stops flush at x24,
  # never entering the wall.
  def test_the_hero_stops_at_a_wall
    s = Reference.new.input_each_frame { [:right] }.run(Maze.program, max_steps: 3_000).screen
    assert_equal HERO,  s.pixel(28, 20), "the hero rests flush against the pillar (its body at x24..31)"
    assert_equal BRICK, s.pixel(48, 20), "the pillar is right there past it"
    refute_equal HERO,  s.pixel(48, 20), "the hero never walked into the pillar"
  end

  # --- Hardware (gemba): the walls really stop the hero ---

  def test_the_hero_stops_at_a_wall_on_the_console
    v = assert_gemba_loads_rom(Maze.build_rom(err: StringIO.new), frames: 40, keys: KEY_RIGHT)
    assert v.pixel_is?(28, 20, HERO),
           "the hero stops flush against the pillar, got 0x#{format('%04X', v.pixel_gba(28, 20))}"
    assert v.pixel_is?(48, 20, BRICK),
           "the pillar is past it, got 0x#{format('%04X', v.pixel_gba(48, 20))}"
    refute v.pixel_is?(48, 20, HERO), "the hero never entered the pillar"
  end
end
