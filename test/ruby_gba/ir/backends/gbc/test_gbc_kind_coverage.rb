# frozen_string_literal: true

require "test_helper"
require "conformance_fixture"

# Every kind the IR has is one the Game Boy Color lowering makes (a row of its tables), one it says
# it does not make yet, by what it is part of, or one it refuses because a Color cannot do it — and
# what it does not make is refused by name before anything is built.
class TestGBCKindCoverage < Minitest::Test
  Nodes = RubyGBA::IR::Nodes
  Portability = RubyGBA::IR::Portability
  GBC = RubyGBA::IR::Backends::GBC
  Lowering = GBC::Lowering

  private def portable_kinds
    (Nodes.of_role(:statement) + Nodes.of_role(:value) + Nodes.of_role(:declaration))
      .reject { |kind| Portability.hardware_only?(kind) }
  end

  private def not_yet = Lowering::NOT_LOWERED_YET.values.flatten

  private def made = Lowering::STATEMENTS.keys + Lowering::VALUES.keys

  def test_the_not_yet_list_names_only_kinds_that_exist
    assert_empty not_yet - portable_kinds
  end

  def test_no_kind_is_listed_twice
    assert_equal not_yet.uniq, not_yet
  end

  # Every kind that can run on a Color is made, listed as not made yet, or refused: none reaches the
  # lowering with no row to make it.
  def test_every_kind_is_made_or_listed
    assert_empty portable_kinds - made - not_yet - Lowering::REFUSED - %i[else]
  end

  def test_no_kind_is_both_made_and_listed
    assert_empty made & (not_yet + Lowering::REFUSED)
  end

  def test_no_kind_is_both_refused_and_not_made_yet
    assert_empty Lowering::REFUSED & not_yet
  end

  # The conformance fixture touches every kind, so building it names everything not made yet.
  def test_the_whole_fixture_is_refused_naming_what_is_not_made_yet
    error = assert_raises(GBC::LoweringError) { GBC.new.build(ConformanceFixture.program) }

    assert_match(/cannot make yet/, error.message)
  end
end
