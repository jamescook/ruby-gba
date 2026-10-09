# frozen_string_literal: true

require "test_helper"
require "differential"

require "stringio"
require_relative "../../examples/meadow"

# The Meadow example (examples/meadow.rb): a hero walks out of a one-screen cabin into a
# meadow of 120x100 cells, far bigger than the console's grid. The streaming itself is
# pinned in test/ruby_gba/builder/test_big_maps.rb; this confirms the example builds, walks
# out the door, and draws the same picture on both backends on the way.
class TestMeadowExample < Minitest::Test
  include Differential

  def test_it_builds_a_rom
    assert_operator Meadow.build_rom(err: StringIO.new).size, :>, 0
  end

  def test_holding_down_walks_out_of_the_cabin_into_the_meadow
    run = Reference.new.hold(:down).run(Meadow.program, frames: 60)
    assert_equal 1, run[:room], "out of the door and into the meadow"
    assert_operator run[:view_y], :>, 0, "the view follows the hero down the path"
  end

  def test_both_backends_draw_the_cabin
    assert_backends_agree(Meadow.program, frames: 3, name: "MEADA")
  end

  # Out of the door on about the thirty-third pass, then down the path through the meadow.
  def test_both_backends_draw_the_walk_into_the_meadow
    [34, 60].each do |frames|
      assert_backends_agree(Meadow.program, frames: frames, name: "MEADB", keys: [:down])
    end
  end
end
