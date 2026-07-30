# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "fixtures/cost_parts/left_wall"
require_relative "fixtures/cost_parts/right_wall"

# The cost tree (rom.explain) groups a frame's work by the source FILE it came from,
# so a game split across collaborator files (player.rb, enemies.rb, hud.rb — plain
# objects handed the builder) reads as a labeled subtotal per file instead of one flat
# list. No author effort: every IR node already carries its DSL call site.
class TestCostTreeBySource < Minitest::Test
  Cost = RubyGBA::IR::CostModel
  Builder = RubyGBA::Builder

  # --- the transform in isolation (data in, data out, like aggregate/collapse_repeats) ---

  def test_group_by_source_buckets_consecutive_leaves_by_file
    tree = [
      leaf("player.rb:10", 2), leaf("player.rb:11", 3),
      leaf("enemies.rb:20", 4), leaf("enemies.rb:21", 5)
    ]
    grouped = Cost.new.group_by_source(tree)

    assert_equal %i[group group], grouped.map { |n| n[:op] }
    assert_equal ["player.rb", "enemies.rb"], grouped.map { |n| n[:label] }
    assert_equal [5, 9], grouped.map { |n| n[:cost] }, "each group carries its file's subtotal"
    assert_equal 2, grouped.first[:children].length
  end

  def test_group_by_source_leaves_a_single_file_untouched
    tree = [leaf("game.rb:10", 2), leaf("game.rb:11", 3)]
    assert_equal tree, Cost.new.group_by_source(tree), "one collaborator: nothing to separate"
  end

  def test_group_by_source_does_not_wrap_a_lone_file_node
    tree = [leaf("a.rb:1", 2), leaf("b.rb:1", 3), leaf("b.rb:2", 4)]
    grouped = Cost.new.group_by_source(tree)

    assert_equal :fill_rect, grouped[0][:op], "a lone node from a.rb isn't wrapped in a group of one"
    assert_equal :group, grouped[1][:op]
    assert_equal "b.rb", grouped[1][:label]
  end

  # Grouping reaches nested siblings too — the collaborators of a game live under a
  # case_var branch, not at the top of the loop, so the transform recurses in.
  def test_group_by_source_recurses_into_children
    tree = [{ op: :case, label: "case", cost: 5, source: "game.rb:1", children: [
      leaf("player.rb:1", 2), leaf("player.rb:2", 2),
      leaf("enemies.rb:1", 3), leaf("enemies.rb:2", 3)
    ] }]
    grouped = Cost.new.group_by_source(tree)
    inner = grouped.first[:children]
    assert_equal ["player.rb", "enemies.rb"], inner.map { |n| n[:label] }
  end

  # --- end to end: two collaborator files, grouped in the real cost tree ---

  def test_a_multi_file_game_groups_its_frame_cost_by_file
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      left = CostParts::LeftWall.new(self)
      right = CostParts::RightWall.new(self)
      game_loop do
        wait_vblank
        left.draw  # recorded from left_wall.rb
        right.draw # recorded from right_wall.rb
      end
    end
    b.emit_pending_functions

    tree = Cost.new.as_json(b.program)[:tree]
    groups = tree.select { |n| n[:op] == :group }
    assert_equal ["left_wall.rb", "right_wall.rb"], groups.map { |n| n[:label] },
                 "each collaborator file is its own labeled group"
    assert(groups.all? { |g| g[:cost].positive? }, "each group carries a real subtotal")
    assert(groups.all? { |g| g[:children].length == 2 }, "each wall's two fills sit under its group")
  end

  private

  def leaf(source, cost)
    { op: :fill_rect, label: "fill", cost: cost, source: source, children: [] }
  end
end
