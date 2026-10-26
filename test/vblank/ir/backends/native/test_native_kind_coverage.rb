# frozen_string_literal: true

require "test_helper"

# Every kind of node a desktop build could meet is either written as C by the native backend
# or on its list of kinds it cannot write yet — never neither, and never both. The first-class
# backends are held to every kind by test_kind_coverage.rb; this backend trails them, so it is
# held to saying what it is missing instead.
class TestNativeKindCoverage < Minitest::Test
  Nodes = VBlank::IR::Nodes
  Portability = VBlank::IR::Portability
  Lowering = VBlank::IR::Backends::Native::Lowering

  # What a program can hold that runs anywhere. An `else` is part of an `if` and is written with
  # it; `raw` and the other hardware-only kinds are refused before anything is written.
  private def portable_kinds
    (Nodes.of_role(:statement) + Nodes.of_role(:value) + Nodes.of_role(:declaration))
      .reject { |kind| Portability.hardware_only?(kind) }
  end

  private def handled = Lowering::STATEMENTS.keys + Lowering::VALUES.keys
  private def not_yet = Lowering::NOT_LOWERED_YET.values.flatten

  def test_every_kind_is_written_as_c_or_listed_as_not_yet
    assert_empty portable_kinds - handled - not_yet
  end

  def test_a_kind_written_as_c_is_off_the_not_yet_list
    assert_empty handled & not_yet
  end

  def test_the_not_yet_list_names_only_kinds_that_exist
    assert_empty not_yet - portable_kinds
  end
end
