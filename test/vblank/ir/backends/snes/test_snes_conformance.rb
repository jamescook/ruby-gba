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

  # The fixture's top-level parts that reach no kind the build does not make, that ask nothing a
  # Super Nintendo's answers refuse (Checks::ConsoleAnswers, which the build asks too), and that the
  # build does not refuse alone as not made yet (a painted screen, say).
  private def made_parts
    kept = ConformanceFixture.program.children.reject do |part|
      alone = Build.program(part).tap { |program| program.console = :snes }
      refused = VBlank::IR::Guardrails::Checks::ConsoleAnswers.new.detect(alone).any? { |found| found.severity == :error }
      refused || part.walk.any? { |node| UNMADE.include?(node.kind) } || not_made_yet?(alone)
    end
    # ...and the parts that change a background or place its bar, place a sprite or play a song whose
    # declaration was left out; and, on the fixture's painted screen, its tiles painted from a list.
    # No background can show those there (the builder refuses a game one), and the interpreter's
    # repaint owed for a copy clears a painted screen at the frame's end, which no game can reach.
    declared = kept.flat_map { |part| part.walk.to_a }.select { |node| %i[background object song].include?(node.kind) }
                   .map(&:name)
    painted = kept.any? { |part| part.walk.any? { |node| node.kind == :screen && node.mode == :bitmap } }
    kept.reject do |part|
      part.walk.any? do |node|
        (%i[scroll_background set_tile show_map place_bar play_song].include?(node.kind) && !declared.include?(node.name)) ||
          (node.kind == :song_list && !(node.songs - declared).empty?) ||
          (node.kind == :sound_effect_list && !(node.effects - declared).empty?) ||
          (node.kind == :present_objects && !(node.names - declared).empty?) ||
          (painted && %i[tile_run copy_tiles copy_owed_tiles].include?(node.kind))
      end
    end
  end

  private def not_made_yet?(program)
    SNES.new.build(program)
    false
  rescue SNES::Lowering::NotMadeYet
    true
  rescue StandardError # a part that cannot be built alone (it calls a routine declared elsewhere)
    false
  end

  def test_the_parts_of_the_fixture_the_build_makes_agree_with_the_interpreter
    program = Build.program(*made_parts).tap { |made| made.console = :snes }
    played = program.walk.map(&:kind).uniq

    assert_empty %i[list_push list_drop case repeat call every after timer_start binop] - played,
                 "the parts played reach the kinds this test is here for"
    SNES::CheckedRun.new.run(program, frames: 8)
  end
end
