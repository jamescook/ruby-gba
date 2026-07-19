# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# During the builder-to-IR migration the DSL builds an IR tree in parallel with
# the ARM bytes it still emits. These tests assert the DSL constructs the RIGHT
# tree — the migration's core correctness — without lowering anything to a ROM.
# (The byte output is still exercised by the existing behavioral tests.)
class TestBuilderIR < Minitest::Test
  include RubyGBA::IR::Build # the expected-tree constructors

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby

  # Build through the DSL and hand back the IR tree it constructed.
  def tree(&block)
    rom = RubyGBA::ROM.new(title: "TEST", code: "TEST", maker: "01")
    builder = Builder.new(rom)
    builder.instance_eval(&block)
    builder.program
  end

  def test_variable_ops_build_a_matching_ir_tree
    got = tree do
      var :x, 5        # var is an alias for set
      set :y, 10
      add :x, 3        # immediate operand
      sub :x, :y       # variable operand
      copy :z, :x
      flip :z          # flip is an alias for negate
      abs :z
      negate_abs :z
      clamp :x, 0, 100
    end

    assert_equal program(
      set(:x, 5),
      set(:y, 10),
      add(:x, 3),
      sub(:x, :y),
      copy(:z, :x),
      negate(:z),
      abs(:z),
      negate_abs(:z),
      clamp(:x, 0, 100),
    ), got
  end

  def test_clamp_records_one_node_not_its_byte_expansion
    # The legacy clamp expands to a pair of compares in bytes, but in the IR it
    # is a single clamp node — the inner set/if calls must not leak in.
    got = tree { clamp :hp, 0, 100 }
    assert_equal 1, got.children.size
    assert_equal :clamp, got.children.first.kind
  end

  def test_the_built_tree_runs_in_the_interpreter
    # Structural equality proves the shape; running it proves the meaning. The
    # same tree the DSL built executes on the Ruby backend and clamps as intended.
    got = tree do
      var :x, 10
      add :x, 100     # 110
      clamp :x, 0, 20 # -> 20
    end
    assert_equal 20, Ruby.new.run(got)[:x]
  end
end
