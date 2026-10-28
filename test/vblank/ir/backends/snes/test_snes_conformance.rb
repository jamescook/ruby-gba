# frozen_string_literal: true

require "test_helper"
require "conformance_fixture"

# The conformance fixture touches every kind of the IR, and the Super Nintendo build does not make
# all of them yet. Every top-level part of the fixture that reaches only kinds it makes is played on
# the checked run, so each kind the build learns to make joins this test by itself, the day it
# leaves the not-made-yet list.
class TestSNESConformance < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Build = VBlank::IR::Build

  UNMADE = (SNES::Lowering::NOT_LOWERED_YET.values.flatten + SNES::Lowering::REFUSED).freeze

  # The fixture's top-level parts that reach no kind the build does not make, and that ask nothing
  # a Super Nintendo's answers refuse (Checks::ConsoleAnswers, which the build asks too).
  private def made_parts
    ConformanceFixture.program.children.reject do |part|
      alone = Build.program(part).tap { |program| program.console = :snes }
      refused = VBlank::IR::Guardrails::Checks::ConsoleAnswers.new.detect(alone).any? { |found| found.severity == :error }
      refused || part.walk.any? { |node| UNMADE.include?(node.kind) }
    end
  end

  def test_the_parts_of_the_fixture_the_build_makes_agree_with_the_interpreter
    program = Build.program(*made_parts).tap { |made| made.console = :snes }
    played = program.walk.map(&:kind).uniq

    assert_empty %i[list_push list_drop case repeat call every after timer_start binop] - played,
                 "the parts played reach the kinds this test is here for"
    SNES::CheckedRun.new.run(program, frames: 8)
  end
end
