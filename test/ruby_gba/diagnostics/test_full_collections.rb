# frozen_string_literal: true

require "test_helper"

# A GAME THAT KEEPS UP UNTIL ITS COLLECTIONS FILL, said at build time from a measurement.
#
# A list or a pool is sized for the worst moment of a game and walked item by item every frame,
# so it keeps up through development and falls behind in the one session that fills it. The
# build runs each scene again with every collection held at its capacity and says which ones
# make it fall behind, with the frame rate it measured.
class TestFullCollections < Minitest::Test
  def setup = require_emulator!

  def build(&block) = RubyGBA.build("FULL", out: nil, err: nil, &block)

  def growths(rom) = RubyGBA::Diagnostics::Profiler.survey_scenes(rom, frames: 10).growths

  # A list of four that can hold 448, each item +divides+ divides.
  def heavy_list(game, name = :xs, divides: 12)
    xs = game.list name, capacity: 448
    total = game.var :total, 0
    4.times { |i| xs.push i }
    -> { xs.each { |x| game.repeat(divides) { total.add!((x * 7) / (total + 3)) } } }
  end

  def test_two_that_fall_behind_only_together_are_named_and_one_never_walked_is_not
    helper = self
    rom = build do
      screen :bitmap
      left = helper.heavy_list(self, :left, divides: 5)
      right = helper.heavy_list(self, :right, divides: 5)
      list :idle, capacity: 448
      game_loop do
        left.call
        right.call
      end
    end

    found = growths(rom)

    assert_equal [["list :left", "list :right"]], found.map { |growth| growth.collections.map(&:label) }
    assert found.first.together
  end

  def test_a_list_walked_every_frame_is_named_with_its_measured_frame_rate
    err = StringIO.new
    helper = self
    RubyGBA.build("FULL", out: nil, err: err, profile: true) do
      screen :bitmap
      walk = helper.heavy_list(self)
      game_loop { walk.call }
    end

    assert_match(/keeps up at 60 frames a second now/, err.string)
    assert_match(/list :xs, which can hold 448/, err.string)
    assert_match(/runs at about \d+ frames a second/, err.string)
  end

  def test_a_pool_walked_every_frame_is_named
    helper = self
    rom = build do
      screen :bitmap
      sparks = pool :spark, x: 0, capacity: 64
      total = var :total, 0
      2.times { sparks.spawn(x: 1) }
      game_loop { sparks.each { |s| repeat(60) { total.add!((s.x * 7) / (total + 3)) } } }
    end

    assert_equal [["pool :spark"]], growths(rom).map { |growth| growth.collections.map(&:label) }
  end

  def test_only_the_collection_that_makes_it_fall_behind_is_named
    helper = self
    rom = build do
      screen :bitmap
      walk = helper.heavy_list(self)
      ys = list :ys, capacity: 448
      count = var :count, 0
      game_loop do
        walk.call
        count.set! ys.length
      end
    end

    found = growths(rom)

    assert_equal [["list :xs"]], found.map { |growth| growth.collections.map(&:label) }
    refute found.first.together
  end

  def test_a_scene_is_named_and_a_scene_without_the_walk_is_not
    helper = self
    rom = build do
      screen :bitmap
      walk = helper.heavy_list(self)
      var :state, 0
      scene(:title) { add! :total, 1 }
      scene(:playing) { walk.call }
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end

    assert_equal [:playing], growths(rom).map(&:scene)
  end

  def test_a_walk_that_keeps_up_full_says_nothing
    helper = self
    rom = build do
      screen :bitmap
      xs = list :xs, capacity: 16
      total = var :total, 0
      game_loop { xs.each { |x| total.add! x } }
    end

    assert_empty growths(rom)
  end
end
