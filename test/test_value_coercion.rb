# frozen_string_literal: true

require "test_helper"

# The one value-coercion boundary (Value.node_for): every value operand — a
# Value, an Integer, a Symbol, a raw value node — becomes a uniform IR value
# node, and anything that can't be a value is a friendly error. The headline
# property is interchangeability: a Value and its :symbol build the SAME IR at
# every verb, so you can hold Values and pass them anywhere.
class TestValueCoercion < Minitest::Test
  include RubyGBA::IR::Build

  Value = RubyGBA::Value

  # ---- the coercer itself --------------------------------------------------

  def test_an_integer_becomes_an_int_literal_node
    node = Value.node_for(5)
    assert_equal :int, node.kind
    assert_equal 5, node.value
  end

  def test_a_symbol_becomes_a_variable_reference_node
    node = Value.node_for(:score)
    assert_equal :var_ref, node.kind
    assert_equal :score, node.name
  end

  def test_a_value_contributes_its_own_node
    v = Value.new(nil, int(9))
    assert_same v.node, Value.node_for(v)
  end

  def test_a_value_node_passes_through_untouched
    n = var_ref(:x)
    assert_same n, Value.node_for(n)
  end

  def test_something_that_cannot_be_a_value_is_a_friendly_error
    err = assert_raises(ArgumentError) { Value.node_for(1.5) }
    assert_match(/value/i, err.message)
    assert_raises(ArgumentError) { Value.node_for("nope") }
  end

  # ---- the other question: is this number fixed, or worked out as it runs? ---

  # The same interchangeability, asked the other way round. A number the author wrote is
  # the same fact however far it has been wrapped on its way here — bare, wrapped for the
  # tree, or held in a handle — so all three answer with the number.
  def test_a_number_the_author_wrote_is_fixed_however_it_is_wrapped
    assert_equal 5, Value.fixed_number(5)
    assert_equal 5, Value.fixed_number(int(5)), "already wrapped for the tree"
    assert_equal 5, Value.fixed_number(Value.new(nil, int(5))), "held in a handle"
  end

  # ...and everything the game works out answers nil, which is what a caller branches on.
  def test_a_number_the_game_works_out_is_not_fixed
    assert_nil Value.fixed_number(:score), "a variable by name"
    assert_nil Value.fixed_number(var_ref(:score))
    assert_nil Value.fixed_number(Value.new(nil, var_ref(:score), name: :score))
    assert_nil Value.fixed_number(binop(:+, var_ref(:score), int(1))), "an expression"
  end

  # THE ONE THAT ASKING AFTER THE CLASS GOT WRONG. `is_a?(Integer)` is false for a literal
  # that has already been wrapped, so a caller handed one took the run-time path for a
  # number that was sitting right there. The two readings have to agree, because the
  # surface and the backend both ask this and they must not answer differently.
  def test_a_wrapped_literal_is_fixed_even_though_it_is_not_an_Integer
    wrapped = int(7)

    refute_kind_of Integer, wrapped
    assert_equal 7, Value.fixed_number(wrapped)
  end

  # ---- the property: a Value and its :symbol are interchangeable at verbs ---

  # Exercise every runtime value-verb with bare symbols/ints, then again with
  # Value handles, and assert the two programs build the identical IR tree.
  def build_with(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def test_symbol_and_value_forms_build_the_same_ir
    with_symbols = build_with do
      screen :bitmap
      var :x, 10
      var :y, 20
      var :d, 2
      set :x, :d           # value operand: a symbol
      add :x, :d
      sub :y, 3
      draw_rect_at :x, :y, 4, 4, :white
      blit :ball, :x, :y
      if_gt :x, :y do
        set :y, 0
      end
      halt
    end

    with_values = build_with do
      screen :bitmap
      x = var :x, 10
      y = var :y, 20
      d = var :d, 2
      x.set d              # same operand as a Value
      x.add d
      y.sub 3
      draw_rect_at x, y, 4, 4, :white
      blit :ball, x, y
      (x > y).then { y.set 0 }
      halt
    end

    assert_equal with_symbols, with_values,
                 "a Value and its :symbol must produce identical IR at every verb"
  end

  def test_passing_an_unrepresentable_value_to_a_verb_errors_at_the_boundary
    b = Builder.new
    err = assert_raises(ArgumentError) { b.set(:x, "half") }
    assert_match(/value/i, err.message)
  end

  # A Float is not unrepresentable — it is how a program says a variable holds a
  # fraction. It is stored multiplied up, and the handle remembers by how much.
  def test_a_float_declares_a_variable_that_holds_a_fraction
    b = Builder.new
    handle = b.set(:x, 1.5)

    assert_predicate handle, :fraction?
    assert_equal 16, handle.fraction_bits
    assert_equal 1.5 * (1 << 16), b.program.walk.find { |n| n.kind == :set }.value.value
  end
end
