# frozen_string_literal: true

require "test_helper"
require "conformance_fixture"

# Every kind the IR has is one the Game Boy Color lowering makes (a row of its tables), one it says
# it does not make yet, by what it is part of, or one it refuses because a Color cannot do it — and
# what it does not make is refused by name before anything is built.
class TestGBCKindCoverage < Minitest::Test
  Nodes = VBlank::IR::Nodes
  Portability = VBlank::IR::Portability
  GBC = VBlank::IR::Backends::GBC
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

  # The kinds a Color cannot do at all, as its answers say of the conformance fixture, which touches
  # every kind: the build refuses them by those words, so the lowering never meets one.
  private def refused
    VBlank::Console::ColorAnswers.refusals(ConformanceFixture.program.walk.to_a, VBlank::Console.described(:gbc))
                                 .map { |refusal| refusal.node.kind }.uniq
  end

  # Every kind that can run on a Color is made, listed as not made yet, or refused: none reaches the
  # lowering with no row to make it.
  def test_every_kind_is_made_listed_or_refused
    assert_empty portable_kinds - made - not_yet - refused - %i[else]
  end

  def test_no_kind_is_both_made_and_not_made_yet
    assert_empty made & not_yet
  end

  def test_no_kind_is_both_refused_and_not_made_yet
    assert_empty refused & not_yet
  end

  # The conformance fixture touches every kind, some of which the Color's hardware cannot do, so
  # building it is refused, saying what the Color cannot do.
  def test_the_whole_fixture_is_refused_saying_why
    error = assert_raises(GBC::LoweringError) { GBC.new.build(ConformanceFixture.program) }

    assert_match(/Game Boy Color/, error.message)
  end
end
