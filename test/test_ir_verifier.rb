# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "conformance_fixture"

# The IR verifier: a well-formedness pass that mechanically enforces the value
# model. It proves the library built a consistent tree — every value slot holds a
# value node, no run-time value leaked into an author-time structural slot — and
# raises IR::InvariantError (a ruby-gba bug) when it didn't. These tests build
# deliberately malformed nodes with Node.new (bypassing Build's wrapping, the way
# a buggy verb would) and assert the verifier catches each shape, and that real
# well-formed trees pass.
class TestIRVerifier < Minitest::Test
  include RubyGBA::IR::Build

  IR = RubyGBA::IR
  Node = RubyGBA::IR::Node
  Verifier = RubyGBA::IR::Verifier

  # ---- the coverage lock: the schema can't fall behind the node model ----

  def test_every_node_kind_has_a_slots_row
    missing = Node::CATEGORY.keys - Verifier::SLOTS.keys
    assert_empty missing, "these kinds have no Verifier::SLOTS row (a new verb could slip the net): #{missing}"
  end

  def test_the_schema_has_no_rows_for_unknown_kinds
    stray = Verifier::SLOTS.keys - Node::CATEGORY.keys
    assert_empty stray, "these SLOTS rows name kinds that aren't in Node::CATEGORY: #{stray}"
  end

  # ---- well-formed trees pass ----

  def test_the_conformance_fixture_verifies_clean
    prog = ConformanceFixture.program
    assert_same prog, Verifier.verify!(prog), "the kitchen-sink fixture (every kind) must be well-formed"
  end

  def test_a_dsl_built_program_verifies_clean
    # A little program through the readable constructors — value slots hold value
    # nodes, structural slots hold literals.
    prog = program(
      screen(:bitmap),
      set(:x, 5),
      loop_(
        wait_vblank,
        if_(binop(:>, var_ref(:x), int(200)), set(:x, 0)),
        add(:x, 1),
        draw_rect_at(var_ref(:x), int(40), 4, 4, :white),
      ),
    )
    assert_same prog, Verifier.verify!(prog)
  end

  # A buffered screen carries a boolean flag — a structural :flag slot the
  # verifier accepts (and it stays absent, not false, on an ordinary screen).
  def test_a_buffered_screen_verifies_clean
    prog = program(screen(:bitmap, buffered: true), halt)
    assert_same prog, Verifier.verify!(prog)
    assert_equal true, prog.children.first[:buffered]
    refute screen(:bitmap).attrs.key?(:buffered), "the flag is absent (not false) when off"
  end

  def test_a_folded_constant_is_a_valid_value_node
    # The escape hatch: an author-time literal folds to an int value node and
    # satisfies the value slot exactly like a runtime var does.
    prog = program(set(:x, 12)) # 12 -> int(12), a value node
    assert_same prog, Verifier.verify!(prog)
    assert_equal :int, prog.children.first[:value].kind
  end

  # ---- value slots must hold value nodes ----

  def test_a_raw_literal_in_a_value_slot_is_caught
    bad = program(Node.new(:set, var: :x, value: 5)) # 5 not wrapped to int(5)
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/set\.value must be a value node/, err.message)
  end

  def test_a_missing_value_slot_is_caught
    bad = program(Node.new(:add, var: :x)) # no operand at all
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/add\.operand is missing/, err.message)
  end

  def test_a_statement_node_in_a_value_slot_is_caught
    bad = program(Node.new(:set, var: :x, value: Node.new(:halt))) # halt is a statement, not a value
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/set\.value must be a value node/, err.message)
  end

  # ---- structural slots must not hold value nodes / wrong types ----

  def test_a_value_node_in_a_structural_slot_is_caught
    # An `every`'s period is fixed as the program is written; a value node there is a leak.
    bad = program(Node.new(:every, counter: :t, period: int(30)))
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/every\.period must be an author-time int/, err.message)
    assert_match(/value node/, err.message)
  end

  def test_a_wrong_literal_type_in_a_structural_slot_is_caught
    bad = program(Node.new(:every, counter: :t, period: :nope)) # period must be an Integer
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/every\.period must be an author-time int/, err.message)
  end

  # ---- optional structural fields may be nil ----

  def test_optional_structural_fields_may_be_nil
    prog = program(
      Node.new(:bitmap, name: :s, width: 2, height: 2, pixels: "abcd".b, transparent: nil),
      Node.new(:beep, tone: :blip, duty: nil, decay: nil, volume: nil),
    )
    assert_same prog, Verifier.verify!(prog)
  end

  # ---- structural integrity of the tree ----

  def test_a_value_node_wired_as_a_child_is_caught
    bad = program(Node.new(:loop, children: [int(5)])) # a value node can't be a statement
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/as a child/, err.message)
  end

  def test_an_undeclared_field_is_caught
    bad = program(Node.new(:set, var: :x, value: int(1), bogus: 3))
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/set\.bogus is not a declared field/, err.message)
  end

  def test_an_unknown_kind_is_caught
    bad = program(Node.new(:frobnicate, whatever: 1))
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/unknown IR kind :frobnicate/, err.message)
  end

  # ---- it is a library-correctness pass, not a user guardrail ----

  def test_it_raises_rather_than_returning_findings
    # No Finding/severity/fix surface — a malformed tree is a hard error aimed at
    # the library authors, distinct from the developer-facing Guardrails.
    bad = program(Node.new(:set, var: :x, value: 5))
    assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
  end
end
