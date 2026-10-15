# frozen_string_literal: true

require "test_helper"
require "differential"

require "stringio"
require RubyGBA.root.join("examples/cave").to_s

# The Cave example (examples/cave.rb): a hero with a lantern walks out of a dark cave, the
# screen closes in a circle on them, and it opens onto a meadow in daylight. The light and
# the iris themselves are pinned in test/ruby_gba/builder/test_spotlight.rb and
# test/ruby_gba/effects/packs/test_iris.rb; this confirms the example builds, that holding
# RIGHT takes the hero all the way out, and that the console draws the same picture on the
# way.
class TestCaveExample < Minitest::Test
  runs_on :reference, :native
  include Differential

  GRASS = [Color.rgb(6, 20, 6), Color.rgb(10, 26, 8)].freeze

  def walk_right(frames) = game_player.hold(:right).run(Cave.program, frames: frames)

  def test_it_builds_with_nothing_to_warn_about
    out = StringIO.new
    err = StringIO.new
    rom = Cave.build_rom(out: out, err: err)

    assert_operator rom.size, :>, 0
    refute_match(/warning/i, out.string + err.string)
  end

  # In the cave the lantern lights the hero's corner and the rest is near black: the far
  # side of the cave is darker than anything in the lantern's reach.
  def test_the_lantern_lights_the_hero_and_leaves_the_cave_dark
    screen = walk_right(2).screen
    near = screen.pixel(32, 76)
    far = screen.pixel(200, 30)

    assert_operator (far & 31) + ((far >> 5) & 31), :<, (near & 31) + ((near >> 5) & 31)
  end

  # Holding RIGHT walks the hero out of the cave mouth; the circle closes on them and opens
  # on the meadow, where nothing is dark.
  def test_holding_right_walks_out_into_a_meadow_in_daylight
    screen = walk_right(300).screen
    lit = [[60, 150], [200, 150], [120, 10]].map { |x, y| screen.pixel(x, y) }

    assert(lit.all? { |color| GRASS.include?(color) }, "the meadow's grass, as drawn: #{lit.inspect}")
  end

  def test_the_console_draws_the_same_cave_and_the_same_iris
    assert_backends_agree(Cave.program, frames: 3, keys: [:right], name: "CAVE")
    assert_backends_agree(Cave.program, frames: 220, keys: [:right], name: "IRIS")
  end
end
