# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# The IR node model is pure data: these tests build and inspect trees without
# ever constructing a ROM or emitting a single ARM byte. That headlessness is
# the property under test as much as any individual assertion.
class TestIRNode < Minitest::Test
  include RubyGBA::IR::Build

  Node = RubyGBA::IR::Node

  # ========================================================================
  # construction & attrs
  # ========================================================================

  def test_node_holds_kind_and_attrs
    n = set(:x, 5)
    assert_equal :set, n.kind
    assert_equal :x, n[:var]
    assert_instance_of Node, n[:value]
    assert_empty n.children
  end

  def test_a_fresh_node_has_no_parent
    assert_nil int(3).parent
  end

  # ========================================================================
  # children & parent wiring
  # ========================================================================

  def test_add_child_wires_parent_back_reference
    parent = loop_
    child = wait_vblank
    returned = parent.add_child(child)

    assert_same child, returned
    assert_equal [child], parent.children
    assert_same parent, child.parent
  end

  def test_shovel_is_an_alias_for_add_child
    parent = loop_
    parent << halt
    assert_equal :halt, parent.children.first.kind
  end

  def test_children_given_at_construction_are_parented
    body = loop_(wait_vblank, add(:x, 1))
    assert_equal 2, body.children.size
    body.children.each { |c| assert_same body, c.parent }
  end

  def test_add_child_rejects_non_nodes
    assert_raises(ArgumentError) { loop_.add_child(:not_a_node) }
  end

  # ========================================================================
  # category classification (covers all five statement/operand categories)
  # ========================================================================

  def test_category_classification
    assert_equal :root,    program.category
    assert_equal :var,     set(:x, 1).category
    assert_equal :draw,    pixel(1, 2, :red).category
    assert_equal :control, loop_.category
    assert_equal :value,   int(1).category
  end

  def test_unknown_kind_is_flagged_not_guessed
    assert_equal :unknown, Node.new(:bogus_kind).category
  end

  def test_predicates
    assert int(1).value?
    assert loop_.control?
    assert set(:x, 1).statement?
    refute int(1).statement?
    assert halt.leaf?
    refute loop_(halt).leaf?
  end

  # ========================================================================
  # traversal
  # ========================================================================

  def test_each_is_depth_first_preorder_over_statements
    tree = program(
      set(:x, 0),
      loop_(
        wait_vblank,
        add(:x, 1),
      ),
    )
    kinds = tree.each.map(&:kind)
    assert_equal %i[program set loop wait_vblank add], kinds
  end

  def test_each_does_not_descend_into_value_operands
    # set's value is a value node in attrs, not a child — #each ignores it.
    kinds = set(:x, binop(:+, :y, 1)).each.map(&:kind)
    assert_equal [:set], kinds
  end

  def test_walk_descends_into_value_operands
    node = set(:x, binop(:+, var_ref(:y), int(1)))
    kinds = node.walk.map(&:kind)
    # set, then its value operand tree: binop -> (var_ref, int)
    assert_equal %i[set binop var_ref int], kinds
  end

  def test_walk_descends_into_array_valued_attrs
    # a node whose attr is a list of value nodes is fully walked
    n = Node.new(:case, clauses: [int(1), int(2)])
    assert_equal %i[case int int], n.walk.map(&:kind)
  end

  # ========================================================================
  # value / expression composition
  # ========================================================================

  def test_wrap_coerces_bare_operands
    assert_equal int(5),      binop(:+, :a, 5)[:rhs]
    assert_equal var_ref(:a), binop(:+, :a, 5)[:lhs]
  end

  def test_expression_trees_nest
    expr = binop(:+, var_ref(:cpu_y), binop(:/, :paddle_h, 2))
    assert_equal :binop, expr.kind
    assert_equal :/, expr[:rhs][:op]
    assert_equal 2, expr[:rhs][:rhs][:value]
  end

  def test_case_builds_a_dispatch_node
    n = case_(:state, 0 => :title, 1 => :playing)
    assert_equal :case, n.kind
    assert_equal :state, n[:var]
    assert_equal [[0, :title], [1, :playing]], n[:clauses]
  end

  def test_draw_ops_are_draw_category
    assert_equal :draw, draw_text("HI", 0, 0, :white).category
    assert_equal :draw, draw_rect_at(:x, :y, 4, 4, :white).category
    assert_equal :draw, dma_fill_rect(0, 0, 4, 4, :white).category
  end

  def test_draw_rect_at_wraps_its_runtime_position
    # position flows through value nodes (so a variable coord works), while the
    # size stays a plain compile-time constant.
    n = draw_rect_at(:ball_x, 40, 4, 6, :white)
    assert_equal var_ref(:ball_x), n[:x]
    assert_equal int(40), n[:y]
    assert_equal 4, n[:w]
    assert_equal 6, n[:h]
  end

  # ========================================================================
  # structural equality & to_h
  # ========================================================================

  def test_structural_equality_ignores_identity
    assert_equal set(:x, 1), set(:x, 1)
    refute_equal set(:x, 1), set(:x, 2)
  end

  def test_to_h_snapshots_shape
    tree = loop_(add(:x, 1))
    assert_equal(
      {
        kind: :loop,
        children: [
          { kind: :add, attrs: { var: :x, operand: { kind: :int, attrs: { value: 1 } } } },
        ],
      },
      tree.to_h,
    )
  end

  # ========================================================================
  # a representative program touches every category with no ROM in sight
  # ========================================================================

  def test_a_full_program_covers_all_categories_headlessly
    prog = program(
      display(:bitmap),                                          # draw
      set(:x, 100),                                              # var + value
      loop_(                                                     # control
        wait_vblank,
        if_(binop(:>, var_ref(:x), int(200)), set(:x, 0)),      # value cond
        add(:x, 1),
        pixel(:x, 80, :red),
        call(:update),
      ),
      halt,
    )

    covered = prog.walk.map(&:category).uniq
    RubyGBA::IR::Node::CATEGORIES.each do |category|
      assert_includes covered, category, "expected the IR to exercise category #{category}"
    end

    # And it really is inert data — to_h is a plain Hash, no ROM/ASM involved.
    assert_instance_of Hash, prog.to_h
  end
end
