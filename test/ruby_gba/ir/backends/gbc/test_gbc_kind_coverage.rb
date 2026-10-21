# frozen_string_literal: true

require "test_helper"
require "conformance_fixture"

# The Game Boy Color lowering writes its statements with the native lowering's tables (GBC::StatementLowering
# inherits them, and test_native_kind_coverage.rb holds those to every kind). What it cannot make yet
# is on a list of its own, said by what it is part of, and refused by name before anything is built.
class TestGBCKindCoverage < Minitest::Test
  Nodes = RubyGBA::IR::Nodes
  Portability = RubyGBA::IR::Portability
  Lowering = RubyGBA::IR::Backends::GBC::StatementLowering
  GBC = RubyGBA::IR::Backends::GBC

  private def portable_kinds
    (Nodes.of_role(:statement) + Nodes.of_role(:value) + Nodes.of_role(:declaration))
      .reject { |kind| Portability.hardware_only?(kind) }
  end

  private def not_yet = Lowering::NOT_LOWERED_YET.values.flatten

  def test_the_not_yet_list_names_only_kinds_that_exist
    assert_empty not_yet - portable_kinds
  end

  def test_no_kind_is_listed_twice
    assert_equal not_yet.uniq, not_yet
  end

  # Every statement of the picture and the sound is one the Color makes, one it says it does not
  # make yet, or one it refuses because a Color cannot do it: none slips through to a runtime call
  # the cartridge has no routine for. (A declaration — a sprite, a song — is made by the statements
  # that use it.)
  def test_every_kind_of_the_picture_and_the_sound_is_made_or_listed
    steps = (Nodes.of_role(:statement) + Nodes.of_role(:value)).reject { |kind| Portability.hardware_only?(kind) }
    categories = %i[draw sound]
    picture_and_sound = steps.select { |kind| categories.include?(Nodes.by_kind.fetch(kind).category) }

    assert_empty picture_and_sound - not_yet - Lowering::MADE - Lowering::REFUSED
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
