# frozen_string_literal: true

require "test_helper"

# EVERY KIND OF NODE, HANDLED BY BOTH BACKENDS — read off what each kind says about itself
# (IR::Nodes.of_role, and each kind's tier) rather than a list kept here.
#
# Both backends dispatch through a table keyed by the kind's name: the console's lowering
# (Backends::GBA::Lowering) and the interpreter (Reference::STATEMENTS and ::VALUES). So a
# kind added to the IR with no handler in one of them fails here by name, rather than at the
# first program that happens to use it. And since a kind is portable unless it says it is
# hardware-only, this is also what holds that promise: a portable kind the interpreter
# cannot run is a failure, not a default.
class TestKindCoverage < Minitest::Test
  Nodes = RubyGBA::IR::Nodes
  Portability = RubyGBA::IR::Portability

  private def interpreter_can_run(kinds) = kinds.reject { |kind| Portability.hardware_only?(kind) }

  private def lowering = GBA.new.lowering

  def test_the_console_has_a_handler_for_every_value_kind_and_no_other
    assert_equal Nodes.of_role(:value).sort, lowering.value_kinds.sort
  end

  # A declaration is gathered before the program runs, so its row says to emit nothing — but
  # it has a row, which is what tells it apart from a kind that was forgotten.
  def test_the_console_has_a_handler_for_every_statement_and_declaration_and_no_other
    assert_equal (Nodes.of_role(:statement) + Nodes.of_role(:declaration)).sort, lowering.statement_kinds.sort
  end

  def test_the_interpreter_has_a_handler_for_every_portable_value_kind_and_no_other
    assert_equal interpreter_can_run(Nodes.of_role(:value)).sort, Reference::VALUES.keys.sort
  end

  # The interpreter runs the program node through the same table, and gives each declaration
  # a row that does nothing, as the console does.
  def test_the_interpreter_has_a_handler_for_every_portable_statement_and_no_other
    assert_equal interpreter_can_run(%i[statement declaration root].flat_map { |role| Nodes.of_role(role) }).sort,
                 Reference::STATEMENTS.keys.sort
  end

  def test_every_kind_plays_one_known_part
    roles = Nodes.by_kind.values.map(&:role).uniq
    assert_empty roles - %i[value statement declaration part root], "unknown roles: #{roles}"
  end
end
