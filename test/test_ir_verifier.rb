# frozen_string_literal: true

require "test_helper"

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
  Nodes = RubyGBA::IR::Nodes
  Verifier = RubyGBA::IR::Verifier
  Fields = RubyGBA::IR::Fields

  # ---- every kind says what it is ----
  #
  # The operands a kind carries and the category it belongs to are declared on the class, so
  # there is no table to fall behind. What can still go wrong is a class that forgets to say
  # one of them.

  def test_every_kind_declares_a_category
    silent = RubyGBA::IR::Nodes.by_kind.reject { |_, type| type.category }.keys

    assert_empty silent, "these kinds declare no category (add `category :...` to the class): #{silent}"
  end

  def test_every_declared_category_is_a_real_one
    stray = RubyGBA::IR::Nodes.by_kind.values.map(&:category).uniq - Node::CATEGORIES

    assert_empty stray, "these kinds name a category that does not exist: #{stray}"
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
    assert_equal true, prog.children.first.buffered
    refute screen(:bitmap).attrs.key?(:buffered), "the flag is absent (not false) when off"
  end

  def test_a_folded_constant_is_a_valid_value_node
    # The escape hatch: an author-time literal folds to an int value node and
    # satisfies the value slot exactly like a runtime var does.
    prog = program(set(:x, 12)) # 12 -> int(12), a value node
    assert_same prog, Verifier.verify!(prog)
    assert_equal :int, prog.children.first.value.kind
  end

  # ---- value slots must hold value nodes ----

  def test_a_raw_literal_in_a_value_slot_is_caught
    bad = program(Nodes::Set.new(var: :x, value: 5)) # 5 not wrapped to int(5)
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/set\.value must be a value node/, err.message)
  end

  def test_a_missing_value_slot_is_caught
    bad = program(Nodes::Add.new(var: :x)) # no operand at all
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/add\.operand is missing/, err.message)
  end

  def test_a_statement_node_in_a_value_slot_is_caught
    bad = program(Nodes::Set.new(var: :x, value: Nodes::Halt.new)) # halt is a statement, not a value
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/set\.value must be a value node/, err.message)
  end

  # ---- structural slots must not hold value nodes / wrong types ----

  def test_a_value_node_in_a_structural_slot_is_caught
    # An `every`'s period is fixed as the program is written; a value node there is a leak.
    bad = program(Nodes::Every.new(counter: :t, period: int(30)))
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/every\.period must be an author-time int/, err.message)
    assert_match(/value node/, err.message)
  end

  def test_a_wrong_literal_type_in_a_structural_slot_is_caught
    bad = program(Nodes::Every.new(counter: :t, period: :nope)) # period must be an Integer
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/every\.period must be an author-time int/, err.message)
  end

  # A SONG'S PARTS ARE RECORDS, and the slot says so. A part used to be a plain Hash, which
  # nothing could check past "it is an Array" — so a misspelt key sat there unread and came out
  # layers away as a part playing the wrong voice. A shape-compatible Hash is now refused here,
  # which is what stops one being written again by hand.
  # THE SAME FOR A SAVED VARIABLE, and this one has a trap of its own worth pinning: Hash has a
  # #default method already — it answers the hash's own fallback, not the key called :default —
  # so a hand-built hash sailed straight past `var.default` and handed a backend nonsense
  # instead of raising. The slot says it must be a record, so it cannot happen again.
  def test_a_saved_variable_that_is_not_a_record_is_caught
    bad = program(Nodes::SaveInit.new(magic: 1, vars: [{ name: :hi, default: 0, slot: 0 }]))
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/save_init\.vars must be an author-time save/, err.message)
  end

  def test_a_song_part_that_is_not_a_record_is_caught
    bad = program(Nodes::Song.new(name: :tune, total_frames: 4,
                                  voices: [{ events: [[0, 262]], duty: :half, volume: 12 }]))
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/song\.voices must be an author-time score/, err.message)
  end

  # ---- optional structural fields may be nil ----

  def test_optional_structural_fields_may_be_nil
    prog = program(
      Nodes::Bitmap.new(name: :s, width: 2, height: 2, pixels: "abcd".b, transparent: nil),
      Nodes::Beep.new(tone: :blip, duty: nil, decay: nil, volume: nil),
    )
    assert_same prog, Verifier.verify!(prog)
  end

  # ---- structural integrity of the tree ----

  def test_a_value_node_wired_as_a_child_is_caught
    bad = program(Nodes::Loop.new(children: [int(5)])) # a value node can't be a statement
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
    assert_match(/as a child/, err.message)
  end

  # A field the kind does not have never reaches the verifier now: the node refuses it at
  # the line that set it, which is where the verb that got it wrong is.
  def test_an_undeclared_field_is_refused_where_it_is_set
    err = assert_raises(IR::InvariantError) { Nodes::Set.new(var: :x, value: int(1), bogus: 3) }

    assert_match(/set has no :bogus field to set/, err.message)
  end

  # A kind the model has not been taught. It cannot come from IR::Nodes.build, which has no
  # class to build — so the shape that reaches here is a node class declared somewhere else,
  # which is how a library outside this one would add a kind. The verifier is what tells such
  # a program that nothing downstream knows the kind.
  def test_a_kind_declared_outside_the_model_is_caught
    outsider = Class.new do
      include RubyGBA::IR::Node
      kind :frobnicate
      category :draw
      operands whatever: :int
    end

    bad = program(outsider.new(whatever: 1))
    err = assert_raises(IR::InvariantError) { Verifier.verify!(bad) }

    assert_match(/unknown IR kind :frobnicate/, err.message)
  end

  # ---- it is a library-correctness pass, not a user guardrail ----

  def test_it_raises_rather_than_returning_findings
    # No Finding/severity/fix surface — a malformed tree is a hard error aimed at
    # the library authors, distinct from the developer-facing Guardrails.
    bad = program(Nodes::Set.new(var: :x, value: 5))
    assert_raises(IR::InvariantError) { Verifier.verify!(bad) }
  end
end
