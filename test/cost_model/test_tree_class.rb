# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# Tree (lib/ruby_gba/ir/cost_model/tree.rb) as a standalone class. Its shaping passes
# (aggregate, collapse_repeats, group_by_source, prune, hot_ops, category_of) are class
# methods that need no catalogue, pricing, walker, or verdicts — they only fold an
# already-built tree — so those are exercised with no instance at all, matching how
# CostModel itself now reaches them (Tree.aggregate, not a CostModel instance's).
class TestTreeClass < CostModelTest
  Tree = RubyGBA::IR::CostModel::Tree

  def test_category_of_needs_no_instance
    assert_equal :drawing, Tree.category_of(:fill_rect)
    assert_equal :sound, Tree.category_of(:beep)
    assert_equal :logic, Tree.category_of(:set)
  end

  def test_aggregate_folds_a_run_of_identical_leaves_with_no_instance
    leaf = ->(cost) { entry(op: :pixel, cost: cost) }
    folded = Tree.aggregate([leaf.call(1), leaf.call(1), leaf.call(1)])

    assert_equal 1, folded.length
    assert_equal 3, folded.first.count
    near 3, folded.first.cost
  end

  def test_hot_ops_ranks_the_costliest_leaf_first_with_no_instance
    tree = [entry(op: :fill_rect, cost: 1), entry(op: :blit, cost: 10)]
    hot = Tree.hot_ops(tree, 5)

    assert_equal :blit, hot.first.op
  end
end
