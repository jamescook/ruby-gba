# frozen_string_literal: true

require "test_helper"

# The kind-keyed dispatch table (GBA::Lowering) that eval_value's case statement was
# replaced with — coverage-locked against IR::Nodes the same way Portability::TIER is
# (see test_ir_portability.rb): every value-category node kind must have a handler, and
# the table must name no kind that doesn't exist.
class TestGBALowering < Minitest::Test
  def value_kinds
    RubyGBA::IR::Nodes.by_kind.select { |_, type| type.category == :value }.keys
  end

  def test_every_value_kind_has_a_handler
    missing = value_kinds - GBA.new.lowering.value_kinds
    assert_empty missing, "these value kinds have no Lowering handler: #{missing}"
  end

  def test_the_value_table_has_no_rows_for_unknown_kinds
    stray = GBA.new.lowering.value_kinds - value_kinds
    assert_empty stray, "these Lowering rows name kinds that aren't value-category IR nodes: #{stray}"
  end
end
