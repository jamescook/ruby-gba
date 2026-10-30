# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/maze").to_s

# The colours these tests look for, shared with the Advance cartridge's own tests of the example
# (test/lowering/gba/examples/test_maze_example_cartridge.rb).
module MazeColors
  HERO = VBlank::Graphics::Color.rgb(31, 20, 0)  # the hero disc's body
  BRICK = VBlank::Graphics::Color.rgb(20, 10, 8) # a wall brick
end

# The Maze example (examples/maze.rb): a hero walks a tiled room and is stopped by the
# wall tiles (a tileset with `solid:` bricks + a sprite `blocked_by` the room). Proves
# the room renders, the hero starts on the floor, and holding into a wall stops it flush
# instead of passing through — on every run that plays the Advance's games. The cartridge it
# builds, and the walls stopping the hero there, are in
# test/lowering/gba/examples/test_maze_example_cartridge.rb.
class TestMazeExample < Minitest::Test
  include MazeColors

  # At rest the room is drawn (border bricks) and the hero sits on the floor near the
  # left wall.
  def test_the_room_and_hero_render
    s = game_player.run(Maze.program, max_steps: 300).screen
    assert_equal HERO,  s.pixel(12, 20), "the hero starts on the floor by the left wall"
    assert_equal BRICK, s.pixel(100, 4), "the room's wall border is drawn along the top"
  end

  # Hold right: the hero walks up to the first pillar (px 32) and stops flush at x24,
  # never entering the wall.
  def test_the_hero_stops_at_a_wall
    s = game_player.input_each_frame { [:right] }.run(Maze.program, max_steps: 3_000).screen
    assert_equal HERO,  s.pixel(28, 20), "the hero rests flush against the pillar (its body at x24..31)"
    assert_equal BRICK, s.pixel(48, 20), "the pillar is right there past it"
    refute_equal HERO,  s.pixel(48, 20), "the hero never walked into the pillar"
  end
end
