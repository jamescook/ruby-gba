# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The expression DSL: `var` hands back a Value handle you compare with ordinary
# Ruby operators to get a Condition, branch on with .then, and mutate with
# .set / .add / .sub / .clamp. It builds the same IR the low-level if_gt/if_lt
# tier does, so these tests assert the tree it constructs and that it boots.
class TestDSLExpression < Minitest::Test
  include RubyGBA::IR::Build # the expected-tree constructors
  include GembaSupport

  Builder = RubyGBA::Builder

  # Build through the DSL and hand back the IR tree it constructed.
  def tree(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  def build(&block)
    RubyGBA.build("EXPR", code: "BEXP", maker: "01", doctor: false, &block)
  end

  # ---- comparison -> Condition -> .then builds an if node ----

  def test_comparison_then_builds_an_if
    got = tree do
      x = var :x, 5
      (x > 3).then { x.add 1 }
    end

    expected = program(
      set(:x, 5),
      if_(binop(:>, var_ref(:x), int(3)), add(:x, 1)),
    )
    assert_equal expected, got
  end

  def test_each_comparison_operator_maps_to_its_op
    %i[> < >= <= == !=].each do |op|
      got = tree do
        x = var :x, 0
        x.public_send(op, 1).then { x.add 1 }
      end

      assert_equal op, got.children.last[:cond][:op], "#{op} should build a #{op} comparison"
    end
  end

  # ---- arithmetic operands ----

  def test_arithmetic_builds_a_binop_operand
    got = tree do
      y = var :y, 0
      c = var :c, 0
      (y > c + 10).then { y.sub 2 }
    end

    expected = program(
      set(:y, 0),
      set(:c, 0),
      if_(binop(:>, var_ref(:y), binop(:+, var_ref(:c), int(10))), sub(:y, 2)),
    )
    assert_equal expected, got
  end

  # ---- mutators ----

  def test_value_mutators_build_var_ops
    got = tree do
      v = var :v, 0
      v.set 5
      v.add 3
      v.sub 1
      v.clamp 0, 10
    end

    expected = program(
      set(:v, 0), set(:v, 5), add(:v, 3), sub(:v, 1), clamp(:v, 0, 10),
    )
    assert_equal expected, got
  end

  def test_unary_mutators_build_var_ops
    got = tree do
      d = var :d, -3
      d.abs
      d.negate_abs
      d.flip
    end

    expected = program(
      set(:d, -3), abs(:d), negate_abs(:d), negate(:d),
    )
    assert_equal expected, got
  end

  # ---- input reads: held / pressed are Conditions too ----

  def test_held_and_pressed_build_input_conditions
    got = tree do
      held(:up).then { set :moved, 1 }
      pressed(:start).then { set :started, 1 }
    end

    expected = program(
      if_(held(:up), set(:moved, 1)),
      if_(pressed(:start), set(:started, 1)),
    )
    assert_equal expected, got
  end

  def test_held_rejects_an_unknown_button
    assert_raises(ArgumentError) do
      tree { held(:turbo).then { halt } }
    end
  end

  def test_held_and_pressed_reject_a_block
    # Forgetting .then and writing held(:up) { ... } drops the block silently
    # (it attaches to `held`, not to an if). Catch it at the call site.
    %i[held pressed].each do |verb|
      err = assert_raises(ArgumentError) do
        tree { send(verb, :up) { halt } }
      end
      assert_match(/\.then/, err.message, "#{verb} should point the dev at .then")
    end
  end

  def test_then_requires_a_block
    err = assert_raises(ArgumentError) do
      tree do
        x = var :x, 0
        (x > 0).then
      end
    end
    assert_match(/block/, err.message)
  end

  # ---- .then { }.else { } ----

  def test_then_else_builds_both_branches
    got = tree do
      x = var :x, 0
      (x > 5).then { x.set 1 }.else { x.set 2 }
    end

    expected_if = if_(binop(:>, var_ref(:x), int(5)), set(:x, 1))
    expected_if[:else] = else_(set(:x, 2))
    assert_equal program(set(:x, 0), expected_if), got
  end

  def test_else_requires_a_block
    err = assert_raises(ArgumentError) do
      tree do
        x = var :x, 0
        (x > 5).then { x.set 1 }.else
      end
    end
    assert_match(/block/, err.message)
  end

  def test_mutating_an_expression_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      tree do
        x = var :x, 0
        (x + 1).add 2 # (x + 1) is an expression, not a variable — can't mutate it
      end
    end
    assert_match(/variable/, err.message)
  end

  # ---- behavioral: it boots and branches on hardware ----

  def test_then_gates_a_draw
    rom = build do
      display :bitmap
      clear_screen :black
      x = var :x, 5
      (x > 3).then { pixel 10, 10, :red }
      (x < 3).then { pixel 20, 20, :blue }
      halt
    end

    v = assert_gemba_loads_rom(rom)
    assert v.red?(10, 10), "5 > 3, so the gated red pixel draws"
    assert v.black?(20, 20), "5 is not < 3, so the blue pixel is skipped"
  end

  def test_mutation_inside_then_is_observed_later
    rom = build do
      display :bitmap
      clear_screen :black
      x = var :x, 0
      (x == 0).then { x.set 5 }
      (x == 5).then { pixel 10, 10, :red }
      halt
    end

    v = assert_gemba_loads_rom(rom)
    assert v.red?(10, 10), ".set inside .then updated x, and the next comparison saw 5"
  end
end
