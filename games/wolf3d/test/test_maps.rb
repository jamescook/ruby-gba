# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class TestMaps < Minitest::Test
  include Wolf3DTest

  Release = Wolf3D::Fixture::Release

  def setup
    @release = Release.new
    @maps = Wolf3D::Maps.new(maphead: @release.files["MAPHEAD"], gamemaps: @release.files["GAMEMAPS"])
  end

  def test_it_reads_the_one_level_the_fixture_holds
    assert_equal 1, @maps.count
    assert_equal ["Fixture Room"], @maps.names
    assert_equal [64, 64], [@maps[0].width, @maps[0].height]
  end

  def test_asking_for_a_level_that_is_not_there_says_so
    error = assert_raises(IndexError) { @maps[7] }

    assert_includes error.message, "7"
  end

  def test_the_walls_and_the_floor_come_back_where_we_put_them
    level = @maps[0]

    assert level.solid?(0, 0), "the border is solid"
    assert level.solid?(63, 63), "the far corner is solid"
    refute level.solid?(32, 32), "the middle is floor"
    assert level.floor?(32, 32)
  end

  def test_a_door_is_a_door_and_not_a_wall
    level = @maps[0]

    assert level.door?(32, 0)
    refute level.solid?(32, 0), "you can walk through a door"
  end

  def test_outside_the_grid_is_solid_so_nothing_walks_off_the_level
    level = @maps[0]

    assert level.solid?(-1, 10)
    assert level.solid?(10, 64)
    refute level.inside?(64, 0)
  end

  def test_the_player_starts_where_the_second_plane_says_facing_where_it_says
    start = @maps[0].start

    assert_equal 32, start.x
    assert_equal 32, start.y
    assert_equal :north, start.facing
  end

  # Everything standing in the level EXCEPT the player, whose thing code says where they
  # start rather than that something is there. The fixture floor holds a guard, a key, and a
  # push wall, and all three are things.
  def test_the_things_are_listed_without_the_player_among_them
    things = @maps[0].things

    refute_includes things.map(&:code), Release::PLAYER_NORTH
    guard = things.find { |thing| thing.code == Release::GUARD_EAST }

    refute_nil guard, "the guard should be among the things"
    assert_equal [34, 32], [guard.x, guard.y]
    assert_includes things.map(&:code), Release::GOLD_KEY
    assert_includes things.map(&:code), Wolf3D::Level::PUSHWALL
  end

  def test_a_floor_cell_knows_which_area_it_belongs_to
    level = @maps[0]

    assert_equal 1, level.area(32, 32)
    assert_nil level.area(0, 0), "a wall is in no area"
  end

  # The header ends in a four-byte tail. Reading a level whose header does not is a corrupt
  # file, not something to guess at.
  def test_a_header_without_its_tail_is_refused
    broken = @release.files["GAMEMAPS"].dup
    broken[8 + 38, 4] = "????"

    maps = Wolf3D::Maps.new(maphead: @release.files["MAPHEAD"], gamemaps: broken)
    assert_raises(ArgumentError) { maps[0] }
  end
end

# The reader against a real copy of the game. Skips without one.
class TestMapsAgainstRealLevels < Minitest::Test
  include Wolf3DTest

  def setup
    @maps = Wolf3D::Maps.from(game_data_or_skip)
  end

  def test_every_level_reads_and_is_named
    assert_operator @maps.count, :>=, 10

    @maps.each do |level|
      assert_equal [64, 64], [level.width, level.height]
      refute_empty level.name
    end
  end

  # Exactly one across all sixty, which is what makes it safe to treat as a single value rather
  # than a list to choose from.
  def test_every_level_has_exactly_one_player_start
    @maps.each do |level|
      refute_nil level.start, "#{level.name} has no start"
      starts = level.each_cell.count { |x, y| Wolf3D::Level::FACINGS.key?(level.thing_code(x, y)) }

      assert_equal 1, starts, "#{level.name} has #{starts} starts"
    end
  end

  def test_the_first_level_is_the_one_everybody_remembers
    level = @maps[0]

    assert_equal "Wolf1 Map1", level.name
    assert_equal [29, 57, :east], [level.start.x, level.start.y, level.start.facing]
  end

  # The property the engine actually leans on. One real level (Wolf1 Map3) has a floor cell
  # sitting on its bottom edge — a slip in the original's own map data — so "the border is
  # solid" is not true and cannot be relied on. This is: outside the grid is solid whatever the
  # border says, so nothing walks out however leaky an edge is.
  def test_stepping_outside_a_level_is_solid_however_leaky_its_border_is
    @maps.each do |level|
      (0...64).each do |i|
        assert level.solid?(i, -1), "#{level.name} above the top"
        assert level.solid?(i, 64), "#{level.name} below the bottom"
        assert level.solid?(-1, i), "#{level.name} left of the left"
        assert level.solid?(64, i), "#{level.name} right of the right"
      end
    end
  end

  # A handful of stray edge cells is the original's own doing. Hundreds would mean the line
  # between a wall code and a floor code is in the wrong place, which is the bug this catches.
  def test_the_border_is_solid_apart_from_the_originals_own_slips
    leaks = @maps.each.flat_map do |level|
      (0...64).flat_map do |i|
        [[i, 0], [i, 63], [0, i], [63, i]]
          .reject { |x, y| level.solid?(x, y) }
          .map { |x, y| "#{level.name} (#{x},#{y})" }
      end
    end

    assert_operator leaks.length, :<=, 4, "too many open edges to be the original's slips: #{leaks}"
  end
end
