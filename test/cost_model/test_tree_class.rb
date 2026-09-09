# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# Tree (lib/ruby_gba/ir/cost_model/tree.rb) as a standalone class. Its shaping passes
# (aggregate, collapse_repeats, group_by_source, prune, hot_ops, category_of, project) are
# class methods that need no catalogue, pricing, walker, or verdicts — they only fold an
# already-built tree — so those are exercised with no instance at all, matching how
# CostModel itself now reaches them (Tree.aggregate, not a CostModel instance's).
class TestTreeClass < CostModelTest
  Tree = RubyGBA::IR::CostModel::Tree

  def test_category_of_needs_no_instance
    assert_equal :drawing, Tree.category_of(:fill_rect)
    assert_equal :sound, Tree.category_of(:beep)
    assert_equal :logic, Tree.category_of(:set)
  end

  # A container is kept as the path to a leaf that belongs to the section, dropped when
  # none of it does, and re-costed from what survived.
  def test_project_keeps_the_path_to_a_leaf_and_re_costs_it
    call = entry(op: :call, label: "call :x", cost: 11, children: [
                   entry(op: :fill_rect, cost: 10),
                   entry(op: :add, cost: 1),
                 ])
    beep = entry(op: :beep, cost: 5)

    drawing = Tree.project([call, beep], :drawing)
    assert_equal ["call :x"], drawing.map(&:title)
    near 10, drawing.first.cost
    assert_equal %i[fill_rect], drawing.first.children.map(&:op)

    assert_equal %i[beep], Tree.project([call, beep], :sound).map(&:op)
    near 1, Tree.project([call, beep], :logic).first.cost
  end

  # A loop bakes its passes into its own cost, so a projection of it has to as well.
  def test_project_multiplies_a_loop_by_its_passes
    loop_node = entry(op: :repeat, label: "repeat 4", cost: 44, factor: 4, children: [
                        entry(op: :fill_rect, cost: 10),
                        entry(op: :add, cost: 1),
                      ])

    near 40, Tree.project([loop_node], :drawing).first.cost
    near 4, Tree.project([loop_node], :logic).first.cost
  end

  # Only one scene runs a frame, so a case_var charges the branch the walker marked as
  # the dearest and shows the rest without charging them.
  def test_project_charges_only_the_scene_a_frame_reaches
    branch = lambda do |cost, factor|
      entry(op: :branch, cost: cost, factor: factor, children: [entry(op: :fill_rect, cost: cost)])
    end
    dispatch = entry(op: :case, label: "case_var :state", cost: 10,
                     children: [branch.call(3, 0), branch.call(10, 1)])

    near 10, Tree.project([dispatch], :drawing).first.cost
    assert_equal 2, Tree.project([dispatch], :drawing).first.children.length,
                 "the light scene is still shown"
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
