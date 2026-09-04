# frozen_string_literal: true

require "test_helper"

# The kind-keyed dispatch tables (GBA::Lowering) that eval_value's and emit_statement's
# case statements were replaced with — coverage-locked against IR::Nodes the same way
# Portability::TIER is (see test_ir_portability.rb): every value/statement-category node
# kind must have a handler, and neither table may name a kind that doesn't exist.
class TestGBALowering < Minitest::Test
  def value_kinds
    RubyGBA::IR::Nodes.by_kind.select { |_, type| type.category == :value }.keys
  end

  STATEMENT_CATEGORIES = %i[root var draw sound control data list].freeze

  # :program and :else are walked structurally (program.children.each,
  # else_node.children.each) and never reach emit_statement's own dispatch.
  def statement_kinds
    RubyGBA::IR::Nodes.by_kind.reject { |k, _| %i[program else].include?(k) }
                              .select { |_, type| STATEMENT_CATEGORIES.include?(type.category) }.keys
  end

  def test_every_value_kind_has_a_handler
    missing = value_kinds - GBA.new.lowering.value_kinds
    assert_empty missing, "these value kinds have no Lowering handler: #{missing}"
  end

  def test_the_value_table_has_no_rows_for_unknown_kinds
    stray = GBA.new.lowering.value_kinds - value_kinds
    assert_empty stray, "these Lowering rows name kinds that aren't value-category IR nodes: #{stray}"
  end

  def test_every_statement_kind_has_a_handler
    missing = statement_kinds - GBA.new.lowering.statement_kinds
    assert_empty missing, "these statement kinds have no Lowering handler: #{missing}"
  end

  def test_the_statement_table_has_no_rows_for_unknown_kinds
    stray = GBA.new.lowering.statement_kinds - statement_kinds
    assert_empty stray, "these Lowering rows name kinds that aren't statement IR nodes: #{stray}"
  end
end
