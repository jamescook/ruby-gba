# frozen_string_literal: true

require "test_helper"
require "stringio"
require "console/gba/examples/test_maze_example"

# The Maze example on the Advance's cartridge: it builds clean, and in the emulator the walls
# really stop the hero. What the room does on every run that plays the Advance's games is in
# test/console/gba/examples/test_maze_example.rb.
class TestMazeExampleCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include MazeColors

  def test_the_example_builds_clean
    rom = Maze.build_rom(err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # --- Hardware (the emulator): the walls really stop the hero ---

  def test_the_hero_stops_at_a_wall_on_the_console
    v = assert_emulator_loads_rom(Maze.build_rom(err: StringIO.new), frames: 40, keys: KEY_RIGHT)
    assert v.pixel_is?(28, 20, HERO),
           "the hero stops flush against the pillar, got 0x#{format('%04X', v.pixel_gba(28, 20))}"
    assert v.pixel_is?(48, 20, BRICK),
           "the pillar is past it, got 0x#{format('%04X', v.pixel_gba(48, 20))}"
    refute v.pixel_is?(48, 20, HERO), "the hero never entered the pillar"
  end
end
